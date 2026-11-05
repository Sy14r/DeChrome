#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Commands for the isolated Chrome process, using only its loopback CDP port.
@interface DCBrowser : NSObject
+ (instancetype)sharedBrowser;

/// Set by the palette so its panel never changes which browser window is used.
@property (nonatomic, weak, nullable) NSWindow *targetWindow;

- (void)currentPageInfo:(void (^)(NSDictionary * _Nullable info,
                                 NSError * _Nullable error))completion;
- (void)checkCommandInterface:(void (^)(NSError * _Nullable error))completion;
- (void)navigate:(NSString *)url completion:(void (^)(NSError * _Nullable error))completion;
/// Navigate the stable tab target chosen by the palette, even if another tab activates meanwhile.
- (void)navigate:(NSString *)url tabID:(NSString *)tabID completion:(void (^)(NSError * _Nullable error))completion;
- (void)performAction:(NSString *)action completion:(void (^)(NSError * _Nullable error))completion;
- (void)listTabs:(void (^)(NSArray<NSDictionary *> * _Nullable tabs, NSError * _Nullable error))completion;
- (void)activateTab:(NSString *)targetId completion:(void (^)(NSError * _Nullable error))completion;
- (void)focusCurrentPage;
@end

NS_ASSUME_NONNULL_END
