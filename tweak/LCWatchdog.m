#import "LCWatchdog.h"
#import "LCProxyManager.h"
#import "LCXrayRustBridge.h"
#import "LCFastSelector.h"
#import "LCProxyHooks.h"
#import <UIKit/UIKit.h>
#import <Network/Network.h>
#import <unistd.h>

static const uint64_t kHeartbeatIntervalSec = 20;
static const NSTimeInterval kReviveProbeTimeoutSec = 2.0;

@interface LCWatchdog () {
    dispatch_queue_t _watchdogQueue;
    dispatch_source_t _heartbeatTimer;
    nw_path_monitor_t _pathMonitor;
    BOOL _monitoring;
    BOOL _inBackground;
    BOOL _reviveInFlight;
    nw_path_status_t _lastPathStatus;
    nw_interface_type_t _lastInterfaceType;
    CFAbsoluteTime _lastReviveTimestamp;
}
@end

@implementation LCWatchdog

+ (instancetype)sharedWatchdog {
    static LCWatchdog *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[LCWatchdog alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _watchdogQueue = dispatch_queue_create("com.lcproxy.watchdog.serial", DISPATCH_QUEUE_SERIAL);
        _lastPathStatus = nw_path_status_invalid;
        _lastInterfaceType = nw_interface_type_other;
    }
    return self;
}

- (void)startMonitoring {
    dispatch_async(_watchdogQueue, ^{
        if (self->_monitoring) return;
        self->_monitoring = YES;

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self
               selector:@selector(handleWillEnterForeground:)
                   name:UIApplicationWillEnterForegroundNotification
                 object:nil];
        [nc addObserver:self
               selector:@selector(handleDidBecomeActive:)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];
        [nc addObserver:self
               selector:@selector(handleDidEnterBackground:)
                   name:UIApplicationDidEnterBackgroundNotification
                 object:nil];

        [self startNetworkPathMonitorLocked];
        [self startHeartbeatLocked];
        [[LCProxyManager sharedManager] appendLog:@"[Watchdog] Monitoring started (20s heartbeat + NWPathMonitor)"];
    });
}

- (void)stopMonitoring {
    dispatch_async(_watchdogQueue, ^{
        if (!self->_monitoring) return;
        self->_monitoring = NO;
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        [self stopHeartbeatLocked];
        if (self->_pathMonitor) {
            nw_path_monitor_cancel(self->_pathMonitor);
            self->_pathMonitor = nil;
        }
    });
}

#pragma mark - App Lifecycle Handlers

- (void)handleWillEnterForeground:(NSNotification *)note {
    dispatch_async(_watchdogQueue, ^{
        self->_inBackground = NO;
        [self startHeartbeatLocked];
    });
    [self verifyAndReviveProxyWithReason:@"WillEnterForeground"];
}

- (void)handleDidBecomeActive:(NSNotification *)note {
    dispatch_async(_watchdogQueue, ^{
        self->_inBackground = NO;
        [self startHeartbeatLocked];
    });
    [self verifyAndReviveProxyWithReason:@"DidBecomeActive"];
}

- (void)handleDidEnterBackground:(NSNotification *)note {
    dispatch_async(_watchdogQueue, ^{
        self->_inBackground = YES;
        [self stopHeartbeatLocked];
        [[LCProxyManager sharedManager] appendLog:@"[Watchdog] App entered background — heartbeat paused for battery"];
    });
}

#pragma mark - NWPathMonitor (Wi-Fi <-> 5G/LTE Instant Reaction)

- (void)startNetworkPathMonitorLocked {
    if (_pathMonitor) {
        nw_path_monitor_cancel(_pathMonitor);
    }
    _pathMonitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(_pathMonitor, _watchdogQueue);

    __weak typeof(self) weakSelf = self;
    nw_path_monitor_set_update_handler(_pathMonitor, ^(nw_path_t path) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        nw_path_status_t status = nw_path_get_status(path);
        nw_interface_type_t iface = nw_interface_type_other;
        if (nw_path_uses_interface_type(path, nw_interface_type_wifi)) iface = nw_interface_type_wifi;
        else if (nw_path_uses_interface_type(path, nw_interface_type_cellular)) iface = nw_interface_type_cellular;
        else if (nw_path_uses_interface_type(path, nw_interface_type_wired)) iface = nw_interface_type_wired;

        BOOL changed = (status != strongSelf->_lastPathStatus) || (iface != strongSelf->_lastInterfaceType);
        strongSelf->_lastPathStatus = status;
        strongSelf->_lastInterfaceType = iface;

        if (!changed) return;

        if (status == nw_path_status_satisfied) {
            NSString *ifaceName = (iface == nw_interface_type_wifi) ? @"Wi-Fi"
                                : (iface == nw_interface_type_cellular ? @"5G/LTE" : @"Network");
            [[LCProxyManager sharedManager] appendLog:[NSString stringWithFormat:@"[Watchdog] Network switched -> %@", ifaceName]];
            [[LCXrayRustBridge sharedBridge] rebindActiveCarrierSockets];
            [strongSelf verifyAndReviveProxyWithReason:[NSString stringWithFormat:@"NetworkSwitch(%@)", ifaceName]];
        } else {
            [[LCProxyManager sharedManager] appendLog:@"[Watchdog] Network path unsatisfied (offline)"];
        }
    });
    nw_path_monitor_start(_pathMonitor);
}

#pragma mark - 20s Battery-Aware Heartbeat

- (void)startHeartbeatLocked {
    if (_heartbeatTimer) return;
    _heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _watchdogQueue);
    dispatch_source_set_timer(_heartbeatTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHeartbeatIntervalSec * NSEC_PER_SEC)),
                              kHeartbeatIntervalSec * NSEC_PER_SEC,
                              2 * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_heartbeatTimer, ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_inBackground) return;
        [strongSelf verifyAndReviveProxyWithReason:@"Heartbeat20s"];
    });
    dispatch_resume(_heartbeatTimer);
}

- (void)stopHeartbeatLocked {
    if (_heartbeatTimer) {
        dispatch_source_cancel(_heartbeatTimer);
        _heartbeatTimer = nil;
    }
}

#pragma mark - Core verifyAndReviveProxy Algorithm

- (void)verifyAndReviveProxyWithReason:(NSString *)reason {
    dispatch_async(_watchdogQueue, ^{
        LCProxyManager *mgr = [LCProxyManager sharedManager];
        if (!mgr.proxyEnabled) return;

        // Debounce rapid foreground+active bursts within 1.5s (unless explicit manual check)
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (self->_reviveInFlight || ((now - self->_lastReviveTimestamp) < 1.5 && ![reason isEqualToString:@"Heartbeat20s"])) {
            return;
        }
        self->_reviveInFlight = YES;
        self->_lastReviveTimestamp = now;

        LCXrayRustBridge *bridge = [LCXrayRustBridge sharedBridge];
        uint16_t httpPort = bridge.activeHttpPort;
        uint16_t socksPort = bridge.activeSocksPort;

        // Step 1: Check xray-rust core status + fast local loopback TCP connect
        BOOL coreAlive = bridge.isRunning && httpPort > 0 &&
                         [LCFastSelector checkLocalLoopbackPortAlive:httpPort timeoutMs:250];

        // Step 2: End-to-end reachability probe through local proxy (2.0s timeout)
        NSInteger rttMs = -1;
        if (coreAlive) {
            rttMs = [LCFastSelector measureEndToEndLatencyThroughLocalHTTPPort:httpPort
                                                                       timeout:kReviveProbeTimeoutSec];
        }

        if (coreAlive && rttMs > 0) {
            // Healthy: ensure hooks stay synchronized & update live ping
            LCProxyHooksSyncPorts(httpPort, socksPort, YES);
            [mgr updateActiveNodeLatency:rttMs status:LCProxyStatusAlive];
            self->_reviveInFlight = NO;
            return;
        }

        // Step 3: Core died, port closed, or sockets went stale after iOS sleep -> Revive!
        [mgr appendLog:[NSString stringWithFormat:@"[Watchdog] Reviving proxy (reason=%@, coreAlive=%d, rtt=%ldms)",
                        reason, coreAlive, (long)rttMs]];
        [mgr setProxyStatus:LCProxyStatusWaking];

        BOOL restarted = [mgr restartActiveNodeSynchronously];
        if (restarted) {
            uint16_t newHttp = bridge.activeHttpPort;
            uint16_t newSocks = bridge.activeSocksPort;
            LCProxyHooksSyncPorts(newHttp, newSocks, YES);

            // Brief settle wait (<=80ms)
            for (int i = 0; i < 8; i++) {
                if ([LCFastSelector checkLocalLoopbackPortAlive:newHttp timeoutMs:15]) break;
                usleep(10000);
            }

            NSInteger postRestartPing = [LCFastSelector measureEndToEndLatencyThroughLocalHTTPPort:newHttp
                                                                                           timeout:kReviveProbeTimeoutSec];
            if (postRestartPing > 0) {
                [mgr updateActiveNodeLatency:postRestartPing status:LCProxyStatusAlive];
                [mgr appendLog:[NSString stringWithFormat:@"[Watchdog] Revived cleanly on port %u (%ld ms)", newHttp, (long)postRestartPing]];
                self->_reviveInFlight = NO;
                return;
            }
        }

        // Step 4: Active node failed after restart -> Instant <100ms Failover to cached backup node
        [mgr appendLog:@"[Watchdog] Active node unreachable after restart — attempting <100ms backup failover"];
        BOOL failedOver = [mgr failoverToNextCachedBackupSynchronously];
        if (failedOver) {
            uint16_t foHttp = bridge.activeHttpPort;
            NSInteger foPing = [LCFastSelector measureEndToEndLatencyThroughLocalHTTPPort:foHttp
                                                                                  timeout:kReviveProbeTimeoutSec];
            if (foPing > 0) {
                [mgr updateActiveNodeLatency:foPing status:LCProxyStatusAlive];
                [mgr appendLog:[NSString stringWithFormat:@"[Watchdog] Failover succeeded (%ld ms)", (long)foPing]];
                self->_reviveInFlight = NO;
                return;
            }
        }

        // Step 5: Cached backups exhausted -> trigger background 2-stage auto-rescan
        [mgr setProxyStatus:LCProxyStatusError];
        [mgr appendLog:@"[Watchdog] Backup cache exhausted — launching automatic fast rescan"];
        [mgr runAutoSelectFastestWithProgress:nil completion:nil];
        self->_reviveInFlight = NO;
    });
}

@end
