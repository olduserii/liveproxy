#import "LCXrayRustBridge.h"
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
