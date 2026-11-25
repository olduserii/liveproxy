#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCProxyUI : NSObject

+ (instancetype)sharedUI;

/// Installs the floating draggable button and 3-finger triple-tap gesture recognizer onto the active window scene.
- (void)installOverlayIfNeeded;

/// Shows or hides the floating button (also triggered by 3-finger triple-tap).
- (void)toggleFloatingButtonVisibility;

/// Opens the compact modal control sheet.
- (void)presentControlPanel;

@end

NS_ASSUME_NONNULL_END
