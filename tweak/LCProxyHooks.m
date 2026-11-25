#import "LCProxyHooks.h"
#import "fishhook.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <CFNetwork/CFNetwork.h>
#import <WebKit/WebKit.h>
#import <Network/Network.h>
#import <dlfcn.h>
#import <stdatomic.h>

static _Atomic uint16_t gActiveHttpPort  = 0;
static _Atomic uint16_t gActiveSocksPort = 0;
static _Atomic bool     gProxyEnabled    = false;
static __thread int     gBypassDepth     = 0;

static const void *kLCDirectBypassAssocKey = &kLCDirectBypassAssocKey;

static CFDictionaryRef (*orig_CFNetworkCopySystemProxySettings)(void) = NULL;

void LCProxyHooksEnterBypass(void) {
    gBypassDepth++;
}

void LCProxyHooksLeaveBypass(void) {
    if (gBypassDepth > 0) gBypassDepth--;
}

static BOOL lc_shouldApplyProxy(void) {
    if (gBypassDepth > 0) return NO;
    if (!atomic_load_explicit(&gProxyEnabled, memory_order_acquire)) return NO;
    return atomic_load_explicit(&gActiveHttpPort, memory_order_acquire) > 0;
}

static NSDictionary *lc_buildProxyDictionary(void) {
    uint16_t httpPort  = atomic_load_explicit(&gActiveHttpPort, memory_order_acquire);
    uint16_t socksPort = atomic_load_explicit(&gActiveSocksPort, memory_order_acquire);
    if (httpPort == 0) return @{};

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[(NSString *)kCFNetworkProxiesHTTPEnable]  = @YES;
    dict[(NSString *)kCFNetworkProxiesHTTPProxy]   = @"127.0.0.1";
    dict[(NSString *)kCFNetworkProxiesHTTPPort]    = @(httpPort);

    dict[@"HTTPSEnable"] = @YES;
    dict[@"HTTPSProxy"]  = @"127.0.0.1";
    dict[@"HTTPSPort"]   = @(httpPort);

    if (socksPort > 0) {
        dict[@"SOCKSEnable"] = @YES;
        dict[@"SOCKSProxy"]  = @"127.0.0.1";
        dict[@"SOCKSPort"]   = @(socksPort);
    }

    // Strict loopback exclusion to prevent proxy self-loops
    dict[(NSString *)kCFNetworkProxiesExceptionsList] = @[
        @"127.0.0.1",
        @"localhost",
        @"::1",
        @"*.local",
        @"169.254/16"
    ];
    dict[@"ExcludeSimpleHostnames"] = @YES;
    return dict;
}

#pragma mark - iOS 17+ WKWebView proxyConfigurations Helper

typedef void *(*lc_nw_proxy_http_connect_fn)(nw_endpoint_t proxy_endpoint, nw_parameters_t tls_options);
typedef void  (*lc_nw_proxy_add_excluded_fn)(void *proxy_config, const char *domain);

static void lc_applyWKWebViewProxyIfSupported(WKWebsiteDataStore *store) {
    if (!store) return;
    if (@available(iOS 17.0, *)) {
        SEL setProxySel = NSSelectorFromString(@"setProxyConfigurations:");
        if (![store respondsToSelector:setProxySel]) return;

        if (!lc_shouldApplyProxy()) {
            ((void (*)(id, SEL, id))objc_msgSend)(store, setProxySel, @[]);
            return;
        }

        uint16_t httpPort = atomic_load_explicit(&gActiveHttpPort, memory_order_acquire);
        if (httpPort == 0) return;

        static lc_nw_proxy_http_connect_fn fnCreateHttpConnect = NULL;
        static lc_nw_proxy_add_excluded_fn fnAddExcluded = NULL;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            fnCreateHttpConnect = (lc_nw_proxy_http_connect_fn)dlsym(RTLD_DEFAULT, "nw_proxy_config_create_http_connect");
            fnAddExcluded = (lc_nw_proxy_add_excluded_fn)dlsym(RTLD_DEFAULT, "nw_proxy_config_add_excluded_domain");
        });

        if (!fnCreateHttpConnect) return;

        NSString *portStr = [NSString stringWithFormat:@"%u", httpPort];
        nw_endpoint_t endpoint = nw_endpoint_create_host("127.0.0.1", portStr.UTF8String);
        void *nwProxyCfg = fnCreateHttpConnect(endpoint, NULL);
        if (nwProxyCfg) {
            if (fnAddExcluded) {
                fnAddExcluded(nwProxyCfg, "127.0.0.1");
                fnAddExcluded(nwProxyCfg, "localhost");
                fnAddExcluded(nwProxyCfg, "::1");
            }
            id proxyObj = (__bridge_transfer id)nwProxyCfg;
            ((void (*)(id, SEL, id))objc_msgSend)(store, setProxySel, @[proxyObj]);
        }
    }
}

void LCProxyHooksSyncPorts(uint16_t httpPort, uint16_t socksPort, BOOL enabled) {
    atomic_store_explicit(&gActiveHttpPort, httpPort, memory_order_release);
    atomic_store_explicit(&gActiveSocksPort, socksPort, memory_order_release);
    atomic_store_explicit(&gProxyEnabled, enabled && httpPort > 0, memory_order_release);

    if (@available(iOS 17.0, *)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            lc_applyWKWebViewProxyIfSupported([WKWebsiteDataStore defaultDataStore]);
        });
    }
}

#pragma mark - Direct Bypass Configuration

NSURLSessionConfiguration *LCProxyCreateDirectSessionConfiguration(void) {
    LCProxyHooksEnterBypass();
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    objc_setAssociatedObject(cfg, kLCDirectBypassAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    cfg.connectionProxyDictionary = @{};
    LCProxyHooksLeaveBypass();
    return cfg;
}

#pragma mark - 1. NSURLSessionConfiguration Swizzling

static NSURLSessionConfiguration *(*orig_defaultSessionConfiguration)(id, SEL) = NULL;
static NSURLSessionConfiguration *(*orig_ephemeralSessionConfiguration)(id, SEL) = NULL;
static NSDictionary *(*orig_connectionProxyDictionary)(id, SEL) = NULL;

static NSURLSessionConfiguration *lc_defaultSessionConfiguration(id self, SEL _cmd) {
    NSURLSessionConfiguration *cfg = orig_defaultSessionConfiguration(self, _cmd);
    if (cfg && lc_shouldApplyProxy() && !objc_getAssociatedObject(cfg, kLCDirectBypassAssocKey)) {
        cfg.connectionProxyDictionary = lc_buildProxyDictionary();
    }
    return cfg;
}

static NSURLSessionConfiguration *lc_ephemeralSessionConfiguration(id self, SEL _cmd) {
    NSURLSessionConfiguration *cfg = orig_ephemeralSessionConfiguration(self, _cmd);
    if (cfg && lc_shouldApplyProxy() && !objc_getAssociatedObject(cfg, kLCDirectBypassAssocKey)) {
        cfg.connectionProxyDictionary = lc_buildProxyDictionary();
    }
    return cfg;
}

static NSDictionary *lc_connectionProxyDictionary(id self, SEL _cmd) {
    if (objc_getAssociatedObject(self, kLCDirectBypassAssocKey)) {
        return @{};
    }
    if (lc_shouldApplyProxy()) {
        return lc_buildProxyDictionary();
    }
    return orig_connectionProxyDictionary(self, _cmd);
}

#pragma mark - 2. CFNetworkCopySystemProxySettings via fishhook

static CFDictionaryRef lc_CFNetworkCopySystemProxySettings(void) {
    if (lc_shouldApplyProxy()) {
        NSDictionary *dict = lc_buildProxyDictionary();
        return (__bridge_retained CFDictionaryRef)dict;
    }
    if (orig_CFNetworkCopySystemProxySettings) {
        return orig_CFNetworkCopySystemProxySettings();
    }
    return (__bridge_retained CFDictionaryRef)@{};
}

#pragma mark - 3. WKWebsiteDataStore Swizzling (iOS 17+)

static WKWebsiteDataStore *(*orig_wkDefaultDataStore)(id, SEL) = NULL;
static WKWebsiteDataStore *(*orig_wkNonPersistentDataStore)(id, SEL) = NULL;

static WKWebsiteDataStore *lc_wkDefaultDataStore(id self, SEL _cmd) {
    WKWebsiteDataStore *store = orig_wkDefaultDataStore(self, _cmd);
    lc_applyWKWebViewProxyIfSupported(store);
    return store;
}

static WKWebsiteDataStore *lc_wkNonPersistentDataStore(id self, SEL _cmd) {
    WKWebsiteDataStore *store = orig_wkNonPersistentDataStore(self, _cmd);
    lc_applyWKWebViewProxyIfSupported(store);
    return store;
}

#pragma mark - Swizzle Helper & Installation

static void lc_swizzleClassMethod(Class cls, SEL sel, IMP replacement, IMP *origOut) {
    Method m = class_getClassMethod(cls, sel);
    if (!m) return;
    *origOut = method_setImplementation(m, replacement);
}

static void lc_swizzleInstanceMethod(Class cls, SEL sel, IMP replacement, IMP *origOut) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    *origOut = method_setImplementation(m, replacement);
}

void LCProxyHooksInstall(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 1. NSURLSessionConfiguration
        Class cfgCls = [NSURLSessionConfiguration class];
        lc_swizzleClassMethod(cfgCls, @selector(defaultSessionConfiguration),
                              (IMP)lc_defaultSessionConfiguration, (IMP *)&orig_defaultSessionConfiguration);
        lc_swizzleClassMethod(cfgCls, @selector(ephemeralSessionConfiguration),
                              (IMP)lc_ephemeralSessionConfiguration, (IMP *)&orig_ephemeralSessionConfiguration);
        lc_swizzleInstanceMethod(cfgCls, @selector(connectionProxyDictionary),
                                 (IMP)lc_connectionProxyDictionary, (IMP *)&orig_connectionProxyDictionary);

        // Also swizzle internal __NSCFURLSessionConfiguration if Apple uses a private subclass
        Class internalCfgCls = NSClassFromString(@"__NSCFURLSessionConfiguration");
        if (internalCfgCls && internalCfgCls != cfgCls) {
            IMP dummy = NULL;
            Method m = class_getInstanceMethod(internalCfgCls, @selector(connectionProxyDictionary));
            if (m && method_getImplementation(m) != (IMP)lc_connectionProxyDictionary) {
                dummy = method_setImplementation(m, (IMP)lc_connectionProxyDictionary);
                if (!orig_connectionProxyDictionary) orig_connectionProxyDictionary = (NSDictionary *(*)(id, SEL))dummy;
            }
        }

        // 2. CFNetworkCopySystemProxySettings via fishhook
        struct rebinding rebs[1] = {
            {
                "CFNetworkCopySystemProxySettings",
                (void *)lc_CFNetworkCopySystemProxySettings,
                (void **)&orig_CFNetworkCopySystemProxySettings
            }
        };
        rebind_symbols(rebs, 1);

        // 3. WKWebsiteDataStore (iOS 17+)
        if (@available(iOS 17.0, *)) {
            Class wkCls = [WKWebsiteDataStore class];
            if (wkCls) {
                lc_swizzleClassMethod(wkCls, @selector(defaultDataStore),
                                      (IMP)lc_wkDefaultDataStore, (IMP *)&orig_wkDefaultDataStore);
                lc_swizzleClassMethod(wkCls, @selector(nonPersistentDataStore),
                                      (IMP)lc_wkNonPersistentDataStore, (IMP *)&orig_wkNonPersistentDataStore);
            }
        }
    });
}
