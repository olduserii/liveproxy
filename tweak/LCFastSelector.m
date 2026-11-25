#import "LCFastSelector.h"
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
        "GET http://www.gstatic.com/generate_204 HTTP/1.1\r\n"
        "Host: www.gstatic.com\r\n"
        "User-Agent: Mozilla/5.0\r\n"
        "Connection: close\r\n\r\n";

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
