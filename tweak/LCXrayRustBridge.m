#import "LCXrayRustBridge.h"
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>
#import <stdint.h>
#import <stddef.h>

#if __has_include("LCXrayRustCustomABI.h")
#import "LCXrayRustCustomABI.h"
#else

// ---------------------------------------------------------------------------
// Exact C ABI from aimalygin/xray-rust-mobile (Sources/XrayRustFFI/include/xray_ffi.h)
// Strictly isolated inside LCXrayRustBridge.m so no other file touches Rust FFI.
// ---------------------------------------------------------------------------

typedef enum XrayStatus {
    XRAY_STATUS_OK = 0,
    XRAY_STATUS_NULL_ARGUMENT = 1,
    XRAY_STATUS_INVALID_UTF8 = 2,
    XRAY_STATUS_CONFIG_ERROR = 3,
    XRAY_STATUS_CORE_NOT_LOADED = 4,
    XRAY_STATUS_RUNTIME_ERROR = 5,
    XRAY_STATUS_NO_PACKET = 6,
    XRAY_STATUS_BUFFER_TOO_SMALL = 7,
    XRAY_STATUS_TUN_ERROR = 8,
    XRAY_STATUS_INVALID_ARGUMENT = 9,
    XRAY_STATUS_PANIC = 255
} XrayStatus;

typedef struct XrayCoreHandle XrayCoreHandle;
typedef struct XrayError XrayError;

extern uint32_t xray_ffi_version_major(void);
extern uint32_t xray_ffi_version_minor(void);
extern uint64_t xray_ffi_capabilities(void);

extern XrayCoreHandle *xray_core_new(XrayError **error);
extern XrayStatus xray_core_load_config_json(XrayCoreHandle *handle, const char *json, XrayError **error);
extern XrayStatus xray_core_start(XrayCoreHandle *handle, XrayError **error);
extern XrayStatus xray_core_stop(XrayCoreHandle *handle, XrayError **error);
extern void xray_core_free(XrayCoreHandle *handle);

extern XrayStatus xray_core_cancel_outbound_probes(XrayCoreHandle *handle, XrayError **error);
extern XrayStatus xray_core_rebind_hysteria(XrayCoreHandle *handle, uint64_t *accepted, XrayError **error);
extern XrayStatus xray_core_rebind_wireguard(XrayCoreHandle *handle, uint64_t *accepted, XrayError **error);

extern XrayStatus xray_error_code(const XrayError *error);
extern const char *xray_error_message(const XrayError *error);
extern void xray_error_free(XrayError *error);

#endif

static NSError *lc_errorFromXray(XrayStatus status, XrayError *xrayErr, NSString *context) {
    NSString *msg = nil;
    if (xrayErr != NULL) {
        const char *cMsg = xray_error_message(xrayErr);
        if (cMsg != NULL && cMsg[0] != '\0') {
            msg = [NSString stringWithUTF8String:cMsg];
        }
        xray_error_free(xrayErr);
    }
    if (msg.length == 0) {
        msg = [NSString stringWithFormat:@"%@ failed (status=%d)", context, (int)status];
    } else {
        msg = [NSString stringWithFormat:@"%@: %@", context, msg];
    }
    return [NSError errorWithDomain:@"LCXrayRustBridge"
                               code:(NSInteger)status
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

@interface LCXrayProbeHandle ()
@property (nonatomic, assign, readwrite) uint16_t httpPort;
@property (nonatomic, assign, readwrite) uint16_t socksPort;
@property (nonatomic, copy, readwrite) NSString *instanceTag;
@property (nonatomic, assign) XrayCoreHandle *rawHandle;
@end

@implementation LCXrayProbeHandle
@end

@interface LCXrayRustBridge () {
    dispatch_queue_t _bridgeQueue;
    XrayCoreHandle *_primaryHandle;
    BOOL _primaryRunning;
    uint16_t _activeSocksPort;
    uint16_t _activeHttpPort;
}
@end

@implementation LCXrayRustBridge

+ (instancetype)sharedBridge {
    static LCXrayRustBridge *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[LCXrayRustBridge alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _bridgeQueue = dispatch_queue_create("com.lcproxy.xrayrust.bridge", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)emitLog:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    LCXrayLogHandler handler = self.logHandler;
    if (handler) {
        handler([NSString stringWithFormat:@"[XrayBridge] %@", msg]);
    }
}

- (BOOL)isRunning {
    __block BOOL running = NO;
    dispatch_sync(_bridgeQueue, ^{
        running = (self->_primaryRunning && self->_primaryHandle != NULL);
    });
    return running;
}

- (uint16_t)activeSocksPort {
    __block uint16_t port = 0;
    dispatch_sync(_bridgeQueue, ^{
        port = (self->_primaryRunning && self->_primaryHandle != NULL) ? self->_activeSocksPort : 0;
    });
    return port;
}

- (uint16_t)activeHttpPort {
    __block uint16_t port = 0;
    dispatch_sync(_bridgeQueue, ^{
        port = (self->_primaryRunning && self->_primaryHandle != NULL) ? self->_activeHttpPort : 0;
    });
    return port;
}

- (BOOL)supportsConcurrentProbes {
    return YES;
}

- (NSString *)coreVersionString {
    uint32_t maj = xray_ffi_version_major();
    uint32_t min = xray_ffi_version_minor();
    uint64_t caps = xray_ffi_capabilities();
    return [NSString stringWithFormat:@"xray-rust FFI v%u.%u (caps=0x%llx)",
            maj, min, (unsigned long long)caps];
}

- (uint16_t)allocateFreeLocalPort {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 0;

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(0);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return 0;
    }

    socklen_t len = sizeof(addr);
    uint16_t assignedPort = 0;
    if (getsockname(fd, (struct sockaddr *)&addr, &len) == 0) {
        assignedPort = ntohs(addr.sin_port);
    }
    close(fd);
    return assignedPort;
}

- (void)destroyHandleSafely:(XrayCoreHandle *)handle {
    if (handle == NULL) return;
    XrayError *err = NULL;
    xray_core_cancel_outbound_probes(handle, &err);
    if (err != NULL) {
        xray_error_free(err);
        err = NULL;
    }
    xray_core_stop(handle, &err);
    if (err != NULL) {
        xray_error_free(err);
    }
    xray_core_free(handle);
}

- (void)stopPrimaryLocked {
    if (_primaryHandle != NULL) {
        [self destroyHandleSafely:_primaryHandle];
        _primaryHandle = NULL;
    }
    if (_primaryRunning) {
        _primaryRunning = NO;
        _activeSocksPort = 0;
        _activeHttpPort = 0;
        [self emitLog:@"Primary xray-rust core stopped"];
    }
}

- (BOOL)startWithJSONConfig:(NSString *)jsonConfig
                  socksPort:(uint16_t)socksPort
                   httpPort:(uint16_t)httpPort
                      error:(NSError **)error {
    if (jsonConfig.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"LCXrayRustBridge"
                                         code:1001
                                     userInfo:@{NSLocalizedDescriptionKey: @"Empty xray-rust JSON config"}];
        }
        return NO;
    }

    __block BOOL ok = NO;
    __block NSError *localErr = nil;

    dispatch_sync(_bridgeQueue, ^{
        // Per xray_ffi.h contract: a handle accepts one full config load; create a fresh handle on restart.
        [self stopPrimaryLocked];

        XrayError *xErr = NULL;
        XrayCoreHandle *handle = xray_core_new(&xErr);
        if (handle == NULL) {
            localErr = lc_errorFromXray(XRAY_STATUS_RUNTIME_ERROR, xErr, @"xray_core_new");
            [self emitLog:@"ERROR: %@", localErr.localizedDescription];
            return;
        }
        if (xErr != NULL) {
            xray_error_free(xErr);
            xErr = NULL;
        }

        XrayStatus loadStatus = xray_core_load_config_json(handle, jsonConfig.UTF8String, &xErr);
        if (loadStatus != XRAY_STATUS_OK) {
            localErr = lc_errorFromXray(loadStatus, xErr, @"xray_core_load_config_json");
            xray_core_free(handle);
            [self emitLog:@"ERROR: %@", localErr.localizedDescription];
            return;
        }
        if (xErr != NULL) {
            xray_error_free(xErr);
            xErr = NULL;
        }

        XrayStatus startStatus = xray_core_start(handle, &xErr);
        if (startStatus != XRAY_STATUS_OK) {
            localErr = lc_errorFromXray(startStatus, xErr, @"xray_core_start");
            xray_core_free(handle);
            [self emitLog:@"ERROR: %@", localErr.localizedDescription];
            return;
        }
        if (xErr != NULL) {
            xray_error_free(xErr);
        }

        self->_primaryHandle = handle;
        self->_primaryRunning = YES;
        self->_activeSocksPort = socksPort;
        self->_activeHttpPort = httpPort;
        ok = YES;

        [self emitLog:@"Started xray-rust FFI v%u.%u on 127.0.0.1 HTTP:%u SOCKS5:%u",
         xray_ffi_version_major(), xray_ffi_version_minor(), httpPort, socksPort];
    });

    if (error && localErr) {
        *error = localErr;
    }
    return ok;
}

- (void)stopPrimaryInstance {
    dispatch_sync(_bridgeQueue, ^{
        [self stopPrimaryLocked];
    });
}

- (void)rebindActiveCarrierSockets {
    dispatch_async(_bridgeQueue, ^{
        if (!self->_primaryRunning || self->_primaryHandle == NULL) return;

        uint64_t hy2Accepted = 0;
        XrayError *err = NULL;
        if (xray_core_rebind_hysteria(self->_primaryHandle, &hy2Accepted, &err) == XRAY_STATUS_OK && hy2Accepted > 0) {
            [self emitLog:@"Rebound %llu QUIC/Hysteria2 carrier socket(s)", (unsigned long long)hy2Accepted];
        }
        if (err != NULL) {
            xray_error_free(err);
            err = NULL;
        }

        uint64_t wgAccepted = 0;
        if (xray_core_rebind_wireguard(self->_primaryHandle, &wgAccepted, &err) == XRAY_STATUS_OK && wgAccepted > 0) {
            [self emitLog:@"Rebound %llu WireGuard carrier socket(s)", (unsigned long long)wgAccepted];
        }
        if (err != NULL) {
            xray_error_free(err);
        }
    });
}

- (nullable LCXrayProbeHandle *)startProbeWithJSONConfig:(NSString *)jsonConfig
                                               socksPort:(uint16_t)socksPort
                                                httpPort:(uint16_t)httpPort
                                                   error:(NSError **)error {
    if (jsonConfig.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"LCXrayRustBridge"
                                         code:2001
                                     userInfo:@{NSLocalizedDescriptionKey: @"Empty probe config"}];
        }
        return nil;
    }

    // Independent XrayCoreHandle per probe — runs safely in parallel without blocking primary traffic
    XrayError *xErr = NULL;
    XrayCoreHandle *handle = xray_core_new(&xErr);
    if (handle == NULL) {
        if (error) *error = lc_errorFromXray(XRAY_STATUS_RUNTIME_ERROR, xErr, @"probe xray_core_new");
        else if (xErr) xray_error_free(xErr);
        return nil;
    }
    if (xErr != NULL) { xray_error_free(xErr); xErr = NULL; }

    XrayStatus st = xray_core_load_config_json(handle, jsonConfig.UTF8String, &xErr);
    if (st != XRAY_STATUS_OK) {
        if (error) *error = lc_errorFromXray(st, xErr, @"probe load_config");
        else if (xErr) xray_error_free(xErr);
        xray_core_free(handle);
        return nil;
    }
    if (xErr != NULL) { xray_error_free(xErr); xErr = NULL; }

    st = xray_core_start(handle, &xErr);
    if (st != XRAY_STATUS_OK) {
        if (error) *error = lc_errorFromXray(st, xErr, @"probe start");
        else if (xErr) xray_error_free(xErr);
        xray_core_free(handle);
        return nil;
    }
    if (xErr != NULL) { xray_error_free(xErr); }

    LCXrayProbeHandle *probe = [[LCXrayProbeHandle alloc] init];
    probe.rawHandle = handle;
    probe.httpPort = httpPort;
    probe.socksPort = socksPort;
    probe.instanceTag = [NSString stringWithFormat:@"probe-%u", httpPort];
    return probe;
}

- (void)stopProbeHandle:(LCXrayProbeHandle *)handle {
    if (!handle || handle.rawHandle == NULL) return;
    XrayCoreHandle *raw = handle.rawHandle;
    handle.rawHandle = NULL;
    [self destroyHandleSafely:raw];
}

@end
