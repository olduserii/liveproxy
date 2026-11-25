#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Installs all in-process network interception hooks once at process launch:
/// 1) NSURLSessionConfiguration method swizzling
/// 2) CFNetworkCopySystemProxySettings rebinding via fishhook
/// 3) WKWebsiteDataStore proxyConfigurations swizzling (iOS 17+)
void LCProxyHooksInstall(void);

/// Atomically updates active loopback proxy ports and enabled state across all hooks.
void LCProxyHooksSyncPorts(uint16_t httpPort, uint16_t socksPort, BOOL enabled);

/// Returns a clean NSURLSessionConfiguration that explicitly bypasses all LCProxy hooks
/// (used for subscription downloads and direct connectivity checks to prevent loops).
NSURLSessionConfiguration *LCProxyCreateDirectSessionConfiguration(void);

/// Thread-local loop-bypass guard for internal networking performed on behalf of xray-rust or tweak updater.
void LCProxyHooksEnterBypass(void);
void LCProxyHooksLeaveBypass(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
