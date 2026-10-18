// Copyright 2025 Flycast Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>
#include "ios_jit_manager.h"

#include <sys/utsname.h>
#include <math.h>
#include <string.h>
#include <stdio.h>

#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR

#include <unistd.h>
#include <sys/types.h>

#define CS_OPS_STATUS 0
#define CS_DEBUGGED 0x10000000

// Properly declare csops for both C and C++
#ifdef __cplusplus
extern "C" {
#endif

int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);

#ifdef __cplusplus
}
#endif

// Port of StosDebug's ProcessInfo.detectedTXM (TXM_Checks.swift).
// Uses the hardware model, so it needs no filesystem access and works in a sandbox / LiveContainer.
static bool ios_hardware_has_txm(void) {
    struct utsname systemInfo;
    if (uname(&systemInfo) != 0) {
        return false;
    }
    const char* hw = systemInfo.machine;

    // iOS 27+: every device except these two iPads has TXM
    if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){27, 0, 0}]) {
        return strcmp(hw, "iPad8,11") != 0 && strcmp(hw, "iPad8,12") != 0;
    }

    // iOS 26: decide by hardware generation
    if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){26, 0, 0}]) {
        bool isPad = strncmp(hw, "iPad", 4) == 0;
        bool isPhone = strncmp(hw, "iPhone", 6) == 0;
        if (!isPad && !isPhone) {
            return false;
        }

        int major = 0, minor = 0;
        if (sscanf(hw + (isPad ? 4 : 6), "%d,%d", &major, &minor) != 2) {
            return false;
        }

        // Same math as StosDebug: major + minor / 10^(digits in minor)
        int digits = 1;
        for (int m = minor; m >= 10; m /= 10) digits++;
        double version = major + (double)minor / pow(10.0, digits);

        return isPad ? (version >= 14.5) : (version >= 14.2);
    }

    return false;
}

bool ios_device_has_txm(void) {
    // Optional manual override, same idea as StosDebug's "forceTXM"
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"forceTXM"]) {
        return true;
    }
    return ios_hardware_has_txm();
}

bool ios_process_is_debugged(void) {
    int flags;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
        return false;
    }
    return (flags & CS_DEBUGGED) != 0;
}

bool ios_can_use_txm_jit(void) {
    static bool checked = false;
    static bool result = false;
    
    if (!checked) {
        checked = true;
        
        bool has_txm = ios_device_has_txm();
        bool is_debugged = ios_process_is_debugged();
        
        if (has_txm && !is_debugged) {
            NSLog(@"[Flycast] WARNING: TXM device detected but no debugger attached.");
            NSLog(@"[Flycast] JIT compilation will not work. Please attach StikDebug to enable JIT.");
            result = false;
        } else if (has_txm && is_debugged) {
            // Check if running under Xcode (which won't work with TXM)
            NSDictionary* environment = [[NSProcessInfo processInfo] environment];
            if ([environment objectForKey:@"XCODE"] != nil) {
                NSLog(@"[Flycast] ERROR: TXM device detected but running under Xcode.");
                NSLog(@"[Flycast] Xcode debugging is not compatible with TXM JIT.");
                NSLog(@"[Flycast] Please use StikDebug instead.");
                result = false;
            } else {
                NSLog(@"[Flycast] TXM device detected with debugger attached.");
                NSLog(@"[Flycast] Enabling TXM JIT mode with dual-mapped memory pool.");
                result = true;
            }
        } else {
            NSLog(@"[Flycast] Non-TXM device or iOS < 26. Using standard MAP_JIT mode.");
            result = false;
        }
    }
    
    return result;
}

#endif // TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
