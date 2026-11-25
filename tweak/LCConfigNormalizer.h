#import <Foundation/Foundation.h>
#import "LCProxyNode.h"

NS_ASSUME_NONNULL_BEGIN

@interface LCSubscriptionInfo : NSObject
@property (nonatomic, assign) int64_t uploadBytes;
@property (nonatomic, assign) int64_t downloadBytes;
@property (nonatomic, assign) int64_t totalBytes;
@property (nonatomic, assign) int64_t expireTimestamp;
@property (nonatomic, copy, nullable) NSString *profileTitle;
- (NSString *)formattedUsageSummary;
@end

@interface LCConfigNormalizer : NSObject

/// Parses ANY raw subscription payload:
/// - Plain URI list (vless://, hysteria2://, hy2://, trojan://, vmess://, ss://, wireguard://, socks5://, http://)
/// - Base64 or URL-safe Base64 encoded URI lists
/// - Full Xray JSON configs, JSON arrays of configs, single JSON outbound objects
/// - sing-box JSON configs (outbounds array)
+ (NSArray<LCProxyNode *> *)parseAnyPayload:(NSString *)rawText
                             subscriptionID:(nullable NSString *)subscriptionID
                                      error:(NSError * _Nullable * _Nullable)error;

/// Parses a single proxy URI string into a canonical LCProxyNode.
+ (nullable LCProxyNode *)parseSingleURI:(NSString *)uriString
                          subscriptionID:(nullable NSString *)subscriptionID;

/// Downloads a subscription URL bypassing local proxy hooks (so updates work even if proxy is off/down).
/// Extracts subscription-userinfo and profile-title headers and parses all nodes.
+ (void)fetchSubscriptionFromURL:(NSString *)urlString
                  subscriptionID:(NSString *)subscriptionID
                      completion:(void (^)(NSArray<LCProxyNode *> * _Nullable nodes,
                                           LCSubscriptionInfo * _Nullable info,
                                           NSError * _Nullable error))completion;

/// Parses RFC-style subscription-userinfo header ("upload=...; download=...; total=...; expire=...").
+ (nullable LCSubscriptionInfo *)parseSubscriptionUserInfoHeader:(nullable NSString *)headerValue;

/// Generates a STRICT, minimal, 100% valid JSON configuration for xray-rust from a canonical LCProxyNode.
/// NEVER passes raw provider JSON into xray-rust; strips observatory, fakedns, policy, stats, and unknown keys.
+ (nullable NSString *)buildStrictXrayJSONForNode:(LCProxyNode *)node
                                        socksPort:(uint16_t)socksPort
                                         httpPort:(uint16_t)httpPort
                                            error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
