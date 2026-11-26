#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCProxyUI : NSObject

+ (instancetype)sharedUI;

/// Installs the 2-finger triple-tap menu gesture recognizer (and optional floating button) onto the active key window.
- (void)installOverlayIfNeeded;

/// Shows or hides the optional floating button.
- (void)toggleFloatingButtonVisibility;

/// Opens the compact modal control sheet.
- (void)presentControlPanel;

/// Opens or dismisses the modal control sheet (triggered by 2-finger triple-tap).
- (void)toggleControlPanel;

@end

NS_ASSUME_NONNULL_END
