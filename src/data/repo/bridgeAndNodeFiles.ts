import type { RepoFile } from './types';

export const bridgeAndNodeFiles: RepoFile[] = [
  {
    path: 'tweak/LCXrayRustBridge.h',
    language: 'objc',
    category: 'tweak',
    summary: 'Isolated C ABI bridge to XrayRust.xcframework with multi-instance probe & dynamic port allocation',
    content: `#import <Foundation/Foundation.h>

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
`,
  },
  {
    path: 'tweak/LCXrayRustBridge.m',
    language: 'objc',
    category: 'tweak',
    summary: 'Safe C ABI resolver & lifecycle manager for aimalygin/xray-rust-mobile (handle + singleton FFI)',
    content: `#import "LCXrayRustBridge.h"
#import <dlfcn.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

#if __has_include("LCXrayRustCustomABI.h")
#import "LCXrayRustCustomABI.h"
#endif

// ---------------------------------------------------------------------------
// C ABI Function Pointer Prototypes covering aimalygin/xray-rust-mobile FFI
// ---------------------------------------------------------------------------

// Pattern A: Handle-based multi-instance ABI (e.g. xray_core_create / xray_create / xray_new)
typedef void *(*lc_xray_create_fn)(const char *config_json, char **err_out);
typedef void *(*lc_xray_create_simple_fn)(const char *config_json);
typedef int   (*lc_xray_handle_start_fn)(void *handle);
typedef int   (*lc_xray_handle_stop_fn)(void *handle);
typedef void  (*lc_xray_handle_destroy_fn)(void *handle);
typedef int   (*lc_xray_handle_is_running_fn)(void *handle);

// Pattern B: Singleton ABI returning status int or error C-string
typedef int   (*lc_xray_start_errptr_fn)(const char *config_json, char **err_out);
typedef int   (*lc_xray_start_int_fn)(const char *config_json);
typedef char *(*lc_xray_start_str_fn)(const char *config_json);
typedef int   (*lc_xray_stop_int_fn)(void);
typedef void  (*lc_xray_stop_void_fn)(void);
typedef int   (*lc_xray_is_running_fn)(void);

// Pattern C: Version & Rust-allocated C-string deallocation
typedef const char *(*lc_xray_version_fn)(void);
typedef void        (*lc_xray_free_str_fn)(char *ptr);

typedef NS_ENUM(NSInteger, LCXrayABIMode) {
    LCXrayABIModeUnresolved = 0,
    LCXrayABIModeHandleBased,
    LCXrayABIModeSingletonIntErrPtr,
    LCXrayABIModeSingletonInt,
    LCXrayABIModeSingletonCharPtr
};

@interface LCXrayProbeHandle ()
@property (nonatomic, assign, readwrite) uint16_t httpPort;
@property (nonatomic, assign, readwrite) uint16_t socksPort;
@property (nonatomic, copy, readwrite) NSString *instanceTag;
@property (nonatomic, assign) void *rawHandle;
@property (nonatomic, assign) BOOL usedSingletonFallback;
@end

@implementation LCXrayProbeHandle
@end

@interface LCXrayRustBridge () {
    dispatch_queue_t _bridgeQueue;
    LCXrayABIMode _abiMode;
    NSString *_resolvedSymbolSummary;

    // Resolved function pointers
    lc_xray_create_fn            _fnCreateWithErr;
    lc_xray_create_simple_fn     _fnCreateSimple;
    lc_xray_handle_start_fn      _fnHandleStart;
    lc_xray_handle_stop_fn       _fnHandleStop;
    lc_xray_handle_destroy_fn    _fnHandleDestroy;
    lc_xray_handle_is_running_fn _fnHandleIsRunning;

    lc_xray_start_errptr_fn      _fnStartErrPtr;
    lc_xray_start_int_fn         _fnStartInt;
    lc_xray_start_str_fn         _fnStartStr;
    lc_xray_stop_int_fn          _fnStopInt;
    lc_xray_stop_void_fn         _fnStopVoid;
    lc_xray_is_running_fn        _fnIsRunning;

    lc_xray_version_fn           _fnVersion;
    lc_xray_free_str_fn          _fnFreeStr;

    // Primary engine runtime state
    void *_primaryHandle;
    BOOL _primaryRunning;
    uint16_t _activeSocksPort;
    uint16_t _activeHttpPort;
    NSString *_lastPrimaryJSON;
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
        _abiMode = LCXrayABIModeUnresolved;
        _resolvedSymbolSummary = @"Unresolved";
        [self resolveABISymbolsLocked];
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

static void *lc_find_symbol(const char *const *names, size_t count, const char **matchedNameOut) {
    // Search across main image, statically linked symbols, and loaded dynamic frameworks
    void *dlHandles[3] = { RTLD_DEFAULT, RTLD_SELF, NULL };
    NSString *frameworkPath = [[[NSBundle mainBundle] privateFrameworksPath]
                               stringByAppendingPathComponent:@"XrayRust.framework/XrayRust"];
    if (frameworkPath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:frameworkPath]) {
        dlHandles[2] = dlopen(frameworkPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    }

    for (size_t i = 0; i < count; i++) {
        for (int h = 0; h < 3; h++) {
            if (h == 2 && dlHandles[2] == NULL) continue;
            void *sym = dlsym(dlHandles[h], names[i]);
            if (sym != NULL) {
                if (matchedNameOut) *matchedNameOut = names[i];
                return sym;
            }
        }
    }
    return NULL;
}

- (void)resolveABISymbolsLocked {
    // 1. Free string & version helpers
    const char *freeNames[] = {
        "xray_rust_free_string",
        "xray_free_string",
        "xray_string_free",
        "xray_core_free_string",
        "xray_cstr_free"
    };
    const char *matchedFree = NULL;
    _fnFreeStr = (lc_xray_free_str_fn)lc_find_symbol(freeNames, sizeof(freeNames)/sizeof(freeNames[0]), &matchedFree);

    const char *verNames[] = {
        "xray_rust_version",
        "xray_core_version",
        "xray_version"
    };
    const char *matchedVer = NULL;
    _fnVersion = (lc_xray_version_fn)lc_find_symbol(verNames, sizeof(verNames)/sizeof(verNames[0]), &matchedVer);

    // 2. Check handle-based multi-instance API first (preferred for concurrent Stage-2 probing)
    const char *createNames[] = {
        "xray_rust_create",
        "xray_core_create",
        "xray_instance_create",
        "xray_create",
        "xray_new"
    };
    const char *handleStartNames[] = {
        "xray_rust_instance_start",
        "xray_core_instance_start",
        "xray_instance_start",
        "xray_handle_start"
    };
    const char *handleStopNames[] = {
        "xray_rust_instance_stop",
        "xray_core_instance_stop",
        "xray_instance_stop",
        "xray_handle_stop"
    };
    const char *destroyNames[] = {
        "xray_rust_destroy",
        "xray_core_destroy",
        "xray_instance_destroy",
        "xray_destroy",
        "xray_free"
    };
    const char *handleRunningNames[] = {
        "xray_rust_instance_is_running",
        "xray_core_instance_is_running",
        "xray_instance_is_running"
    };

    const char *mCreate = NULL, *mHStart = NULL, *mHStop = NULL, *mDestroy = NULL, *mHRun = NULL;
    void *symCreate  = lc_find_symbol(createNames, sizeof(createNames)/sizeof(createNames[0]), &mCreate);
    void *symHStart  = lc_find_symbol(handleStartNames, sizeof(handleStartNames)/sizeof(handleStartNames[0]), &mHStart);
    void *symHStop   = lc_find_symbol(handleStopNames, sizeof(handleStopNames)/sizeof(handleStopNames[0]), &mHStop);
    void *symDestroy = lc_find_symbol(destroyNames, sizeof(destroyNames)/sizeof(destroyNames[0]), &mDestroy);
    void *symHRun    = lc_find_symbol(handleRunningNames, sizeof(handleRunningNames)/sizeof(handleRunningNames[0]), &mHRun);

    if (symCreate && symDestroy && (symHStart || symHStop)) {
        _fnCreateSimple   = (lc_xray_create_simple_fn)symCreate;
        _fnHandleStart    = (lc_xray_handle_start_fn)symHStart;
        _fnHandleStop     = (lc_xray_handle_stop_fn)symHStop;
        _fnHandleDestroy  = (lc_xray_handle_destroy_fn)symDestroy;
        _fnHandleIsRunning = (lc_xray_handle_is_running_fn)symHRun;
        _abiMode = LCXrayABIModeHandleBased;
        _resolvedSymbolSummary = [NSString stringWithFormat:@"HandleABI(%s/%s/%s)",
                                  mCreate ?: "?", mHStart ?: "?", mDestroy ?: "?"];
        return;
    }

    // 3. Check singleton start/stop/status API (standard xray-rust-mobile C ABI)
    const char *startErrPtrNames[] = {
        "xray_rust_start_with_error",
        "xray_core_start_json",
        "xray_start_json"
    };
    const char *startIntNames[] = {
        "xray_rust_start",
        "xray_core_start",
        "xray_start",
        "start_xray"
    };
    const char *stopNames[] = {
        "xray_rust_stop",
        "xray_core_stop",
        "xray_stop",
        "stop_xray"
    };
    const char *runningNames[] = {
        "xray_rust_is_running",
        "xray_core_is_running",
        "xray_is_running",
        "is_xray_running"
    };

    const char *mStart = NULL, *mStop = NULL, *mRun = NULL;
    void *symStartErr = lc_find_symbol(startErrPtrNames, sizeof(startErrPtrNames)/sizeof(startErrPtrNames[0]), &mStart);
    void *symStop     = lc_find_symbol(stopNames, sizeof(stopNames)/sizeof(stopNames[0]), &mStop);
    void *symRun      = lc_find_symbol(runningNames, sizeof(runningNames)/sizeof(runningNames[0]), &mRun);

    if (symStartErr && symStop) {
        _fnStartErrPtr = (lc_xray_start_errptr_fn)symStartErr;
        _fnStopInt     = (lc_xray_stop_int_fn)symStop;
        _fnStopVoid    = (lc_xray_stop_void_fn)symStop;
        _fnIsRunning   = (lc_xray_is_running_fn)symRun;
        _abiMode = LCXrayABIModeSingletonIntErrPtr;
        _resolvedSymbolSummary = [NSString stringWithFormat:@"SingletonErrPtr(%s/%s)",
                                  mStart ?: "?", mStop ?: "?"];
        return;
    }

    void *symStartInt = lc_find_symbol(startIntNames, sizeof(startIntNames)/sizeof(startIntNames[0]), &mStart);
    if (symStartInt && symStop) {
        _fnStartInt  = (lc_xray_start_int_fn)symStartInt;
        _fnStopInt   = (lc_xray_stop_int_fn)symStop;
        _fnStopVoid  = (lc_xray_stop_void_fn)symStop;
        _fnIsRunning = (lc_xray_is_running_fn)symRun;
        _abiMode = LCXrayABIModeSingletonInt;
        _resolvedSymbolSummary = [NSString stringWithFormat:@"SingletonInt(%s/%s)",
                                  mStart ?: "?", mStop ?: "?"];
        return;
    }

    _abiMode = LCXrayABIModeUnresolved;
    _resolvedSymbolSummary = @"No XrayRust C ABI symbols found in process";
}

- (BOOL)isRunning {
    __block BOOL running = NO;
    dispatch_sync(_bridgeQueue, ^{
        if (!_primaryRunning) {
            running = NO;
            return;
        }
        if (_abiMode == LCXrayABIModeHandleBased && _fnHandleIsRunning && _primaryHandle) {
            running = (_fnHandleIsRunning(_primaryHandle) != 0);
        } else if (_fnIsRunning) {
            running = (_fnIsRunning() != 0);
        } else {
            running = _primaryRunning;
        }
    });
    return running;
}

- (uint16_t)activeSocksPort {
    __block uint16_t port = 0;
    dispatch_sync(_bridgeQueue, ^{
        port = _primaryRunning ? _activeSocksPort : 0;
    });
    return port;
}

- (uint16_t)activeHttpPort {
    __block uint16_t port = 0;
    dispatch_sync(_bridgeQueue, ^{
        port = _primaryRunning ? _activeHttpPort : 0;
    });
    return port;
}

- (BOOL)supportsConcurrentProbes {
    __block BOOL supported = NO;
    dispatch_sync(_bridgeQueue, ^{
        supported = (_abiMode == LCXrayABIModeHandleBased);
    });
    return supported;
}

- (NSString *)coreVersionString {
    __block NSString *result = nil;
    dispatch_sync(_bridgeQueue, ^{
        if (_fnVersion) {
            const char *ver = _fnVersion();
            if (ver) {
                result = [NSString stringWithFormat:@"xray-rust %s [%@]", ver, _resolvedSymbolSummary];
                return;
            }
        }
        result = [NSString stringWithFormat:@"xray-rust [%@]", _resolvedSymbolSummary];
    });
    return result;
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

- (void)stopPrimaryLocked {
    if (!_primaryRunning && _primaryHandle == NULL) {
        return;
    }
    if (_abiMode == LCXrayABIModeHandleBased) {
        if (_primaryHandle) {
            if (_fnHandleStop) _fnHandleStop(_primaryHandle);
            if (_fnHandleDestroy) _fnHandleDestroy(_primaryHandle);
            _primaryHandle = NULL;
        }
    } else if (_abiMode != LCXrayABIModeUnresolved) {
        if (_fnStopVoid) _fnStopVoid();
    }
    _primaryRunning = NO;
    _activeSocksPort = 0;
    _activeHttpPort = 0;
    [self emitLog:@"Primary xray-rust core stopped"];
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
        if (_abiMode == LCXrayABIModeUnresolved) {
            [self resolveABISymbolsLocked];
        }
        if (_abiMode == LCXrayABIModeUnresolved) {
            localErr = [NSError errorWithDomain:@"LCXrayRustBridge"
                                           code:1002
                                       userInfo:@{NSLocalizedDescriptionKey: @"XrayRust C ABI symbols not linked/loaded"}];
            [self emitLog:@"ERROR: %@", localErr.localizedDescription];
            return;
        }

        [self stopPrimaryLocked];

        const char *cJSON = jsonConfig.UTF8String;
        if (_abiMode == LCXrayABIModeHandleBased) {
            void *handle = _fnCreateSimple(cJSON);
            if (!handle) {
                localErr = [NSError errorWithDomain:@"LCXrayRustBridge"
                                               code:1003
                                           userInfo:@{NSLocalizedDescriptionKey: @"xray-rust rejected config during create"}];
                return;
            }
            int rc = _fnHandleStart ? _fnHandleStart(handle) : 0;
            if (rc != 0) {
                if (_fnHandleDestroy) _fnHandleDestroy(handle);
                localErr = [NSError errorWithDomain:@"LCXrayRustBridge"
                                               code:rc
                                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"xray-rust handle start failed (%d)", rc]}];
                return;
            }
            _primaryHandle = handle;
            ok = YES;
        } else if (_abiMode == LCXrayABIModeSingletonIntErrPtr) {
            char *errStr = NULL;
            int rc = _fnStartErrPtr(cJSON, &errStr);
            if (rc != 0) {
                NSString *desc = errStr ? [NSString stringWithUTF8String:errStr] : [NSString stringWithFormat:@"xray-rust start failed (%d)", rc];
                if (errStr && _fnFreeStr) _fnFreeStr(errStr);
                localErr = [NSError errorWithDomain:@"LCXrayRustBridge"
                                               code:rc
                                           userInfo:@{NSLocalizedDescriptionKey: desc}];
                return;
            }
            if (errStr && _fnFreeStr) _fnFreeStr(errStr);
            ok = YES;
        } else if (_abiMode == LCXrayABIModeSingletonInt) {
            int rc = _fnStartInt(cJSON);
            if (rc != 0) {
                localErr = [NSError errorWithDomain:@"LCXrayRustBridge"
                                               code:rc
                                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"xray-rust start returned error code %d", rc]}];
                return;
            }
            ok = YES;
        }

        if (ok) {
            _primaryRunning = YES;
            _activeSocksPort = socksPort;
            _activeHttpPort = httpPort;
            _lastPrimaryJSON = [jsonConfig copy];
            [self emitLog:@"Started xray-rust (%@) on 127.0.0.1 HTTP:%u SOCKS5:%u",
             _resolvedSymbolSummary, httpPort, socksPort];
        }
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

- (nullable LCXrayProbeHandle *)startProbeWithJSONConfig:(NSString *)jsonConfig
                                               socksPort:(uint16_t)socksPort
                                                httpPort:(uint16_t)httpPort
                                                   error:(NSError **)error {
    __block LCXrayProbeHandle *probe = nil;
    __block NSError *localErr = nil;

    dispatch_sync(_bridgeQueue, ^{
        if (_abiMode == LCXrayABIModeUnresolved) {
            [self resolveABISymbolsLocked];
        }
        if (_abiMode == LCXrayABIModeUnresolved) {
            localErr = [NSError errorWithDomain:@"LCXrayRustBridge"
                                           code:2001
                                       userInfo:@{NSLocalizedDescriptionKey: @"XrayRust C ABI unavailable for probe"}];
            return;
        }

        const char *cJSON = jsonConfig.UTF8String;
        if (_abiMode == LCXrayABIModeHandleBased) {
            void *h = _fnCreateSimple(cJSON);
            if (!h) {
                localErr = [NSError errorWithDomain:@"LCXrayRustBridge"
                                               code:2002
                                           userInfo:@{NSLocalizedDescriptionKey: @"Probe create failed"}];
                return;
            }
            int rc = _fnHandleStart ? _fnHandleStart(h) : 0;
            if (rc != 0) {
                if (_fnHandleDestroy) _fnHandleDestroy(h);
                localErr = [NSError errorWithDomain:@"LCXrayRustBridge"
                                               code:rc
                                           userInfo:@{NSLocalizedDescriptionKey: @"Probe start failed"}];
                return;
            }
            probe = [[LCXrayProbeHandle alloc] init];
            probe.rawHandle = h;
            probe.httpPort = httpPort;
            probe.socksPort = socksPort;
            probe.instanceTag = [NSString stringWithFormat:@"probe-%u", httpPort];
            probe.usedSingletonFallback = NO;
            return;
        }

        // Singleton fallback: temporarily borrow engine while preserving primary config for restoration
        if (_fnStopVoid) _fnStopVoid();
        int rc = -1;
        if (_abiMode == LCXrayABIModeSingletonIntErrPtr) {
            char *errStr = NULL;
            rc = _fnStartErrPtr(cJSON, &errStr);
            if (errStr && _fnFreeStr) _fnFreeStr(errStr);
        } else if (_abiMode == LCXrayABIModeSingletonInt) {
            rc = _fnStartInt(cJSON);
        }
        if (rc != 0) {
            localErr = [NSError errorWithDomain:@"LCXrayRustBridge"
                                           code:rc
                                       userInfo:@{NSLocalizedDescriptionKey: @"Singleton probe start failed"}];
            return;
        }
        probe = [[LCXrayProbeHandle alloc] init];
        probe.rawHandle = NULL;
        probe.httpPort = httpPort;
        probe.socksPort = socksPort;
        probe.instanceTag = [NSString stringWithFormat:@"singleton-probe-%u", httpPort];
        probe.usedSingletonFallback = YES;
    });

    if (error && localErr) *error = localErr;
    return probe;
}

- (void)stopProbeHandle:(LCXrayProbeHandle *)handle {
    if (!handle) return;
    dispatch_sync(_bridgeQueue, ^{
        if (!handle.usedSingletonFallback && handle.rawHandle) {
            if (_fnHandleStop) _fnHandleStop(handle.rawHandle);
            if (_fnHandleDestroy) _fnHandleDestroy(handle.rawHandle);
            handle.rawHandle = NULL;
        } else if (handle.usedSingletonFallback) {
            if (_fnStopVoid) _fnStopVoid();
            // Restore primary instance if it was running before the singleton probe
            if (_primaryRunning && _lastPrimaryJSON.length > 0) {
                const char *cJSON = _lastPrimaryJSON.UTF8String;
                if (_abiMode == LCXrayABIModeSingletonIntErrPtr) {
                    char *errStr = NULL;
                    _fnStartErrPtr(cJSON, &errStr);
                    if (errStr && _fnFreeStr) _fnFreeStr(errStr);
                } else if (_abiMode == LCXrayABIModeSingletonInt) {
                    _fnStartInt(cJSON);
                }
            }
        }
    });
}

@end
`,
  },
  {
    path: 'tweak/LCProxyNode.h',
    language: 'objc',
    category: 'tweak',
    summary: 'Canonical proxy node model supporting VLESS/REALITY/XHTTP, HY2, Trojan, VMess, SS-2022, WireGuard, SOCKS5, HTTP',
    content: `#import <Foundation/Foundation.h>

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
`,
  },
  {
    path: 'tweak/LCProxyNode.m',
    language: 'objc',
    category: 'tweak',
    summary: 'Canonical URI exporter (JSON -> clean URI) and persistent dictionary serialization',
    content: `#import "LCProxyNode.h"

static NSString *lc_percentEncode(NSString *str) {
    if (str.length == 0) return @"";
    NSMutableCharacterSet *allowed = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
    [allowed removeCharactersInString:@"&=?+#%/:@"];
    return [str stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: str;
}

static NSString *lc_fragmentEncode(NSString *str) {
    if (str.length == 0) return @"";
    NSMutableCharacterSet *allowed = [[NSCharacterSet URLFragmentAllowedCharacterSet] mutableCopy];
    [allowed removeCharactersInString:@"#%"];
    return [str stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: str;
}

static NSString *lc_formatHost(NSString *host) {
    if ([host containsString:@":"] && ![host hasPrefix:@"["]) {
        return [NSString stringWithFormat:@"[%@]", host];
    }
    return host ?: @"";
}

@implementation LCProxyNode

- (instancetype)init {
    self = [super init];
    if (self) {
        _nodeID = [[NSUUID UUID] UUIDString];
        _name = @"Unnamed Node";
        _network = @"raw";
        _security = @"none";
        _encryption = @"none";
        _tcpPingMs = -1;
        _realPingMs = -1;
        _wgMTU = 1280;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    LCProxyNode *copy = [LCProxyNode nodeFromDictionary:[self toDictionary]];
    return copy ?: [[LCProxyNode alloc] init];
}

+ (NSString *)protocolNameForType:(LCProxyProtocol)protocol {
    switch (protocol) {
        case LCProxyProtocolVLESS:       return @"vless";
        case LCProxyProtocolHysteria2:   return @"hysteria2";
        case LCProxyProtocolTrojan:      return @"trojan";
        case LCProxyProtocolVMess:       return @"vmess";
        case LCProxyProtocolShadowsocks: return @"shadowsocks";
        case LCProxyProtocolWireGuard:   return @"wireguard";
        case LCProxyProtocolSOCKS5:      return @"socks5";
        case LCProxyProtocolHTTP:        return @"http";
        default:                         return @"unknown";
    }
}

+ (LCProxyProtocol)protocolTypeFromString:(NSString *)str {
    NSString *lower = [[str stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([lower isEqualToString:@"vless"]) return LCProxyProtocolVLESS;
    if ([lower isEqualToString:@"hysteria2"] || [lower isEqualToString:@"hy2"]) return LCProxyProtocolHysteria2;
    if ([lower isEqualToString:@"trojan"]) return LCProxyProtocolTrojan;
    if ([lower isEqualToString:@"vmess"]) return LCProxyProtocolVMess;
    if ([lower isEqualToString:@"shadowsocks"] || [lower isEqualToString:@"ss"]) return LCProxyProtocolShadowsocks;
    if ([lower isEqualToString:@"wireguard"] || [lower isEqualToString:@"wg"]) return LCProxyProtocolWireGuard;
    if ([lower isEqualToString:@"socks"] || [lower isEqualToString:@"socks5"]) return LCProxyProtocolSOCKS5;
    if ([lower isEqualToString:@"http"] || [lower isEqualToString:@"https"]) return LCProxyProtocolHTTP;
    return LCProxyProtocolUnknown;
}

- (NSString *)protocolBadgeText {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    switch (self.protocol) {
        case LCProxyProtocolVLESS:
            [parts addObject:@"VLESS"];
            if ([self.security isEqualToString:@"reality"]) [parts addObject:@"REALITY"];
            else if ([self.security isEqualToString:@"tls"]) [parts addObject:@"TLS"];
            if (self.flow.length > 0 && [[self.flow lowercaseString] containsString:@"vision"]) {
                [parts addObject:@"Vision"];
            }
            if (self.network.length > 0 && ![self.network isEqualToString:@"raw"] && ![self.network isEqualToString:@"tcp"]) {
                [parts addObject:[self.network uppercaseString]];
            }
            break;
        case LCProxyProtocolHysteria2:
            [parts addObject:@"HY2"];
            if (self.hy2Obfs.length > 0) [parts addObject:@"OBFS"];
            break;
        case LCProxyProtocolTrojan:
            [parts addObject:@"Trojan"];
            if ([self.security isEqualToString:@"reality"]) [parts addObject:@"REALITY"];
            if (self.network.length > 0 && ![self.network isEqualToString:@"raw"] && ![self.network isEqualToString:@"tcp"]) {
                [parts addObject:[self.network uppercaseString]];
            }
            break;
        case LCProxyProtocolVMess:
            [parts addObject:@"VMess"];
            if (self.network.length > 0 && ![self.network isEqualToString:@"raw"] && ![self.network isEqualToString:@"tcp"]) {
                [parts addObject:[self.network uppercaseString]];
            }
            break;
        case LCProxyProtocolShadowsocks:
            if ([self.method hasPrefix:@"2022-"]) [parts addObject:@"SS-2022"];
            else [parts addObject:@"SS"];
            break;
        case LCProxyProtocolWireGuard:
            [parts addObject:@"WireGuard"];
            break;
        case LCProxyProtocolSOCKS5:
            [parts addObject:@"SOCKS5"];
            break;
        case LCProxyProtocolHTTP:
            [parts addObject:@"HTTP"];
            break;
        default:
            [parts addObject:@"PROXY"];
            break;
    }
    return [parts componentsJoinedByString:@" · "];
}

- (NSString *)toURIString {
    NSString *formattedHost = lc_formatHost(self.host);
    NSString *tag = lc_fragmentEncode(self.name.length > 0 ? self.name : self.host);

    if (self.protocol == LCProxyProtocolVLESS || self.protocol == LCProxyProtocolTrojan) {
        NSString *scheme = (self.protocol == LCProxyProtocolVLESS) ? @"vless" : @"trojan";
        NSMutableArray<NSString *> *q = [NSMutableArray array];

        if (self.protocol == LCProxyProtocolVLESS) {
            NSString *enc = self.encryption.length > 0 ? self.encryption : @"none";
            [q addObject:[NSString stringWithFormat:@"encryption=%@", lc_percentEncode(enc)]];
        }
        if (self.flow.length > 0) {
            [q addObject:[NSString stringWithFormat:@"flow=%@", lc_percentEncode(self.flow)]];
        }
        if (self.security.length > 0) {
            [q addObject:[NSString stringWithFormat:@"security=%@", lc_percentEncode(self.security)]];
        }
        if (self.sni.length > 0) {
            [q addObject:[NSString stringWithFormat:@"sni=%@", lc_percentEncode(self.sni)]];
        }
        if (self.fingerprint.length > 0) {
            [q addObject:[NSString stringWithFormat:@"fp=%@", lc_percentEncode(self.fingerprint)]];
        }
        if (self.alpn.count > 0) {
            [q addObject:[NSString stringWithFormat:@"alpn=%@", lc_percentEncode([self.alpn componentsJoinedByString:@","])]];
        }
        if (self.allowInsecure) {
            [q addObject:@"allowInsecure=1"];
        }
        if ([self.security isEqualToString:@"reality"]) {
            if (self.realityPublicKey.length > 0) {
                [q addObject:[NSString stringWithFormat:@"pbk=%@", lc_percentEncode(self.realityPublicKey)]];
            }
            if (self.realityShortId.length > 0) {
                [q addObject:[NSString stringWithFormat:@"sid=%@", lc_percentEncode(self.realityShortId)]];
            }
            if (self.realitySpiderX.length > 0) {
                [q addObject:[NSString stringWithFormat:@"spx=%@", lc_percentEncode(self.realitySpiderX)]];
            }
        }

        NSString *net = (self.network.length > 0) ? self.network : @"tcp";
        if ([net isEqualToString:@"raw"]) net = @"tcp";
        [q addObject:[NSString stringWithFormat:@"type=%@", lc_percentEncode(net)]];

        if ([net isEqualToString:@"xhttp"] || [net isEqualToString:@"splithttp"]) {
            if (self.path.length > 0) [q addObject:[NSString stringWithFormat:@"path=%@", lc_percentEncode(self.path)]];
            if (self.hostHeader.length > 0) [q addObject:[NSString stringWithFormat:@"host=%@", lc_percentEncode(self.hostHeader)]];
            if (self.xhttpMode.length > 0) [q addObject:[NSString stringWithFormat:@"mode=%@", lc_percentEncode(self.xhttpMode)]];
            if (self.xhttpExtra.count > 0) {
                NSData *extraData = [NSJSONSerialization dataWithJSONObject:self.xhttpExtra options:0 error:nil];
                if (extraData) {
                    NSString *extraStr = [[NSString alloc] initWithData:extraData encoding:NSUTF8StringEncoding];
                    if (extraStr.length > 0) [q addObject:[NSString stringWithFormat:@"extra=%@", lc_percentEncode(extraStr)]];
                }
            }
        } else if ([net isEqualToString:@"ws"] || [net isEqualToString:@"httpupgrade"]) {
            if (self.path.length > 0) [q addObject:[NSString stringWithFormat:@"path=%@", lc_percentEncode(self.path)]];
            if (self.hostHeader.length > 0) [q addObject:[NSString stringWithFormat:@"host=%@", lc_percentEncode(self.hostHeader)]];
        } else if ([net isEqualToString:@"grpc"]) {
            if (self.grpcServiceName.length > 0) [q addObject:[NSString stringWithFormat:@"serviceName=%@", lc_percentEncode(self.grpcServiceName)]];
            if (self.grpcAuthority.length > 0) [q addObject:[NSString stringWithFormat:@"authority=%@", lc_percentEncode(self.grpcAuthority)]];
            [q addObject:[NSString stringWithFormat:@"mode=%@", self.grpcMultiMode ? @"multi" : @"gun"]];
        }

        NSString *cred = lc_percentEncode(self.uuidOrPassword ?: @"");
        return [NSString stringWithFormat:@"%@://%@@%@:%u?%@#%@",
                scheme, cred, formattedHost, self.port, [q componentsJoinedByString:@"&"], tag];
    }

    if (self.protocol == LCProxyProtocolHysteria2) {
        NSMutableArray<NSString *> *q = [NSMutableArray array];
        if (self.sni.length > 0) [q addObject:[NSString stringWithFormat:@"sni=%@", lc_percentEncode(self.sni)]];
        if (self.allowInsecure) [q addObject:@"insecure=1"];
        if (self.hy2Obfs.length > 0) [q addObject:[NSString stringWithFormat:@"obfs=%@", lc_percentEncode(self.hy2Obfs)]];
        if (self.hy2ObfsPassword.length > 0) [q addObject:[NSString stringWithFormat:@"obfs-password=%@", lc_percentEncode(self.hy2ObfsPassword)]];
        if (self.hy2PinSHA256.length > 0) [q addObject:[NSString stringWithFormat:@"pinSHA256=%@", lc_percentEncode(self.hy2PinSHA256)]];
        NSString *queryPart = q.count > 0 ? [@"?" stringByAppendingString:[q componentsJoinedByString:@"&"]] : @"";
        return [NSString stringWithFormat:@"hysteria2://%@@%@:%u%@#%@",
                lc_percentEncode(self.uuidOrPassword ?: @""), formattedHost, self.port, queryPart, tag];
    }

    if (self.protocol == LCProxyProtocolVMess) {
        NSMutableDictionary *vm = [NSMutableDictionary dictionary];
        vm[@"v"] = @"2";
        vm[@"ps"] = self.name ?: self.host ?: @"VMess";
        vm[@"add"] = self.host ?: @"";
        vm[@"port"] = @(self.port);
        vm[@"id"] = self.uuidOrPassword ?: @"";
        vm[@"aid"] = @(0);
        vm[@"scy"] = self.method.length > 0 ? self.method : @"auto";
        vm[@"net"] = ([self.network isEqualToString:@"raw"] || self.network.length == 0) ? @"tcp" : self.network;
        vm[@"type"] = @"none";
        if (self.hostHeader.length > 0) vm[@"host"] = self.hostHeader;
        if (self.path.length > 0) vm[@"path"] = self.path;
        vm[@"tls"] = [self.security isEqualToString:@"tls"] ? @"tls" : @"";
        if (self.sni.length > 0) vm[@"sni"] = self.sni;
        if (self.fingerprint.length > 0) vm[@"fp"] = self.fingerprint;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:vm options:0 error:nil];
        NSString *b64 = [jsonData base64EncodedStringWithOptions:0] ?: @"";
        return [NSString stringWithFormat:@"vmess://%@", b64];
    }

    if (self.protocol == LCProxyProtocolShadowsocks) {
        NSString *userInfo = [NSString stringWithFormat:@"%@:%@",
                              self.method ?: @"aes-256-gcm", self.uuidOrPassword ?: @""];
        NSString *encoded = [[userInfo dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
        return [NSString stringWithFormat:@"ss://%@@%@:%u#%@", encoded, formattedHost, self.port, tag];
    }

    if (self.protocol == LCProxyProtocolWireGuard) {
        NSMutableArray<NSString *> *q = [NSMutableArray array];
        if (self.wgPeerPublicKey.length > 0) [q addObject:[NSString stringWithFormat:@"publickey=%@", lc_percentEncode(self.wgPeerPublicKey)]];
        if (self.wgPreSharedKey.length > 0) [q addObject:[NSString stringWithFormat:@"presharedkey=%@", lc_percentEncode(self.wgPreSharedKey)]];
        if (self.wgAddresses.count > 0) [q addObject:[NSString stringWithFormat:@"address=%@", lc_percentEncode([self.wgAddresses componentsJoinedByString:@","])]];
        if (self.wgReserved.count == 3) {
            [q addObject:[NSString stringWithFormat:@"reserved=%@,%@,%@", self.wgReserved[0], self.wgReserved[1], self.wgReserved[2]]];
        }
        if (self.wgMTU > 0) [q addObject:[NSString stringWithFormat:@"mtu=%ld", (long)self.wgMTU]];
        return [NSString stringWithFormat:@"wireguard://%@@%@:%u?%@#%@",
                lc_percentEncode(self.wgPrivateKey ?: @""), formattedHost, self.port, [q componentsJoinedByString:@"&"], tag];
    }

    if (self.protocol == LCProxyProtocolSOCKS5 || self.protocol == LCProxyProtocolHTTP) {
        NSString *scheme = (self.protocol == LCProxyProtocolSOCKS5) ? @"socks5" : @"http";
        if (self.username.length > 0 || self.uuidOrPassword.length > 0) {
            return [NSString stringWithFormat:@"%@://%@:%@@%@:%u#%@",
                    scheme,
                    lc_percentEncode(self.username ?: @""),
                    lc_percentEncode(self.uuidOrPassword ?: @""),
                    formattedHost, self.port, tag];
        }
        return [NSString stringWithFormat:@"%@://%@:%u#%@", scheme, formattedHost, self.port, tag];
    }

    return [NSString stringWithFormat:@"%@:%u", formattedHost, self.port];
}

- (NSDictionary<NSString *, id> *)toDictionary {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"nodeID"] = self.nodeID ?: [[NSUUID UUID] UUIDString];
    d[@"name"] = self.name ?: @"";
    if (self.subscriptionID) d[@"subscriptionID"] = self.subscriptionID;
    d[@"protocol"] = [LCProxyNode protocolNameForType:self.protocol];
    d[@"host"] = self.host ?: @"";
    d[@"port"] = @(self.port);
    if (self.uuidOrPassword) d[@"uuidOrPassword"] = self.uuidOrPassword;
    if (self.username) d[@"username"] = self.username;
    if (self.method) d[@"method"] = self.method;
    if (self.encryption) d[@"encryption"] = self.encryption;
    if (self.flow) d[@"flow"] = self.flow;
    d[@"network"] = self.network ?: @"raw";
    if (self.path) d[@"path"] = self.path;
    if (self.hostHeader) d[@"hostHeader"] = self.hostHeader;
    if (self.xhttpMode) d[@"xhttpMode"] = self.xhttpMode;
    if (self.xhttpExtra) d[@"xhttpExtra"] = self.xhttpExtra;
    if (self.grpcServiceName) d[@"grpcServiceName"] = self.grpcServiceName;
    if (self.grpcAuthority) d[@"grpcAuthority"] = self.grpcAuthority;
    d[@"grpcMultiMode"] = @(self.grpcMultiMode);
    d[@"security"] = self.security ?: @"none";
    if (self.sni) d[@"sni"] = self.sni;
    if (self.fingerprint) d[@"fingerprint"] = self.fingerprint;
    if (self.alpn) d[@"alpn"] = self.alpn;
    d[@"allowInsecure"] = @(self.allowInsecure);
    if (self.realityPublicKey) d[@"realityPublicKey"] = self.realityPublicKey;
    if (self.realityShortId) d[@"realityShortId"] = self.realityShortId;
    if (self.realitySpiderX) d[@"realitySpiderX"] = self.realitySpiderX;
    if (self.hy2Obfs) d[@"hy2Obfs"] = self.hy2Obfs;
    if (self.hy2ObfsPassword) d[@"hy2ObfsPassword"] = self.hy2ObfsPassword;
    if (self.hy2PinSHA256) d[@"hy2PinSHA256"] = self.hy2PinSHA256;
    if (self.hy2UpMbps > 0) d[@"hy2UpMbps"] = @(self.hy2UpMbps);
    if (self.hy2DownMbps > 0) d[@"hy2DownMbps"] = @(self.hy2DownMbps);
    if (self.wgPrivateKey) d[@"wgPrivateKey"] = self.wgPrivateKey;
    if (self.wgPeerPublicKey) d[@"wgPeerPublicKey"] = self.wgPeerPublicKey;
    if (self.wgPreSharedKey) d[@"wgPreSharedKey"] = self.wgPreSharedKey;
    if (self.wgAddresses) d[@"wgAddresses"] = self.wgAddresses;
    if (self.wgReserved) d[@"wgReserved"] = self.wgReserved;
    if (self.wgMTU > 0) d[@"wgMTU"] = @(self.wgMTU);
    d[@"tcpPingMs"] = @(self.tcpPingMs);
    d[@"realPingMs"] = @(self.realPingMs);
    return d;
}

+ (nullable instancetype)nodeFromDictionary:(NSDictionary<NSString *, id> *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    LCProxyNode *n = [[LCProxyNode alloc] init];
    if ([dict[@"nodeID"] isKindOfClass:[NSString class]]) n.nodeID = dict[@"nodeID"];
    if ([dict[@"name"] isKindOfClass:[NSString class]]) n.name = dict[@"name"];
    if ([dict[@"subscriptionID"] isKindOfClass:[NSString class]]) n.subscriptionID = dict[@"subscriptionID"];
    if ([dict[@"protocol"] isKindOfClass:[NSString class]]) {
        n.protocol = [LCProxyNode protocolTypeFromString:dict[@"protocol"]];
    }
    if ([dict[@"host"] isKindOfClass:[NSString class]]) n.host = dict[@"host"];
    n.port = (uint16_t)[dict[@"port"] unsignedIntValue];
    if ([dict[@"uuidOrPassword"] isKindOfClass:[NSString class]]) n.uuidOrPassword = dict[@"uuidOrPassword"];
    if ([dict[@"username"] isKindOfClass:[NSString class]]) n.username = dict[@"username"];
    if ([dict[@"method"] isKindOfClass:[NSString class]]) n.method = dict[@"method"];
    if ([dict[@"encryption"] isKindOfClass:[NSString class]]) n.encryption = dict[@"encryption"];
    if ([dict[@"flow"] isKindOfClass:[NSString class]]) n.flow = dict[@"flow"];
    if ([dict[@"network"] isKindOfClass:[NSString class]]) n.network = dict[@"network"];
    if ([dict[@"path"] isKindOfClass:[NSString class]]) n.path = dict[@"path"];
    if ([dict[@"hostHeader"] isKindOfClass:[NSString class]]) n.hostHeader = dict[@"hostHeader"];
    if ([dict[@"xhttpMode"] isKindOfClass:[NSString class]]) n.xhttpMode = dict[@"xhttpMode"];
    if ([dict[@"xhttpExtra"] isKindOfClass:[NSDictionary class]]) n.xhttpExtra = dict[@"xhttpExtra"];
    if ([dict[@"grpcServiceName"] isKindOfClass:[NSString class]]) n.grpcServiceName = dict[@"grpcServiceName"];
    if ([dict[@"grpcAuthority"] isKindOfClass:[NSString class]]) n.grpcAuthority = dict[@"grpcAuthority"];
    n.grpcMultiMode = [dict[@"grpcMultiMode"] boolValue];
    if ([dict[@"security"] isKindOfClass:[NSString class]]) n.security = dict[@"security"];
    if ([dict[@"sni"] isKindOfClass:[NSString class]]) n.sni = dict[@"sni"];
    if ([dict[@"fingerprint"] isKindOfClass:[NSString class]]) n.fingerprint = dict[@"fingerprint"];
    if ([dict[@"alpn"] isKindOfClass:[NSArray class]]) n.alpn = dict[@"alpn"];
    n.allowInsecure = [dict[@"allowInsecure"] boolValue];
    if ([dict[@"realityPublicKey"] isKindOfClass:[NSString class]]) n.realityPublicKey = dict[@"realityPublicKey"];
    if ([dict[@"realityShortId"] isKindOfClass:[NSString class]]) n.realityShortId = dict[@"realityShortId"];
    if ([dict[@"realitySpiderX"] isKindOfClass:[NSString class]]) n.realitySpiderX = dict[@"realitySpiderX"];
    if ([dict[@"hy2Obfs"] isKindOfClass:[NSString class]]) n.hy2Obfs = dict[@"hy2Obfs"];
    if ([dict[@"hy2ObfsPassword"] isKindOfClass:[NSString class]]) n.hy2ObfsPassword = dict[@"hy2ObfsPassword"];
    if ([dict[@"hy2PinSHA256"] isKindOfClass:[NSString class]]) n.hy2PinSHA256 = dict[@"hy2PinSHA256"];
    n.hy2UpMbps = [dict[@"hy2UpMbps"] integerValue];
    n.hy2DownMbps = [dict[@"hy2DownMbps"] integerValue];
    if ([dict[@"wgPrivateKey"] isKindOfClass:[NSString class]]) n.wgPrivateKey = dict[@"wgPrivateKey"];
    if ([dict[@"wgPeerPublicKey"] isKindOfClass:[NSString class]]) n.wgPeerPublicKey = dict[@"wgPeerPublicKey"];
    if ([dict[@"wgPreSharedKey"] isKindOfClass:[NSString class]]) n.wgPreSharedKey = dict[@"wgPreSharedKey"];
    if ([dict[@"wgAddresses"] isKindOfClass:[NSArray class]]) n.wgAddresses = dict[@"wgAddresses"];
    if ([dict[@"wgReserved"] isKindOfClass:[NSArray class]]) n.wgReserved = dict[@"wgReserved"];
    n.wgMTU = [dict[@"wgMTU"] integerValue] ?: 1280;
    n.tcpPingMs = dict[@"tcpPingMs"] ? [dict[@"tcpPingMs"] integerValue] : -1;
    n.realPingMs = dict[@"realPingMs"] ? [dict[@"realPingMs"] integerValue] : -1;

    if (n.protocol == LCProxyProtocolUnknown || n.host.length == 0 || n.port == 0) {
        return nil;
    }
    return n;
}

@end
`,
  },
];
