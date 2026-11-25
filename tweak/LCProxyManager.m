#import "LCProxyManager.h"
#import "LCXrayRustBridge.h"
#import "LCConfigNormalizer.h"
#import "LCProxyHooks.h"
#import <stdlib.h>

NSNotificationName const LCProxyStateDidChangeNotification = @"LCProxyStateDidChangeNotification";
NSNotificationName const LCProxyLogsDidUpdateNotification  = @"LCProxyLogsDidUpdateNotification";

static const NSUInteger kMaxLogLines = 400;
static const NSTimeInterval kAutoUpdateIntervalSec = 6 * 3600; // 6 hours

@implementation LCSubscriptionItem

- (NSDictionary<NSString *, id> *)toDictionary {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"subID"] = self.subID ?: [[NSUUID UUID] UUIDString];
    d[@"name"] = self.name ?: @"Subscription";
    d[@"url"] = self.url ?: @"";
    if (self.usageSummary) d[@"usageSummary"] = self.usageSummary;
    d[@"lastUpdated"] = @(self.lastUpdated);
    d[@"nodeCount"] = @(self.nodeCount);
    return d;
}

+ (nullable instancetype)itemFromDictionary:(NSDictionary<NSString *, id> *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    NSString *url = dict[@"url"];
    if (![url isKindOfClass:[NSString class]] || url.length == 0) return nil;
    LCSubscriptionItem *item = [[LCSubscriptionItem alloc] init];
    item.subID = [dict[@"subID"] isKindOfClass:[NSString class]] ? dict[@"subID"] : [[NSUUID UUID] UUIDString];
    item.name = [dict[@"name"] isKindOfClass:[NSString class]] ? dict[@"name"] : @"Subscription";
    item.url = url;
    if ([dict[@"usageSummary"] isKindOfClass:[NSString class]]) item.usageSummary = dict[@"usageSummary"];
    item.lastUpdated = [dict[@"lastUpdated"] doubleValue];
    item.nodeCount = [dict[@"nodeCount"] unsignedIntegerValue];
    return item;
}

@end

@interface LCProxyManager () {
    dispatch_queue_t _stateQueue;
    BOOL _proxyEnabled;
    LCProxyStatus _status;
    BOOL _autoUpdateSubscriptions;
    NSString *_activeNodeID;
    NSInteger _activePingMs;

    NSMutableArray<LCProxyNode *> *_nodes;
    NSMutableArray<LCSubscriptionItem *> *_subscriptions;
    NSMutableArray<NSString *> *_backupNodeIDs;
    NSMutableArray<NSString *> *_logs;
    NSUInteger _backupCursor;
    NSString *_storageDir;
}
@end

@implementation LCProxyManager

+ (instancetype)sharedManager {
    static LCProxyManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[LCProxyManager alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _stateQueue = dispatch_queue_create("com.lcproxy.manager.state", DISPATCH_QUEUE_SERIAL);
        _nodes = [NSMutableArray array];
        _subscriptions = [NSMutableArray array];
        _backupNodeIDs = [NSMutableArray array];
        _logs = [NSMutableArray array];
        _activePingMs = -1;
        _autoUpdateSubscriptions = YES;
        _storageDir = [self resolveSharedStorageDirectory];

        __weak typeof(self) weakSelf = self;
        [LCXrayRustBridge sharedBridge].logHandler = ^(NSString *message) {
            [weakSelf appendLog:message];
        };
    }
    return self;
}

#pragma mark - Shared Container Storage (Application Support/LCProxy/)

- (NSString *)resolveSharedStorageDirectory {
    // Inside LiveContainer guest apps, LC_HOME_PATH or container Application Support points to shared storage
    const char *lcHome = getenv("LC_HOME_PATH");
    NSString *baseDir = nil;
    if (lcHome && strlen(lcHome) > 0) {
        baseDir = [[NSString stringWithUTF8String:lcHome]
                   stringByAppendingPathComponent:@"Library/Application Support/LCProxy"];
    } else {
        NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
        NSString *appSupport = paths.firstObject ?: NSTemporaryDirectory();
        baseDir = [appSupport stringByAppendingPathComponent:@"LCProxy"];
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:baseDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return baseDir;
}

- (NSString *)sharedStorageDirectory {
    return _storageDir;
}

- (NSString *)pathForStorageFile:(NSString *)filename {
    return [_storageDir stringByAppendingPathComponent:filename];
}

- (void)loadPersistedStateLocked {
    NSData *stateData = [NSData dataWithContentsOfFile:[self pathForStorageFile:@"state.json"]];
    if (stateData) {
        NSDictionary *st = [NSJSONSerialization JSONObjectWithData:stateData options:0 error:nil];
        if ([st isKindOfClass:[NSDictionary class]]) {
            _proxyEnabled = [st[@"proxyEnabled"] boolValue];
            _autoUpdateSubscriptions = st[@"autoUpdateSubscriptions"] ? [st[@"autoUpdateSubscriptions"] boolValue] : YES;
            if ([st[@"activeNodeID"] isKindOfClass:[NSString class]]) _activeNodeID = st[@"activeNodeID"];
            if ([st[@"backupNodeIDs"] isKindOfClass:[NSArray class]]) {
                [_backupNodeIDs setArray:st[@"backupNodeIDs"]];
            }
        }
    }

    NSData *subsData = [NSData dataWithContentsOfFile:[self pathForStorageFile:@"subscriptions.json"]];
    if (subsData) {
        NSArray *arr = [NSJSONSerialization JSONObjectWithData:subsData options:0 error:nil];
        if ([arr isKindOfClass:[NSArray class]]) {
            [_subscriptions removeAllObjects];
            for (id item in arr) {
                LCSubscriptionItem *sub = [LCSubscriptionItem itemFromDictionary:item];
                if (sub) [_subscriptions addObject:sub];
            }
        }
    }

    NSData *nodesData = [NSData dataWithContentsOfFile:[self pathForStorageFile:@"nodes.json"]];
    if (nodesData) {
        NSArray *arr = [NSJSONSerialization JSONObjectWithData:nodesData options:0 error:nil];
        if ([arr isKindOfClass:[NSArray class]]) {
            [_nodes removeAllObjects];
            for (id item in arr) {
                LCProxyNode *n = [LCProxyNode nodeFromDictionary:item];
                if (n) [_nodes addObject:n];
            }
        }
    }
}

- (void)savePersistedStateLocked {
    NSMutableDictionary *st = [NSMutableDictionary dictionary];
    st[@"proxyEnabled"] = @(_proxyEnabled);
    st[@"autoUpdateSubscriptions"] = @(_autoUpdateSubscriptions);
    if (_activeNodeID) st[@"activeNodeID"] = _activeNodeID;
    st[@"backupNodeIDs"] = [_backupNodeIDs copy];

    NSData *stData = [NSJSONSerialization dataWithJSONObject:st options:NSJSONWritingPrettyPrinted error:nil];
    if (stData) [stData writeToFile:[self pathForStorageFile:@"state.json"] atomically:YES];

    NSMutableArray *subDicts = [NSMutableArray arrayWithCapacity:_subscriptions.count];
    for (LCSubscriptionItem *s in _subscriptions) [subDicts addObject:[s toDictionary]];
    NSData *subsData = [NSJSONSerialization dataWithJSONObject:subDicts options:NSJSONWritingPrettyPrinted error:nil];
    if (subsData) [subsData writeToFile:[self pathForStorageFile:@"subscriptions.json"] atomically:YES];

    NSMutableArray *nodeDicts = [NSMutableArray arrayWithCapacity:_nodes.count];
    for (LCProxyNode *n in _nodes) [nodeDicts addObject:[n toDictionary]];
    NSData *nodesData = [NSJSONSerialization dataWithJSONObject:nodeDicts options:0 error:nil];
    if (nodesData) [nodesData writeToFile:[self pathForStorageFile:@"nodes.json"] atomically:YES];
}

- (void)notifyStateChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:LCProxyStateDidChangeNotification object:self];
    });
}

#pragma mark - Accessors

- (BOOL)proxyEnabled {
    __block BOOL v = NO;
    dispatch_sync(_stateQueue, ^{ v = self->_proxyEnabled; });
    return v;
}

- (LCProxyStatus)status {
    __block LCProxyStatus s = LCProxyStatusOff;
    dispatch_sync(_stateQueue, ^{ s = self->_status; });
    return s;
}

- (BOOL)autoUpdateSubscriptions {
    __block BOOL v = YES;
    dispatch_sync(_stateQueue, ^{ v = self->_autoUpdateSubscriptions; });
    return v;
}

- (void)setAutoUpdateSubscriptions:(BOOL)autoUpdateSubscriptions {
    dispatch_async(_stateQueue, ^{
        self->_autoUpdateSubscriptions = autoUpdateSubscriptions;
        [self savePersistedStateLocked];
        [self notifyStateChanged];
    });
}

- (nullable LCProxyNode *)activeNodeLocked {
    if (_activeNodeID.length > 0) {
        for (LCProxyNode *n in _nodes) {
            if ([n.nodeID isEqualToString:_activeNodeID]) return n;
        }
    }
    return _nodes.firstObject;
}

- (nullable LCProxyNode *)activeNode {
    __block LCProxyNode *node = nil;
    dispatch_sync(_stateQueue, ^{ node = [[self activeNodeLocked] copy]; });
    return node;
}

- (NSInteger)activePingMs {
    __block NSInteger p = -1;
    dispatch_sync(_stateQueue, ^{ p = self->_activePingMs; });
    return p;
}

- (NSArray<LCProxyNode *> *)nodes {
    __block NSArray *copy = nil;
    dispatch_sync(_stateQueue, ^{ copy = [self->_nodes copy]; });
    return copy;
}

- (NSArray<LCSubscriptionItem *> *)subscriptions {
    __block NSArray *copy = nil;
    dispatch_sync(_stateQueue, ^{ copy = [self->_subscriptions copy]; });
    return copy;
}

- (NSArray<NSString *> *)backupNodeIDs {
    __block NSArray *copy = nil;
    dispatch_sync(_stateQueue, ^{ copy = [self->_backupNodeIDs copy]; });
    return copy;
}

- (NSArray<NSString *> *)logs {
    __block NSArray *copy = nil;
    dispatch_sync(_stateQueue, ^{ copy = [self->_logs copy]; });
    return copy;
}

- (NSString *)statusDisplayText {
    switch (self.status) {
        case LCProxyStatusAlive:  return @"Жив";
        case LCProxyStatusWaking: return @"Пробуждение";
        case LCProxyStatusError:  return @"Ошибка";
        case LCProxyStatusOff:
        default:                  return @"Выкл";
    }
}

#pragma mark - Bootstrap & Core Control

- (void)bootstrapOnLaunch {
    dispatch_async(_stateQueue, ^{
        [self loadPersistedStateLocked];
        NSString *ver = [[LCXrayRustBridge sharedBridge] coreVersionString];
        [self appendLogLocked:[NSString stringWithFormat:@"[Core] Initialized (%@) storage=%@", ver, self->_storageDir]];

        if (self->_proxyEnabled) {
            LCProxyNode *node = [self activeNodeLocked];
            if (node) {
                NSError *err = nil;
                BOOL ok = [self startEngineForNodeLocked:node error:&err];
                if (!ok) {
                    self->_status = LCProxyStatusError;
                    [self appendLogLocked:[NSString stringWithFormat:@"[Core] Launch start failed: %@", err.localizedDescription]];
                }
            }
        }

        // Check if subscriptions need auto-refresh
        if (self->_autoUpdateSubscriptions && self->_subscriptions.count > 0) {
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            BOOL needsRefresh = NO;
            for (LCSubscriptionItem *sub in self->_subscriptions) {
                if ((now - sub.lastUpdated) > kAutoUpdateIntervalSec) {
                    needsRefresh = YES;
                    break;
                }
            }
            if (needsRefresh) {
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    [self refreshAllSubscriptionsWithCompletion:nil];
                });
            }
        }

        [self notifyStateChanged];
    });
}

- (BOOL)startEngineForNodeLocked:(LCProxyNode *)node error:(NSError **)error {
    LCXrayRustBridge *bridge = [LCXrayRustBridge sharedBridge];
    uint16_t socksPort = [bridge allocateFreeLocalPort];
    uint16_t httpPort  = [bridge allocateFreeLocalPort];
    if (socksPort == 0 || httpPort == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"LCProxyManager"
                                         code:100
                                     userInfo:@{NSLocalizedDescriptionKey: @"Не удалось выделить локальный порт"}];
        }
        return NO;
    }

    NSString *strictJSON = [LCConfigNormalizer buildStrictXrayJSONForNode:node
                                                                socksPort:socksPort
                                                                 httpPort:httpPort
                                                                    error:error];
    if (strictJSON.length == 0) return NO;

    BOOL started = [bridge startWithJSONConfig:strictJSON socksPort:socksPort httpPort:httpPort error:error];
    if (!started) {
        LCProxyHooksSyncPorts(0, 0, NO);
        _status = LCProxyStatusError;
        return NO;
    }

    _activeNodeID = node.nodeID;
    _proxyEnabled = YES;
    _status = LCProxyStatusAlive;
    _activePingMs = node.realPingMs > 0 ? node.realPingMs : node.tcpPingMs;
    LCProxyHooksSyncPorts(httpPort, socksPort, YES);
    [self savePersistedStateLocked];
    [self appendLogLocked:[NSString stringWithFormat:@"[Core] Active -> %@ (%@) HTTP:%u SOCKS:%u",
                           node.name, [node protocolBadgeText], httpPort, socksPort]];
    return YES;
}

- (void)setProxyEnabled:(BOOL)enabled completion:(nullable void (^)(BOOL, NSError *))completion {
    dispatch_async(_stateQueue, ^{
        NSError *err = nil;
        BOOL ok = YES;
        if (enabled) {
            LCProxyNode *target = [self activeNodeLocked];
            if (!target) {
                ok = NO;
                err = [NSError errorWithDomain:@"LCProxyManager"
                                          code:101
                                      userInfo:@{NSLocalizedDescriptionKey: @"Добавьте подписку или вставьте ключ/JSON"}];
                self->_proxyEnabled = NO;
                self->_status = LCProxyStatusOff;
            } else {
                ok = [self startEngineForNodeLocked:target error:&err];
            }
        } else {
            self->_proxyEnabled = NO;
            self->_status = LCProxyStatusOff;
            self->_activePingMs = -1;
            LCProxyHooksSyncPorts(0, 0, NO);
            [[LCXrayRustBridge sharedBridge] stopPrimaryInstance];
            [self savePersistedStateLocked];
            [self appendLogLocked:@"[Core] Proxy switched OFF by user"];
        }
        [self notifyStateChanged];
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, err); });
        }
    });
}

- (void)activateNode:(LCProxyNode *)node completion:(nullable void (^)(BOOL, NSError *))completion {
    if (!node) return;
    dispatch_async(_stateQueue, ^{
        NSError *err = nil;
        BOOL ok = [self startEngineForNodeLocked:node error:&err];
        [self notifyStateChanged];
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, err); });
        }
    });
}

- (BOOL)restartActiveNodeSynchronously {
    __block BOOL ok = NO;
    dispatch_sync(_stateQueue, ^{
        LCProxyNode *node = [self activeNodeLocked];
        if (!node) return;
        NSError *err = nil;
        ok = [self startEngineForNodeLocked:node error:&err];
        if (!ok) {
            [self appendLogLocked:[NSString stringWithFormat:@"[Core] Restart failed: %@", err.localizedDescription]];
        }
        [self notifyStateChanged];
    });
    return ok;
}

- (BOOL)failoverToNextCachedBackupSynchronously {
    __block BOOL ok = NO;
    dispatch_sync(_stateQueue, ^{
        if (self->_backupNodeIDs.count == 0) return;
        NSUInteger tries = self->_backupNodeIDs.count;
        for (NSUInteger i = 0; i < tries; i++) {
            self->_backupCursor = (self->_backupCursor + 1) % self->_backupNodeIDs.count;
            NSString *candID = self->_backupNodeIDs[self->_backupCursor];
            if ([candID isEqualToString:self->_activeNodeID] && tries > 1) continue;

            LCProxyNode *cand = nil;
            for (LCProxyNode *n in self->_nodes) {
                if ([n.nodeID isEqualToString:candID]) { cand = n; break; }
            }
            if (!cand) continue;

            NSError *err = nil;
            if ([self startEngineForNodeLocked:cand error:&err]) {
                [self appendLogLocked:[NSString stringWithFormat:@"[Failover] Switched in <100ms to backup -> %@", cand.name]];
                ok = YES;
                break;
            }
        }
        [self notifyStateChanged];
    });
    return ok;
}

#pragma mark - Fast 2-Stage Auto-Selection

- (void)runAutoSelectFastestWithProgress:(nullable LCSelectorProgressBlock)progress
                              completion:(nullable void (^)(LCProxyNode *, NSError *))completion {
    NSArray<LCProxyNode *> *snapshot = self.nodes;
    [self appendLog:[NSString stringWithFormat:@"[Selector] Starting 2-stage scan on %lu nodes", (unsigned long)snapshot.count]];

    [[LCFastSelector sharedSelector] selectFastestFromNodes:snapshot
                                                   progress:progress
                                                 completion:^(NSArray<LCProxyNode *> *rankedTopNodes, NSError *error) {
        if (rankedTopNodes.count == 0) {
            [self appendLog:[NSString stringWithFormat:@"[Selector] Scan failed: %@", error.localizedDescription]];
            if (completion) completion(nil, error);
            return;
        }

        LCProxyNode *best = rankedTopNodes.firstObject;
        dispatch_async(self->_stateQueue, ^{
            // Cache top-3 fastest live servers for <100ms failover
            [self->_backupNodeIDs removeAllObjects];
            NSUInteger cacheCount = MIN((NSUInteger)3, rankedTopNodes.count);
            for (NSUInteger i = 0; i < cacheCount; i++) {
                [self->_backupNodeIDs addObject:rankedTopNodes[i].nodeID];
            }
            self->_backupCursor = 0;

            // Persist measured pings onto stored nodes
            NSMutableDictionary<NSString *, LCProxyNode *> *byID = [NSMutableDictionary dictionary];
            for (LCProxyNode *r in rankedTopNodes) byID[r.nodeID] = r;
            for (LCProxyNode *stored in self->_nodes) {
                LCProxyNode *u = byID[stored.nodeID];
                if (u) {
                    stored.tcpPingMs = u.tcpPingMs;
                    stored.realPingMs = u.realPingMs;
                }
            }

            NSError *startErr = nil;
            [self startEngineForNodeLocked:best error:&startErr];
            [self appendLogLocked:[NSString stringWithFormat:@"[Selector] Best=%@ (%ld ms), cached %lu failover backups",
                                   best.name, (long)(best.realPingMs > 0 ? best.realPingMs : best.tcpPingMs),
                                   (unsigned long)self->_backupNodeIDs.count]];
            [self notifyStateChanged];

            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(best, startErr);
                });
            }
        });
    }];
}

#pragma mark - Subscriptions & Clipboard Import

- (void)addSubscriptionURL:(NSString *)url
                      name:(nullable NSString *)name
                completion:(void (^)(BOOL, NSString *))completion {
    NSString *trimmed = [url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        completion(NO, @"URL не может быть пустым");
        return;
    }

    NSString *subID = [[NSUUID UUID] UUIDString];
    [self appendLog:[NSString stringWithFormat:@"[Sub] Fetching %@", trimmed]];

    [LCConfigNormalizer fetchSubscriptionFromURL:trimmed
                                  subscriptionID:subID
                                      completion:^(NSArray<LCProxyNode *> *nodes, LCSubscriptionInfo *info, NSError *error) {
        if (error || nodes.count == 0) {
            [self appendLog:[NSString stringWithFormat:@"[Sub] Fetch failed: %@", error.localizedDescription]];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, error.localizedDescription ?: @"Не найдено ни одного узла");
            });
            return;
        }

        dispatch_async(self->_stateQueue, ^{
            LCSubscriptionItem *sub = [[LCSubscriptionItem alloc] init];
            sub.subID = subID;
            sub.url = trimmed;
            sub.name = name.length > 0 ? name : (info.profileTitle.length > 0 ? info.profileTitle : ([NSURL URLWithString:trimmed].host ?: @"Подписка"));
            sub.usageSummary = [info formattedUsageSummary];
            sub.lastUpdated = [[NSDate date] timeIntervalSince1970];
            sub.nodeCount = nodes.count;

            [self->_subscriptions addObject:sub];
            [self->_nodes addObjectsFromArray:nodes];
            if (!self->_activeNodeID && nodes.firstObject) {
                self->_activeNodeID = nodes.firstObject.nodeID;
            }
            [self savePersistedStateLocked];
            [self appendLogLocked:[NSString stringWithFormat:@"[Sub] Added '%@' (%lu nodes)", sub.name, (unsigned long)nodes.count]];
            [self notifyStateChanged];

            dispatch_async(dispatch_get_main_queue(), ^{
                completion(YES, [NSString stringWithFormat:@"Добавлено узлов: %lu", (unsigned long)nodes.count]);
            });
        });
    }];
}

- (void)refreshAllSubscriptionsWithCompletion:(nullable void (^)(NSUInteger, NSError *))completion {
    NSArray<LCSubscriptionItem *> *subs = self.subscriptions;
    if (subs.count == 0) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(0, nil); });
        return;
    }

    dispatch_group_t grp = dispatch_group_create();
    __block NSUInteger totalAdded = 0;
    __block NSError *lastErr = nil;

    for (LCSubscriptionItem *sub in subs) {
        dispatch_group_enter(grp);
        [LCConfigNormalizer fetchSubscriptionFromURL:sub.url
                                      subscriptionID:sub.subID
                                          completion:^(NSArray<LCProxyNode *> *nodes, LCSubscriptionInfo *info, NSError *error) {
            if (nodes.count > 0) {
                dispatch_async(self->_stateQueue, ^{
                    // Replace old nodes belonging to this subscription
                    NSPredicate *keepPred = [NSPredicate predicateWithBlock:^BOOL(LCProxyNode *n, NSDictionary *b) {
                        return ![n.subscriptionID isEqualToString:sub.subID];
                    }];
                    [self->_nodes filterUsingPredicate:keepPred];
                    [self->_nodes addObjectsFromArray:nodes];

                    for (LCSubscriptionItem *s in self->_subscriptions) {
                        if ([s.subID isEqualToString:sub.subID]) {
                            s.lastUpdated = [[NSDate date] timeIntervalSince1970];
                            s.nodeCount = nodes.count;
                            if (info.profileTitle.length > 0) s.name = info.profileTitle;
                            if (info) s.usageSummary = [info formattedUsageSummary];
                            break;
                        }
                    }
                    totalAdded += nodes.count;
                    [self savePersistedStateLocked];
                    [self appendLogLocked:[NSString stringWithFormat:@"[Sub] Refreshed '%@': %lu nodes", sub.name, (unsigned long)nodes.count]];
                    [self notifyStateChanged];
                    dispatch_group_leave(grp);
                });
            } else {
                lastErr = error;
                [self appendLog:[NSString stringWithFormat:@"[Sub] Refresh failed for '%@': %@", sub.name, error.localizedDescription]];
                dispatch_group_leave(grp);
            }
        }];
    }

    dispatch_group_notify(grp, dispatch_get_main_queue(), ^{
        if (completion) completion(totalAdded, totalAdded > 0 ? nil : lastErr);
    });
}

- (void)removeSubscriptionWithID:(NSString *)subID {
    dispatch_async(_stateQueue, ^{
        [self->_subscriptions filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(LCSubscriptionItem *s, NSDictionary *b) {
            return ![s.subID isEqualToString:subID];
        }]];
        [self->_nodes filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(LCProxyNode *n, NSDictionary *b) {
            return ![n.subscriptionID isEqualToString:subID];
        }]];
        [self savePersistedStateLocked];
        [self appendLogLocked:[NSString stringWithFormat:@"[Sub] Removed subscription %@", subID]];
        [self notifyStateChanged];
    });
}

- (NSArray<LCProxyNode *> *)importFromClipboardOrText:(NSString *)rawText error:(NSError **)error {
    NSArray<LCProxyNode *> *parsed = [LCConfigNormalizer parseAnyPayload:rawText subscriptionID:nil error:error];
    if (parsed.count == 0) return @[];

    dispatch_sync(_stateQueue, ^{
        [self->_nodes insertObjects:parsed atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, parsed.count)]];
        if (!self->_activeNodeID) self->_activeNodeID = parsed.firstObject.nodeID;
        [self savePersistedStateLocked];
        [self appendLogLocked:[NSString stringWithFormat:@"[Parser] Imported %lu node(s) -> normalized to standard URI", (unsigned long)parsed.count]];
        [self notifyStateChanged];
    });
    return parsed;
}

- (void)removeNodeWithID:(NSString *)nodeID {
    dispatch_async(_stateQueue, ^{
        [self->_nodes filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(LCProxyNode *n, NSDictionary *b) {
            return ![n.nodeID isEqualToString:nodeID];
        }]];
        [self->_backupNodeIDs removeObject:nodeID];
        [self savePersistedStateLocked];
        [self notifyStateChanged];
    });
}

#pragma mark - Status & Ring-Buffer Logging

- (void)setProxyStatus:(LCProxyStatus)status {
    dispatch_async(_stateQueue, ^{
        self->_status = status;
        [self notifyStateChanged];
    });
}

- (void)updateActiveNodeLatency:(NSInteger)pingMs status:(LCProxyStatus)status {
    dispatch_async(_stateQueue, ^{
        self->_activePingMs = pingMs;
        self->_status = status;
        LCProxyNode *active = [self activeNodeLocked];
        if (active && pingMs > 0) active.realPingMs = pingMs;
        [self notifyStateChanged];
    });
}

- (void)appendLogLocked:(NSString *)line {
    static NSDateFormatter *df = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss";
    });
    NSString *entry = [NSString stringWithFormat:@"%@ %@", [df stringFromDate:[NSDate date]], line ?: @""];
    [_logs addObject:entry];
    if (_logs.count > kMaxLogLines) {
        [_logs removeObjectsInRange:NSMakeRange(0, _logs.count - kMaxLogLines)];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:LCProxyLogsDidUpdateNotification object:self];
    });
}

- (void)appendLog:(NSString *)line {
    dispatch_async(_stateQueue, ^{
        [self appendLogLocked:line];
    });
}

- (void)clearLogs {
    dispatch_async(_stateQueue, ^{
        [self->_logs removeAllObjects];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:LCProxyLogsDidUpdateNotification object:self];
        });
    });
}

- (NSString *)joinedLogsText {
    return [self.logs componentsJoinedByString:@"\n"];
}

@end
