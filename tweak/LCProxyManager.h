#import <Foundation/Foundation.h>
#import "LCProxyNode.h"
#import "LCFastSelector.h"

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const LCProxyStateDidChangeNotification;
extern NSNotificationName const LCProxyLogsDidUpdateNotification;

typedef NS_ENUM(NSInteger, LCProxyStatus) {
    LCProxyStatusOff = 0,
    LCProxyStatusAlive,
    LCProxyStatusWaking,
    LCProxyStatusError
};

@interface LCSubscriptionItem : NSObject
@property (nonatomic, copy) NSString *subID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy, nullable) NSString *usageSummary;
@property (nonatomic, assign) NSTimeInterval lastUpdated;
@property (nonatomic, assign) NSUInteger nodeCount;
- (NSDictionary<NSString *, id> *)toDictionary;
+ (nullable instancetype)itemFromDictionary:(NSDictionary<NSString *, id> *)dict;
@end

@interface LCProxyManager : NSObject

+ (instancetype)sharedManager;

// State
@property (nonatomic, assign, readonly) BOOL proxyEnabled;
@property (nonatomic, assign, readonly) LCProxyStatus status;
@property (nonatomic, assign) BOOL autoUpdateSubscriptions;
@property (nonatomic, strong, readonly, nullable) LCProxyNode *activeNode;
@property (nonatomic, assign, readonly) NSInteger activePingMs;

// Data snapshots
@property (nonatomic, copy, readonly) NSArray<LCProxyNode *> *nodes;
@property (nonatomic, copy, readonly) NSArray<LCSubscriptionItem *> *subscriptions;
@property (nonatomic, copy, readonly) NSArray<NSString *> *backupNodeIDs;
@property (nonatomic, copy, readonly) NSArray<NSString *> *logs;

/// Shared storage directory: Application Support/LCProxy/
- (NSString *)sharedStorageDirectory;

/// Bootstraps persisted state, logs core version, and starts proxy if previously enabled.
- (void)bootstrapOnLaunch;

/// Master Proxy ON / OFF toggle.
- (void)setProxyEnabled:(BOOL)enabled completion:(nullable void (^)(BOOL ok, NSError * _Nullable error))completion;

/// Selects a specific node and starts xray-rust if proxy is ON (or enables proxy immediately).
- (void)activateNode:(LCProxyNode *)node completion:(nullable void (^)(BOOL ok, NSError * _Nullable error))completion;

/// Synchronously restarts the current active node (invoked on Watchdog serial queue).
- (BOOL)restartActiveNodeSynchronously;

/// Instantly switches to next fastest cached backup node (<100ms, no full rescan).
- (BOOL)failoverToNextCachedBackupSynchronously;

/// Runs the 2-stage fast selector, caches top-3 fastest live nodes, and activates #1.
- (void)runAutoSelectFastestWithProgress:(nullable LCSelectorProgressBlock)progress
                              completion:(nullable void (^)(LCProxyNode * _Nullable bestNode, NSError * _Nullable error))completion;

/// Subscriptions management
- (void)addSubscriptionURL:(NSString *)url
                      name:(nullable NSString *)name
                completion:(void (^)(BOOL ok, NSString * _Nullable message))completion;
- (void)refreshAllSubscriptionsWithCompletion:(nullable void (^)(NSUInteger totalNodes, NSError * _Nullable error))completion;
- (void)removeSubscriptionWithID:(NSString *)subID;

/// Paste URI or raw JSON (auto-converts JSON -> canonical URI nodes).
- (NSArray<LCProxyNode *> *)importFromClipboardOrText:(NSString *)rawText
                                                error:(NSError * _Nullable * _Nullable)error;
- (void)removeNodeWithID:(NSString *)nodeID;

/// Status & Log helpers
- (void)setProxyStatus:(LCProxyStatus)status;
- (void)updateActiveNodeLatency:(NSInteger)pingMs status:(LCProxyStatus)status;
- (void)appendLog:(NSString *)line;
- (void)clearLogs;
- (NSString *)joinedLogsText;
- (NSString *)statusDisplayText;

@end

NS_ASSUME_NONNULL_END
