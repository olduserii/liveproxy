import type { RepoFile } from './types';

export const selectorAndWatchdogFiles: RepoFile[] = [
  {
    path: 'tweak/LCFastSelector.h',
    language: 'objc',
    category: 'tweak',
    summary: 'Ultra-fast 2-stage server selector: Stage-1 NWConnection TCP pool (16x, 800ms) + Stage-2 real 204 proxy latency',
    content: `#import <Foundation/Foundation.h>
#import "LCProxyNode.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^LCSelectorProgressBlock)(NSString *stageText, LCProxyNode * _Nullable updatedNode);
typedef void (^LCSelectorCompletionBlock)(NSArray<LCProxyNode *> *rankedTopNodes, NSError * _Nullable error);

@interface LCFastSelector : NSObject

+ (instancetype)sharedSelector;

@property (nonatomic, assign, readonly) BOOL isScanning;

/// Runs the 2-stage native selector:
/// Stage 1: Parallel NWConnection TCP pre-filter (concurrency=16, timeout=800ms).
/// Stage 2: Real end-to-end HTTP 204 probe through xray-rust on ephemeral local ports for top 6 candidates (timeout=2500ms).
/// Returns top ranked live nodes sorted by realPingMs ascending.
- (void)selectFastestFromNodes:(NSArray<LCProxyNode *> *)nodes
                      progress:(nullable LCSelectorProgressBlock)progress
                    completion:(LCSelectorCompletionBlock)completion;

/// Performs a single real end-to-end HTTP GET http://www.gstatic.com/generate_204
/// through an already-running local HTTP proxy port (used by Stage 2 and LCWatchdog).
/// Returns latency in milliseconds, or -1 on failure/timeout.
+ (NSInteger)measureEndToEndLatencyThroughLocalHTTPPort:(uint16_t)httpPort
                                                timeout:(NSTimeInterval)timeoutSeconds;

/// Fast local TCP handshake check to 127.0.0.1:<port> (used by LCWatchdog).
+ (BOOL)checkLocalLoopbackPortAlive:(uint16_t)port timeoutMs:(int)timeoutMs;

@end

NS_ASSUME_NONNULL_END
`,
  },
  {
    path: 'tweak/LCFastSelector.m',
    language: 'objc',
    category: 'tweak',
    summary: 'Native Network.framework NWConnection TCP pre-filter and real xray-rust HTTP 204 latency prober',
    content: `#import "LCFastSelector.h"
#import "LCXrayRustBridge.h"
#import "LCConfigNormalizer.h"
#import "LCProxyHooks.h"
#import <Network/Network.h>
#import <QuartzCore/QuartzCore.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <fcntl.h>
#import <poll.h>
#import <unistd.h>

static const NSInteger kTCPPoolConcurrency   = 16;
static const NSTimeInterval kTCPTimeoutSec   = 0.8;   // 800 ms hard timeout
static const NSUInteger kStage2TopCandidates = 6;     // Top 5-6 nodes
static const NSTimeInterval kRealProbeSec    = 2.5;   // 2500 ms hard timeout

@interface LCFastSelector () {
    dispatch_queue_t _workQueue;
    BOOL _isScanning;
}
@end

@implementation LCFastSelector

+ (instancetype)sharedSelector {
    static LCFastSelector *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[LCFastSelector alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _workQueue = dispatch_queue_create("com.lcproxy.fastselector", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (BOOL)isScanning {
    @synchronized (self) {
        return _isScanning;
    }
}

#pragma mark - Stage 1: Instant NWConnection TCP Pre-Filter

- (void)measureTCPForNode:(LCProxyNode *)node
                    queue:(dispatch_queue_t)nwQueue
               completion:(void (^)(NSInteger rttMs))completion {
    if (node.host.length == 0 || node.port == 0) {
        completion(-1);
        return;
    }

    // UDP-only protocols (Hysteria2 / WireGuard) cannot be reliably pre-filtered with TCP;
    // assign an optimistic baseline so they advance to Stage 2 real probe.
    if (node.protocol == LCProxyProtocolHysteria2 || node.protocol == LCProxyProtocolWireGuard) {
        completion(120);
        return;
    }

    NSString *portStr = [NSString stringWithFormat:@"%u", node.port];
    nw_endpoint_t endpoint = nw_endpoint_create_host(node.host.UTF8String, portStr.UTF8String);
    nw_parameters_t params = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL,
                                                             NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_connection_t conn = nw_connection_create(endpoint, params);
    nw_connection_set_queue(conn, nwQueue);

    __block BOOL finished = NO;
    CFTimeInterval startTime = CACurrentMediaTime();

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, nwQueue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTCPTimeoutSec * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              (uint64_t)(20 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(timer, ^{
        if (finished) return;
        finished = YES;
        nw_connection_cancel(conn);
        dispatch_source_cancel(timer);
        completion(-1);
    });
    dispatch_resume(timer);

    nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state, nw_error_t error) {
        if (finished) return;
        if (state == nw_connection_state_ready) {
            finished = YES;
            NSInteger ms = MAX(1, (NSInteger)llround((CACurrentMediaTime() - startTime) * 1000.0));
            dispatch_source_cancel(timer);
            nw_connection_cancel(conn);
            completion(ms);
        } else if (state == nw_connection_state_failed || state == nw_connection_state_waiting) {
            if (error != NULL || state == nw_connection_state_failed) {
                finished = YES;
                dispatch_source_cancel(timer);
                nw_connection_cancel(conn);
                completion(-1);
            }
        }
    });

    nw_connection_start(conn);
}

#pragma mark - Stage 2: Real End-to-End Proxy 204 Probe

+ (BOOL)checkLocalLoopbackPortAlive:(uint16_t)port timeoutMs:(int)timeoutMs {
    if (port == 0) return NO;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;

    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(port);

    int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (rc == 0) {
        close(fd);
        return YES;
    }

    struct pollfd pfd;
    pfd.fd = fd;
    pfd.events = POLLOUT;
    pfd.revents = 0;

    int prc = poll(&pfd, 1, timeoutMs);
    BOOL alive = NO;
    if (prc > 0 && (pfd.revents & POLLOUT)) {
        int err = 0;
        socklen_t len = sizeof(err);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0) {
            alive = YES;
        }
    }
    close(fd);
    return alive;
}

+ (NSInteger)measureEndToEndLatencyThroughLocalHTTPPort:(uint16_t)httpPort
                                                timeout:(NSTimeInterval)timeoutSeconds {
    if (httpPort == 0) return -1;

    // Raw HTTP-proxy request directly to 127.0.0.1:<httpPort> to guarantee zero swizzle interference
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct timeval tv;
    tv.tv_sec = (time_t)timeoutSeconds;
    tv.tv_usec = (suseconds_t)((timeoutSeconds - floor(timeoutSeconds)) * 1000000.0);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    int nosig = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, sizeof(nosig));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(httpPort);

    CFTimeInterval t0 = CACurrentMediaTime();
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }

    const char *req =
        "GET http://www.gstatic.com/generate_204 HTTP/1.1\\r\\n"
        "Host: www.gstatic.com\\r\\n"
        "User-Agent: Mozilla/5.0\\r\\n"
        "Connection: close\\r\\n\\r\\n";

    ssize_t sent = send(fd, req, strlen(req), 0);
    if (sent <= 0) {
        close(fd);
        return -1;
    }

    char buf[256];
    memset(buf, 0, sizeof(buf));
    ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
    close(fd);

    if (n <= 0) return -1;

    // Accept HTTP 204 (or 200/302 captive-free response)
    if (strstr(buf, " 204") != NULL || strstr(buf, " 200") != NULL) {
        NSInteger rtt = MAX(1, (NSInteger)llround((CACurrentMediaTime() - t0) * 1000.0));
        return rtt;
    }
    return -1;
}

#pragma mark - Two-Stage Pipeline

- (void)selectFastestFromNodes:(NSArray<LCProxyNode *> *)nodes
                      progress:(nullable LCSelectorProgressBlock)progress
                    completion:(LCSelectorCompletionBlock)completion {
    if (nodes.count == 0) {
        if (completion) {
            completion(@[], [NSError errorWithDomain:@"LCFastSelector"
                                                code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"Нет серверов для проверки"}]);
        }
        return;
    }

    @synchronized (self) {
        if (_isScanning) {
            if (completion) {
                completion(@[], [NSError errorWithDomain:@"LCFastSelector"
                                                    code:2
                                                userInfo:@{NSLocalizedDescriptionKey: @"Сканирование уже выполняется"}]);
            }
            return;
        }
        _isScanning = YES;
    }

    dispatch_async(_workQueue, ^{
        dispatch_queue_t nwQueue = dispatch_queue_create("com.lcproxy.selector.nw", DISPATCH_QUEUE_SERIAL);
        dispatch_semaphore_t pool = dispatch_semaphore_create(kTCPPoolConcurrency);
        dispatch_group_t tcpGroup = dispatch_group_create();

        if (progress) {
            dispatch_async(dispatch_get_main_queue(), ^{
                progress([NSString stringWithFormat:@"Этап 1/2: TCP-префильтр (%lu узлов)...", (unsigned long)nodes.count], nil);
            });
        }

        // Reset old metrics
        for (LCProxyNode *n in nodes) {
            n.tcpPingMs = -1;
            n.realPingMs = -1;
        }

        // Stage 1: Parallel TCP pre-filter (16 concurrent sockets, 800 ms timeout)
        for (LCProxyNode *node in nodes) {
            dispatch_group_enter(tcpGroup);
            dispatch_async(self->_workQueue, ^{
                dispatch_semaphore_wait(pool, DISPATCH_TIME_FOREVER);
                [self measureTCPForNode:node queue:nwQueue completion:^(NSInteger rttMs) {
                    node.tcpPingMs = rttMs;
                    dispatch_semaphore_signal(pool);
                    if (progress && rttMs > 0) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            progress(@"Этап 1/2: TCP-префильтр...", node);
                        });
                    }
                    dispatch_group_leave(tcpGroup);
                }];
            });
        }

        dispatch_group_wait(tcpGroup, DISPATCH_TIME_FOREVER);

        // Sort reachable TCP candidates
        NSMutableArray<LCProxyNode *> *tcpAlive = [NSMutableArray array];
        for (LCProxyNode *n in nodes) {
            if (n.tcpPingMs > 0) [tcpAlive addObject:n];
        }
        [tcpAlive sortUsingComparator:^NSComparisonResult(LCProxyNode *a, LCProxyNode *b) {
            if (a.tcpPingMs == b.tcpPingMs) return NSOrderedSame;
            return a.tcpPingMs < b.tcpPingMs ? NSOrderedAscending : NSOrderedDescending;
        }];

        if (tcpAlive.count == 0) {
            @synchronized (self) { self->_isScanning = NO; }
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(@[], [NSError errorWithDomain:@"LCFastSelector"
                                                    code:3
                                                userInfo:@{NSLocalizedDescriptionKey: @"Ни один сервер не ответил на TCP-префильтр"}]);
            });
            return;
        }

        NSUInteger topCount = MIN(kStage2TopCandidates, tcpAlive.count);
        NSArray<LCProxyNode *> *candidates = [tcpAlive subarrayWithRange:NSMakeRange(0, topCount)];

        if (progress) {
            dispatch_async(dispatch_get_main_queue(), ^{
                progress([NSString stringWithFormat:@"Этап 2/2: Реальный тест 204 (%lu лучших)...", (unsigned long)candidates.count], nil);
            });
        }

        // Stage 2: Real end-to-end latency test through xray-rust on temporary local ports
        LCXrayRustBridge *bridge = [LCXrayRustBridge sharedBridge];
        BOOL concurrent = [bridge supportsConcurrentProbes];
        dispatch_group_t probeGroup = dispatch_group_create();
        dispatch_semaphore_t probeSem = dispatch_semaphore_create(concurrent ? (long)topCount : 1);

        for (LCProxyNode *candidate in candidates) {
            dispatch_group_enter(probeGroup);
            dispatch_async(self->_workQueue, ^{
                dispatch_semaphore_wait(probeSem, DISPATCH_TIME_FOREVER);

                uint16_t tmpSocks = [bridge allocateFreeLocalPort];
                uint16_t tmpHttp  = [bridge allocateFreeLocalPort];
                NSError *cfgErr = nil;
                NSString *json = [LCConfigNormalizer buildStrictXrayJSONForNode:candidate
                                                                      socksPort:tmpSocks
                                                                       httpPort:tmpHttp
                                                                          error:&cfgErr];
                if (json.length > 0 && tmpHttp > 0) {
                    NSError *startErr = nil;
                    LCXrayProbeHandle *handle = [bridge startProbeWithJSONConfig:json
                                                                       socksPort:tmpSocks
                                                                        httpPort:tmpHttp
                                                                           error:&startErr];
                    if (handle) {
                        // Brief wait (<=60ms) until xray-rust binds local HTTP listener
                        for (int attempt = 0; attempt < 6; attempt++) {
                            if ([LCFastSelector checkLocalLoopbackPortAlive:tmpHttp timeoutMs:15]) break;
                            usleep(10000);
                        }
                        NSInteger realMs = [LCFastSelector measureEndToEndLatencyThroughLocalHTTPPort:tmpHttp
                                                                                              timeout:kRealProbeSec];
                        candidate.realPingMs = realMs;
                        [bridge stopProbeHandle:handle];
                    }
                }

                if (progress) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        progress(@"Этап 2/2: Реальный тест 204...", candidate);
                    });
                }

                dispatch_semaphore_signal(probeSem);
                dispatch_group_leave(probeGroup);
            });
        }

        dispatch_group_wait(probeGroup, DISPATCH_TIME_FOREVER);

        NSMutableArray<LCProxyNode *> *verified = [NSMutableArray array];
        for (LCProxyNode *c in candidates) {
            if (c.realPingMs > 0) [verified addObject:c];
        }
        [verified sortUsingComparator:^NSComparisonResult(LCProxyNode *a, LCProxyNode *b) {
            if (a.realPingMs == b.realPingMs) return NSOrderedSame;
            return a.realPingMs < b.realPingMs ? NSOrderedAscending : NSOrderedDescending;
        }];

        @synchronized (self) { self->_isScanning = NO; }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (verified.count > 0) {
                completion(verified, nil);
            } else {
                // Fallback to fastest TCP candidate if 204 endpoint was blocked/timed out
                completion(candidates, [NSError errorWithDomain:@"LCFastSelector"
                                                           code:4
                                                       userInfo:@{NSLocalizedDescriptionKey: @"Нет ответа 204; показаны лучшие по TCP"}]);
            }
        });
    });
}

@end
`,
  },
  {
    path: 'tweak/LCWatchdog.h',
    language: 'objc',
    category: 'tweak',
    summary: 'Lifecycle & NWPathMonitor Watchdog with 20s heartbeat and instant wake-up/failover revival',
    content: `#import <Foundation/Foundation.h>

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
`,
  },
  {
    path: 'tweak/LCWatchdog.m',
    language: 'objc',
    category: 'tweak',
    summary: 'Complete sleep/unlock/Wi-Fi-5G watchdog running strictly on a serial queue with battery-aware heartbeat',
    content: `#import "LCWatchdog.h"
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
`,
  },
];
