//
//  main.m
//  LowBatteryWarning
//
//  Created by Nicholas Hutchinson on 7/01/12.
//  Copyright (c) 2012 __MyCompanyName__. All rights reserved.
//

#import <Foundation/Foundation.h>

#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/ps/IOPSKeys.h>
#import <IOKit/ps/IOPowerSources.h>

#import <AudioToolbox/AudioToolbox.h>

#import <getopt.h>
#import <notify.h>

// This define ought to be made public by IOKit--it's referenced by public headers!--but it ain't.
// So we define it here.
#ifndef kIOPMACPowerKey
#define kIOPMACPowerKey                                 "AC Power"
#endif

@interface CriticalBatteryMonitor : NSObject
- (void)startMonitoring;

@property (readonly) double criticalThreshold;
@end


@interface CriticalBatteryMonitor ()
- (void)systemPowerInfoDidChange;
- (void)putSystemToSleep;
- (void)performBeep;
- (void)registerForPowerNotifications;
@end


@implementation CriticalBatteryMonitor {
    @private
    int _notifyToken;
    BOOL _isRegistered;
    double _lastSeenPercentageCapacity;
}

- (double)criticalThreshold
{
    return 1.0;
}

- (id)init {    
    self = [super init];
    if (self) {
        _lastSeenPercentageCapacity = 100.0;
    }
    return self;
}

- (void)dealloc {
    if (_isRegistered) {
        notify_cancel(_notifyToken);
        _isRegistered = NO;
    }
}

#pragma  mark -

- (void)registerForPowerNotifications
{
    assert(!_isRegistered);

    _isRegistered = YES;
    __weak CriticalBatteryMonitor* weakself = self;
    notify_register_dispatch(kIOPSTimeRemainingNotificationKey, &_notifyToken, dispatch_get_main_queue(), ^(int token) {
        @autoreleasepool {
            [weakself systemPowerInfoDidChange];
        }
    });
}

- (void)startMonitoring
{
    [self registerForPowerNotifications];
    
    /* Send initial notification */
    [self systemPowerInfoDidChange];
}


#pragma  mark -


- (void)performBeep
{
    AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert);
}


- (void)putSystemToSleep
{
    io_connect_t port = IOPMFindPowerManagement(MACH_PORT_NULL);
    IOPMSleepSystem(port);
    IOServiceClose(port);
}


- (void)askUserToSleepSystem
{
    [self performBeep];
    
    CFOptionFlags response;
    CFUserNotificationDisplayAlert(10 /* timeout in seconds */,
                                   kCFUserNotificationStopAlertLevel /*flags*/, 
                                   NULL /*icon*/,
                                   NULL /*sound*/,
                                   NULL /*localisation*/,
                                   CFSTR("Low battery") /*title*/,
                                   CFSTR("You should really sleep your laptop before something bad happens.") /*message*/,
                                   CFSTR("Sleep now") /*default button*/,
                                   CFSTR("Don't sleep") /* alternate button*/,
                                   NULL /* other */,
                                   &response /* response out */);
    
    /* response values: default => sleep now, alternate => don't sleep, cancel => timeout. */
    
    /* Explicit cancel by user */
    if (response == kCFUserNotificationAlternateResponse)
        return;
    
    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    /* Has the user plugged in the power cable ? If so, cancel the sleep request */
    NSString *ps = (__bridge NSString *)IOPSGetProvidingPowerSourceType(blob);
    CFRelease(blob), blob = NULL;
    
    if ([ps isEqualToString:@kIOPMACPowerKey]) {
        CFUserNotificationDisplayNotice(0, 
                                        kCFUserNotificationNoteAlertLevel, 
                                        NULL /* icon */, 
                                        NULL /* URL */,
                                        NULL /* Localization */, 
                                        CFSTR("Sleep cancelled."), 
                                        CFSTR("No need to sleep: your computer is connected to A/C power."), 
                                        NULL /* default button */);
        return;
        
    } else {
        NSLog(@"MnLowBatteryWarning: low battery. Sending system to sleep...");
        [self putSystemToSleep];
        
    }

}

#pragma  mark -


/* see IOKit/ps/IOPSKeys.h for possible keys/values in the dictionary */
- (NSDictionary*)primaryBatteryInfo
{
    id powerInfoBlob = (__bridge_transfer id)IOPSCopyPowerSourcesInfo();
    NSArray* sources = (__bridge_transfer NSArray*)IOPSCopyPowerSourcesList((__bridge CFTypeRef)powerInfoBlob);
    
    NSUInteger idx = [sources indexOfObjectPassingTest:^BOOL(id sourceBlob, NSUInteger idx, BOOL *stop) {
                      NSDictionary* sourceInfo = (__bridge NSDictionary*)IOPSGetPowerSourceDescription((__bridge CFTypeRef)powerInfoBlob,
                                                                                                       (__bridge CFTypeRef)sourceBlob);
                      
                      NSString* batteryType = [sourceInfo objectForKey:@kIOPSTypeKey];
                      return (batteryType && [batteryType isEqualToString:@kIOPSInternalBatteryType]);
                      }];
    
    if (idx == NSNotFound)
        return nil;
    
    return (__bridge NSDictionary*)IOPSGetPowerSourceDescription((__bridge CFTypeRef)powerInfoBlob,
                                                                 (__bridge CFTypeRef)[sources objectAtIndex:idx]);
}

- (void)systemPowerInfoDidChange
{
    NSDictionary* info = [self primaryBatteryInfo];
    
    if (!info) {
        NSLog(@"Could not find primary battery -- perhaps there is none.");
        return;
    }
    
    NSNumber* capacity = [info objectForKey:@kIOPSCurrentCapacityKey];
    NSNumber* maxCapacity = [info objectForKey:@kIOPSMaxCapacityKey];
    
    if (!capacity || !maxCapacity) {
        NSLog(@"Can't calculate capacity.");
        return;
    }
    
    double capacityAsPercentage = 100.0 * [capacity doubleValue] / [maxCapacity doubleValue];
    
    /* Did out battery level decrease such that the critical threshold was crossed */
    BOOL didCrossThreshold = _lastSeenPercentageCapacity > self.criticalThreshold && capacityAsPercentage <= self.criticalThreshold;
    
    _lastSeenPercentageCapacity = capacityAsPercentage;
    
    if (didCrossThreshold) {
//        printf("*Notifying*: Capacity is %.1f%%; last seen was %.1f%%, threshold is %.1f%%.\n", capacityAsPercentage, _lastSeenPercentageCapacity, self.criticalThreshold);
        
        [self askUserToSleepSystem];
    } else {
//        printf("Not notifying: Capacity is %.1f%%; last seen was %.1f%%, threshold is %.1f%%.\n", capacityAsPercentage, _lastSeenPercentageCapacity, self.criticalThreshold);
    }
    
}

@end


int main (int argc, char * argv[])
{
    @autoreleasepool {
        CriticalBatteryMonitor* monitor = [CriticalBatteryMonitor new];
        
        NSLog(@"Starting monitoring of battery levels...\n");
        
        BOOL usingDebugMode = NO;
        
        struct option kArgFlags[] = {
            { "debug", no_argument, NULL, 'd'},
            { NULL, 0, NULL, 0 }
        };
        
        int ch;
        while ((ch=getopt_long(argc, argv, ""/*opt string*/, kArgFlags, NULL)) != -1) {
            switch (ch) {
                case 'd':
                    usingDebugMode = YES;
                    break;
            }
        }
        
        if (usingDebugMode) {
            NSLog(@"Debug mode");
            [monitor askUserToSleepSystem];
            return EXIT_SUCCESS;
        }
        
        [monitor startMonitoring];
        
        dispatch_main();

    }
  
    
    return 0;
}

