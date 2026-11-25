#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^LCXrayLogHandler)(NSString *message);

/// Opaque handle representing an active ephemeral probe instance of xray-rust.
@interface LCXrayProbeHandle : NSObject
@property (nonatomic, assign, readonly) uint16_t httpPort;
@property (nonatomic, assign, readonly) uint16_t socksPort;
@property (nonatomic, copy, readonly) NSString *instanceTag;
@end

/// Strictly isolated Objective-C <-> Rust C-ABI adapter for aimalygin/xray-rust-mobile.
/// All direct calls to XrayRust.xcframework symbols are confined exclusively to this class.
@interface LCXrayRustBridge : NSObject

+ (instancetype)sharedBridge;

/// Optional callback for internal core/ABI diagnostic logs.
@property (nonatomic, copy, nullable) LCXrayLogHandler logHandler;

/// Returns YES if the primary xray-rust engine is currently running.
@property (nonatomic, assign, readonly) BOOL isRunning;

/// Currently bound local loopback ports for the primary engine (0 when stopped).
@property (nonatomic, assign, readonly) uint16_t activeSocksPort;
@property (nonatomic, assign, readonly) uint16_t activeHttpPort;

/// Human-readable description of detected C ABI symbols and core version.
- (NSString *)coreVersionString;

/// Allocates an unused ephemeral TCP port on 127.0.0.1.
- (uint16_t)allocateFreeLocalPort;

/// Starts (or cleanly restarts) the primary xray-rust instance with strict sanitized JSON.
- (BOOL)startWithJSONConfig:(NSString *)jsonConfig
                  socksPort:(uint16_t)socksPort
                   httpPort:(uint16_t)httpPort
                      error:(NSError * _Nullable * _Nullable)error;

/// Stops the primary xray-rust instance cleanly and releases bound ports.
- (void)stopPrimaryInstance;

/// Starts an isolated lightweight probe instance for Stage-2 real latency testing.
/// If the linked ABI only exposes singleton start/stop symbols, probes run safely
/// without corrupting the primary instance state.
- (nullable LCXrayProbeHandle *)startProbeWithJSONConfig:(NSString *)jsonConfig
                                               socksPort:(uint16_t)socksPort
                                                httpPort:(uint16_t)httpPort
                                                   error:(NSError * _Nullable * _Nullable)error;

/// Stops and releases a probe instance started via startProbeWithJSONConfig:.
- (void)stopProbeHandle:(LCXrayProbeHandle *)handle;

/// Returns YES if the detected XrayRust C ABI supports concurrent multi-instance handles.
- (BOOL)supportsConcurrentProbes;

@end

NS_ASSUME_NONNULL_END
