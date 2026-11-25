#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "LCProxyHooks.h"
#import "LCProxyManager.h"
#import "LCWatchdog.h"
#import "LCProxyUI.h"

__attribute__((constructor))
static void LCProxyTweakInitialize(void) {
    @autoreleasepool {
        // 1. Install NSURLSession, fishhook CFNetwork, and WKWebView hooks immediately
        //    before host LiveContainer or any guest app initiates network requests.
        LCProxyHooksInstall();

        // 2. Bootstrap shared configuration & start xray-rust if proxy was enabled.
        [[LCProxyManager sharedManager] bootstrapOnLaunch];

        // 3. Start Watchdog (sleep/unlock notifications + NWPathMonitor + 20s heartbeat).
        [[LCWatchdog sharedWatchdog] startMonitoring];

        // 4. Attach floating UIKit overlay once UIWindowScene becomes active.
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            [[LCProxyUI sharedUI] installOverlayIfNeeded];
        }];
    }
}
