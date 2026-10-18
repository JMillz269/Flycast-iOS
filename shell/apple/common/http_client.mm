/*
	Copyright 2022 flyinghead

	This file is part of Flycast.

	Flycast is free software: you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation, either version 2 of the License, or
	(at your option) any later version.

	Flycast is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with Flycast.  If not, see <https://www.gnu.org/licenses/>.
*/
#import <Foundation/Foundation.h>
#include "oslib/http_client.h"
#include <atomic>

static std::atomic<int> cancelGeneration {0};

static bool sendRequest(NSURLRequest *request, NSData **outData, NSHTTPURLResponse **outResponse)
{
	__block NSData *data = nil;
	__block NSURLResponse *response = nil;
	__block NSError *error = nil;
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	const int generation = cancelGeneration.load();

	NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
	config.timeoutIntervalForRequest = 10;
	NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
	NSURLSessionDataTask *task = [session dataTaskWithRequest:request
	        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
		data = d;
		response = r;
		error = e;
		dispatch_semaphore_signal(done);
	}];
	[task resume];

	// Wait in short slices so cancelPending() can interrupt us
	while (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0)
	{
		if (cancelGeneration.load() != generation)
			[task cancel];
	}
	[session finishTasksAndInvalidate];

	if (error != nil || ![response isKindOfClass:[NSHTTPURLResponse class]]) {
		NSLog(@"Flycast HTTP request to %@ failed: %@", request.URL, error);
		return false;
	}
	*outData = data;
	*outResponse = (NSHTTPURLResponse *)response;
	return true;
}

namespace http {

void cancelPending() {
	cancelGeneration++;
}

int get(const std::string& url, std::vector<u8>& content, std::string& contentType)
{
	NSString *nsurl = [NSString stringWithCString:url.c_str() 
                                         encoding:[NSString defaultCStringEncoding]];
    NSString *userAgent = [NSString stringWithCString:getUserAgent().c_str()
                                             encoding:[NSString defaultCStringEncoding]];
	NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:nsurl]];
	[urlRequest setValue:userAgent forHTTPHeaderField:@"User-Agent"];
	[urlRequest setTimeoutInterval:10.0];

	NSData *data = nil;
	NSHTTPURLResponse *httpResponse = nil;
	if (!sendRequest(urlRequest, &data, &httpResponse))
		return 500;

	if (httpResponse.MIMEType != nil)
		contentType = std::string([httpResponse.MIMEType UTF8String]);
	else
		contentType.clear();
		
	content.clear();
	content.insert(content.begin(), (const u8 *)[data bytes], (const u8 *)[data bytes] + [data length]);
	
	return [httpResponse statusCode];
}

int post(const std::string& url, const char *payload, const char *contentType, std::vector<u8>& reply)
{
	NSString *nsurl = [NSString stringWithCString:url.c_str() 
                                         encoding:[NSString defaultCStringEncoding]];
    NSString *userAgent = [NSString stringWithCString:getUserAgent().c_str()
                                             encoding:[NSString defaultCStringEncoding]];
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:nsurl]];
	[request setHTTPMethod:@"POST"];
	[request setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData];
	[request setHTTPShouldHandleCookies:NO];
	[request setTimeoutInterval:10.0];
	
	size_t payloadSize = strlen(payload);
	[request setHTTPBody:[NSData dataWithBytes:payload length:payloadSize]];
	NSString *postLength = [NSString stringWithFormat:@"%ld", (unsigned long)payloadSize];
    [request setValue:postLength forHTTPHeaderField:@"Content-Length"];
    NSString *nscontentType = contentType != nullptr ? [NSString stringWithCString:contentType 
                                         encoding:[NSString defaultCStringEncoding]]
    	: @"application/x-www-form-urlencoded";
    [request setValue:nscontentType forHTTPHeaderField:@"Content-Type"];
	[request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    
	NSData *data = nil;
	NSHTTPURLResponse *httpResponse = nil;
	if (!sendRequest(request, &data, &httpResponse))
		return 500;
		
	reply.clear();
	reply.insert(reply.begin(), (const u8 *)[data bytes], (const u8 *)[data bytes] + [data length]);

	return [httpResponse statusCode];
}

int post(const std::string& url, const std::vector<PostField>& fields)
{
	NSString *nsurl = [NSString stringWithCString:url.c_str() 
                                         encoding:[NSString defaultCStringEncoding]];
    NSString *userAgent = [NSString stringWithCString:getUserAgent().c_str()
                                             encoding:[NSString defaultCStringEncoding]];
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:nsurl]];
	[request setHTTPMethod:@"POST"];
	[request setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData];
	[request setHTTPShouldHandleCookies:NO];

	NSString *boundary = @"----flycast-boundary-7192397596";
	NSString *contentType = [NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary];
	[request setValue:contentType forHTTPHeaderField: @"Content-Type"];
	[request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
	
	NSMutableData *body = [NSMutableData data];
	for (const PostField& field : fields)
	{
        NSString *value = [NSString stringWithCString:field.value.c_str() 
                                         encoding:[NSString defaultCStringEncoding]];
		[body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
		[body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"", [NSString stringWithCString:field.name.c_str() 
                                         encoding:[NSString defaultCStringEncoding]]] dataUsingEncoding:NSUTF8StringEncoding]];
        if (!field.contentType.empty())
        {
	        [body appendData:[[NSString stringWithFormat:@"; filename=\"%@\"\r\n", value] dataUsingEncoding:NSUTF8StringEncoding]];
	        [body appendData:[[NSString stringWithFormat:@"Content-Type: %@", [NSString stringWithCString:field.contentType.c_str() 
                                         encoding:[NSString defaultCStringEncoding]]] dataUsingEncoding:NSUTF8StringEncoding]];
        }
        [body appendData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
        
        if (field.contentType.empty())
        {
	        [body appendData:[value dataUsingEncoding:NSUTF8StringEncoding]];
        }
        else
        {
        	NSError* error = nil;
			NSData *filedata = [NSData dataWithContentsOfFile:value options:0 error:&error];
			if (error != nil)
				return 500;
	        [body appendData:filedata];
        }
        [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
	}
	[body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
	
	[request setHTTPBody:body];
	NSString *postLength = [NSString stringWithFormat:@"%ld", (unsigned long)[body length]];
    [request setValue:postLength forHTTPHeaderField:@"Content-Length"];
    
	NSData *data = nil;
	NSHTTPURLResponse *httpResponse = nil;
	if (!sendRequest(request, &data, &httpResponse))
		return 500;

	return [httpResponse statusCode];
}

void init() {
}

void term() {
}

}
