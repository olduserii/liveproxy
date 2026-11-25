#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LCProxyProtocol) {
    LCProxyProtocolUnknown = 0,
    LCProxyProtocolVLESS,
    LCProxyProtocolHysteria2,
    LCProxyProtocolTrojan,
    LCProxyProtocolVMess,
    LCProxyProtocolShadowsocks,
    LCProxyProtocolWireGuard,
    LCProxyProtocolSOCKS5,
    LCProxyProtocolHTTP
};

@interface LCProxyNode : NSObject <NSCopying>

@property (nonatomic, copy) NSString *nodeID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, nullable) NSString *subscriptionID;
@property (nonatomic, assign) LCProxyProtocol protocol;

// Core endpoint & credentials
@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, copy, nullable) NSString *uuidOrPassword;
@property (nonatomic, copy, nullable) NSString *username;
@property (nonatomic, copy, nullable) NSString *method;          // SS cipher (incl. 2022-blake3-*), VMess security
@property (nonatomic, copy, nullable) NSString *encryption;      // VLESS encryption (default "none" or VLESS Encryption key)
@property (nonatomic, copy, nullable) NSString *flow;            // e.g. "xtls-rprx-vision"

// Transport layer (raw/tcp, xhttp/splithttp, ws, grpc, httpupgrade)
@property (nonatomic, copy) NSString *network;
@property (nonatomic, copy, nullable) NSString *path;
@property (nonatomic, copy, nullable) NSString *hostHeader;
@property (nonatomic, copy, nullable) NSString *xhttpMode;       // auto, packet-up, stream-up, stream-one
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *xhttpExtra;
@property (nonatomic, copy, nullable) NSString *grpcServiceName;
@property (nonatomic, copy, nullable) NSString *grpcAuthority;
@property (nonatomic, assign) BOOL grpcMultiMode;

// Security layer (none, tls, reality)
@property (nonatomic, copy) NSString *security;
@property (nonatomic, copy, nullable) NSString *sni;
@property (nonatomic, copy, nullable) NSString *fingerprint;     // chrome, safari, ios, randomized
@property (nonatomic, copy, nullable) NSArray<NSString *> *alpn;
@property (nonatomic, assign) BOOL allowInsecure;

// REALITY specific
@property (nonatomic, copy, nullable) NSString *realityPublicKey; // pbk
@property (nonatomic, copy, nullable) NSString *realityShortId;   // sid
@property (nonatomic, copy, nullable) NSString *realitySpiderX;   // spx

// Hysteria 2 specific
@property (nonatomic, copy, nullable) NSString *hy2Obfs;
@property (nonatomic, copy, nullable) NSString *hy2ObfsPassword;
@property (nonatomic, copy, nullable) NSString *hy2PinSHA256;
@property (nonatomic, assign) NSInteger hy2UpMbps;
@property (nonatomic, assign) NSInteger hy2DownMbps;

// WireGuard specific
@property (nonatomic, copy, nullable) NSString *wgPrivateKey;
@property (nonatomic, copy, nullable) NSString *wgPeerPublicKey;
@property (nonatomic, copy, nullable) NSString *wgPreSharedKey;
@property (nonatomic, copy, nullable) NSArray<NSString *> *wgAddresses;
@property (nonatomic, copy, nullable) NSArray<NSNumber *> *wgReserved;
@property (nonatomic, assign) NSInteger wgMTU;

// Runtime latency metrics (not used in xray-rust JSON)
@property (nonatomic, assign) NSInteger tcpPingMs;       // -1 = untested/failed
@property (nonatomic, assign) NSInteger realPingMs;      // -1 = untested/failed

+ (NSString *)protocolNameForType:(LCProxyProtocol)protocol;
+ (LCProxyProtocol)protocolTypeFromString:(NSString *)str;

/// Compact display string (e.g., "VLESS REALITY · XHTTP", "HY2", "SS-2022").
- (NSString *)protocolBadgeText;

/// Converts this canonical node (even if originally imported from Xray/sing-box JSON)
/// into a clean, standard copyable URI string.
- (NSString *)toURIString;

/// Serialization for shared Application Support storage.
- (NSDictionary<NSString *, id> *)toDictionary;
+ (nullable instancetype)nodeFromDictionary:(NSDictionary<NSString *, id> *)dict;

@end

NS_ASSUME_NONNULL_END
