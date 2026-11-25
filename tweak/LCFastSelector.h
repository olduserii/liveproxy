#import <Foundation/Foundation.h>
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
