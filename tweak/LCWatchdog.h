#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCWatchdog : NSObject

+ (instancetype)sharedWatchdog;

/// Starts observing UIApplication foreground/background notifications, NWPathMonitor, and the 20s active heartbeat.
- (void)startMonitoring;

/// Stops heartbeat timer and NWPathMonitor.
- (void)stopMonitoring;

/// Serialized, race-free revival check:
/// 1) Verifies xray-rust running flag & local TCP loopback port
/// 2) Verifies end-to-end 204 reachability (2s timeout)
/// 3) Restarts xray-rust & re-syncs hooks, or performs <100ms failover to cached backup server
- (void)verifyAndReviveProxyWithReason:(NSString *)reason;

@end

NS_ASSUME_NONNULL_END
