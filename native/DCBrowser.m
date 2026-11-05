#import "DCBrowser.h"
#import "DCBrowserTargetPolicy.h"
#import <objc/runtime.h>
#import <fcntl.h>
#import <unistd.h>

static NSString *const DCBrowserErrorDomain = @"DeChrome.Browser";

static NSError *DCBrowserError(NSInteger code, NSString *message) {
  return [NSError errorWithDomain:DCBrowserErrorDomain code:code
                        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static void DCOnMain(dispatch_block_t block) {
  if (NSThread.isMainThread) block();
  else dispatch_async(dispatch_get_main_queue(), block);
}

static void DCLogTabTargetCounts(NSUInteger discovered, NSUInteger auxiliary,
                                NSUInteger missingWindow, NSUInteger browserTabs,
                                NSUInteger failures) {
  const char *path = getenv("DECHROME_LOG_PATH");
  if (!path || !*path) return;
  NSString *line = [NSString stringWithFormat:
      @"[DeChrome pid=%d] tab targets discovered=%lu auxiliary=%lu missingBrowserWindow=%lu browserTabs=%lu failures=%lu\n",
      getpid(), (unsigned long)discovered, (unsigned long)auxiliary,
      (unsigned long)missingWindow, (unsigned long)browserTabs, (unsigned long)failures];
  NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
  int descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0600);
  if (descriptor >= 0) { (void)write(descriptor, data.bytes, data.length); close(descriptor); }
}

typedef void (^DCProtocolReply)(NSDictionary * _Nullable result, NSError * _Nullable error);

// One connection belongs to one palette action. Requests are correlated by ID;
// unsolicited protocol events are ignored. No connection survives the action.
@interface DCCDPConnection : NSObject
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionWebSocketTask *socket;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, DCProtocolReply> *pending;
@property (nonatomic) NSUInteger nextID;
@property (nonatomic) BOOL closed;
@property (nonatomic, copy) void (^eventHandler)(NSDictionary *message);
- (instancetype)initWithURL:(NSURL *)url;
- (void)sendMethod:(NSString *)method params:(NSDictionary *)params completion:(DCProtocolReply)completion;
- (void)sendMethod:(NSString *)method params:(NSDictionary *)params sessionID:(NSString *)sessionID completion:(DCProtocolReply)completion;
- (void)close;
@end

@implementation DCCDPConnection
- (instancetype)initWithURL:(NSURL *)url {
  self = [super init];
  if (self) {
    _pending = [NSMutableDictionary new];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.connectionProxyDictionary = @{};
    configuration.timeoutIntervalForRequest = 5;
    configuration.timeoutIntervalForResource = 8;
    _session = [NSURLSession sessionWithConfiguration:configuration];
    _socket = [_session webSocketTaskWithURL:url];
    [_socket resume];
    [self receiveNext];
  }
  return self;
}

- (void)receiveNext {
  if (self.closed) return;
  __weak DCCDPConnection *weakSelf = self;
  [self.socket receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
    DCOnMain(^{
      DCCDPConnection *connection = weakSelf;
      if (!connection || connection.closed) return;
      if (error) {
        [connection fail:error];
        return;
      }
      NSData *data = message.type == NSURLSessionWebSocketMessageTypeString ?
          [message.string dataUsingEncoding:NSUTF8StringEncoding] : message.data;
      id decoded = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
      if (![decoded isKindOfClass:NSDictionary.class]) {
        [connection fail:DCBrowserError(11, @"Chrome returned an invalid command response.")];
        return;
      }
      NSDictionary *reply = decoded;
      if ([reply[@"method"] isKindOfClass:NSString.class] && connection.eventHandler)
        connection.eventHandler(reply);
      NSNumber *identifier = [reply[@"id"] isKindOfClass:NSNumber.class] ? reply[@"id"] : nil;
      DCProtocolReply callback = identifier ? connection.pending[identifier] : nil;
      if (callback) {
        [connection.pending removeObjectForKey:identifier];
        NSDictionary *protocolError = [reply[@"error"] isKindOfClass:NSDictionary.class] ? reply[@"error"] : nil;
        if (protocolError) {
          NSString *description = [protocolError[@"message"] isKindOfClass:NSString.class] ?
              protocolError[@"message"] : @"Chrome could not perform that command.";
          NSMutableDictionary *details = [@{NSLocalizedDescriptionKey:description} mutableCopy];
          if ([protocolError[@"code"] isKindOfClass:NSNumber.class])
            details[@"CDPCode"] = protocolError[@"code"];
          callback(nil, [NSError errorWithDomain:DCBrowserErrorDomain code:12 userInfo:details]);
        } else {
          NSDictionary *result = [reply[@"result"] isKindOfClass:NSDictionary.class] ? reply[@"result"] : @{};
          callback(result, nil);
        }
      }
      [connection receiveNext];
    });
  }];
}

- (void)sendMethod:(NSString *)method params:(NSDictionary *)params completion:(DCProtocolReply)completion {
  [self sendMethod:method params:params sessionID:nil completion:completion];
}

- (void)sendMethod:(NSString *)method params:(NSDictionary *)params sessionID:(NSString *)sessionID completion:(DCProtocolReply)completion {
  NSAssert(NSThread.isMainThread, @"CDP connection state belongs to the main queue");
  if (self.closed) {
    completion(nil, DCBrowserError(13, @"Chrome's command connection is closed."));
    return;
  }
  NSNumber *identifier = @(++self.nextID);
  NSMutableDictionary *request = [@{ @"id": identifier, @"method": method, @"params": params } mutableCopy];
  if (sessionID.length) request[@"sessionId"] = sessionID;
  NSError *encodingError;
  NSData *data = [NSJSONSerialization dataWithJSONObject:request options:0 error:&encodingError];
  if (!data) {
    completion(nil, encodingError);
    return;
  }
  self.pending[identifier] = [completion copy];
  NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc]
      initWithString:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
  __weak DCCDPConnection *weakSelf = self;
  [self.socket sendMessage:message completionHandler:^(NSError *error) {
    if (!error) return;
    DCOnMain(^{ [weakSelf fail:error]; });
  }];
  // The strong capture keeps this action's connection alive even if the caller
  // has no other reference. Closing clears pending callbacks and breaks cycles.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (self.pending[identifier])
      [self fail:DCBrowserError(14, @"Chrome did not respond. Try the command again.")];
  });
}

- (void)fail:(NSError *)error {
  if (self.closed) return;
  NSArray<DCProtocolReply> *callbacks = self.pending.allValues;
  [self.pending removeAllObjects];
  [self close];
  for (DCProtocolReply callback in callbacks) callback(nil, error);
}

- (void)close {
  if (self.closed) return;
  self.closed = YES;
  self.eventHandler = nil;
  [self.pending removeAllObjects];
  [self.socket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
  [self.session invalidateAndCancel];
}
@end

@interface DCBrowser ()
@property (nonatomic, strong) NSURLSession *httpSession;
- (void)resolveTargetForWindow:(NSWindow *)owner completion:(void (^)(NSDictionary *target, NSError *error))completion;
- (void)resolveTabPageForWindow:(NSWindow *)owner completion:(void (^)(NSDictionary *target, NSError *error))completion;
- (void)resolveTabPageForTabID:(NSString *)tabID window:(NSWindow *)owner completion:(void (^)(NSDictionary *target, NSError *error))completion;
- (void)navigateURL:(NSString *)url tabID:(NSString *)tabID window:(NSWindow *)owner completion:(void (^)(NSError *error))completion;
- (void)listTabsForWindow:(NSWindow *)owner completion:(void (^)(NSArray<NSDictionary *> *tabs, NSError *error))completion;
- (void)activateTab:(NSString *)targetId window:(NSWindow *)owner completion:(void (^)(NSError *error))completion;
- (BOOL)performMenuAction:(NSString *)action window:(NSWindow *)owner error:(NSError **)error;
- (NSURL *)browserSocketURL:(NSError **)error;
@end

static const void *DCTabWindowIDKey = &DCTabWindowIDKey;
static BOOL DCTabMode(void) {
  const char *mode = getenv("DECHROME_TAB_MODE");
  return mode && strcmp(mode, "1") == 0;
}

// Retaining a window during a protocol request does not mean it is still open.
// Keep delayed actions bound to a live browser window, excluding the palette,
// sheets and Chromium's auxiliary windows.
static BOOL DCBrowserWindowEligible(NSWindow *window) {
  if (!window || ![NSApp.windows containsObject:window] ||
      [window isKindOfClass:NSPanel.class] || window.parentWindow || window.sheetParent ||
      window.level != NSNormalWindowLevel || !window.contentView ||
      !(window.styleMask & NSWindowStyleMaskTitled) ||
      !(window.styleMask & NSWindowStyleMaskResizable)) return NO;
  for (Class cls = window.class; cls; cls = class_getSuperclass(cls)) {
    NSString *name = NSStringFromClass(cls);
    if ([name isEqualToString:@"BrowserNativeWidgetWindow"] ||
        [name isEqualToString:@"NativeWidgetMacNSWindow"]) return YES;
  }
  return NO;
}

static BOOL DCBrowserWindowUsable(NSWindow *window) {
  return DCBrowserWindowEligible(window) && window.visible;
}

static NSError *DCBrowserWindowError(NSWindow *window) {
  return DCBrowserWindowUsable(window) ? nil :
      DCBrowserError(29, @"This Chrome window has closed or is no longer available.");
}

static void DCFindFocusView(NSView *view, NSView **best, CGFloat *bestArea) {
  if (view.hidden || view.alphaValue == 0) return;
  if ([NSStringFromClass(view.class) containsString:@"RenderWidgetHostViewCocoa"] &&
      view.acceptsFirstResponder) {
    CGFloat area = NSWidth(view.bounds) * NSHeight(view.bounds);
    if (area > *bestArea) { *bestArea = area; *best = view; }
  }
  for (NSView *child in view.subviews) DCFindFocusView(child, best, bestArea);
}

@implementation DCBrowser
+ (instancetype)sharedBrowser {
  static DCBrowser *browser;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ browser = [DCBrowser new]; });
  return browser;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.connectionProxyDictionary = @{};
    configuration.timeoutIntervalForRequest = 3;
    configuration.timeoutIntervalForResource = 5;
    configuration.URLCache = nil;
    _httpSession = [NSURLSession sessionWithConfiguration:configuration];
  }
  return self;
}

- (void)resolveTargetForWindow:(NSWindow *)owner completion:(void (^)(NSDictionary * _Nullable target, NSError * _Nullable error))completion {
  NSAssert(NSThread.isMainThread, @"Read AppKit state on the main thread");
  NSError *ownerError = DCBrowserWindowError(owner);
  if (ownerError) { completion(nil, ownerError); return; }
  if (DCTabMode()) { [self resolveTabPageForWindow:owner completion:completion]; return; }
  const char *profile = getenv("DECHROME_PROFILE_PATH");
  NSString *profilePath = profile ? [NSString stringWithUTF8String:profile] : nil;
  if (!profilePath.isAbsolutePath) {
    completion(nil, DCBrowserError(1, @"The command palette needs a Chrome launch from ./dechrome."));
    return;
  }
  NSString *contents = [NSString stringWithContentsOfFile:
      [profilePath stringByAppendingPathComponent:@"DevToolsActivePort"]
      encoding:NSUTF8StringEncoding error:nil];
  NSString *firstLine = [[contents componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] firstObject];
  NSScanner *scanner = [NSScanner scannerWithString:firstLine ?: @""];
  int port = 0;
  if (![scanner scanInt:&port] || !scanner.isAtEnd || port < 1 || port > 65535) {
    completion(nil, DCBrowserError(2, @"Chrome's command service is starting. Try again in a moment."));
    return;
  }
  NSString *windowTitle = owner.title ?: @"";
  NSString *suffix = @" - Google Chrome";
  if ([windowTitle hasSuffix:suffix])
    windowTitle = [windowTitle substringToIndex:windowTitle.length - suffix.length];
  NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/json/list", port]];
  NSURLSessionDataTask *task = [self.httpSession dataTaskWithURL:url
      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    DCOnMain(^{
      NSError *closedError = DCBrowserWindowError(owner);
      if (closedError) { completion(nil, closedError); return; }
      if (error) {
        completion(nil, DCBrowserError(3, @"Could not connect to this Chrome window. Relaunch with ./dechrome."));
        return;
      }
      if (![response isKindOfClass:NSHTTPURLResponse.class] || [(NSHTTPURLResponse *)response statusCode] != 200) {
        completion(nil, DCBrowserError(4, @"Chrome's command service is unavailable."));
        return;
      }
      id decoded = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
      if (![decoded isKindOfClass:NSArray.class]) {
        completion(nil, DCBrowserError(5, @"Chrome returned an invalid page list."));
        return;
      }
      NSMutableArray<NSDictionary *> *pages = [NSMutableArray new];
      NSMutableArray<NSDictionary *> *matches = [NSMutableArray new];
      for (id item in decoded) {
        if (![item isKindOfClass:NSDictionary.class] || ![item[@"type"] isEqual:@"page"] ||
            ![item[@"id"] isKindOfClass:NSString.class] ||
            ![item[@"webSocketDebuggerUrl"] isKindOfClass:NSString.class]) continue;
        NSURLComponents *socket = [NSURLComponents componentsWithString:item[@"webSocketDebuggerUrl"]];
        if (![socket.scheme isEqualToString:@"ws"] ||
            ![@[@"localhost", @"127.0.0.1", @"::1"] containsObject:socket.host] ||
            socket.port.intValue != port || ![socket.path hasPrefix:@"/devtools/page/"]) continue;
        // Never use a host supplied by page metadata, even a loopback hostname.
        socket.host = @"127.0.0.1";
        NSMutableDictionary *page = [item mutableCopy];
        page[@"webSocketDebuggerUrl"] = socket.URL.absoluteString;
        [pages addObject:page];
        if (windowTitle.length && [item[@"title"] isEqual:windowTitle]) [matches addObject:page];
      }
      NSDictionary *target = matches.count == 1 ? matches.firstObject :
          (pages.count == 1 ? pages.firstObject : nil);
      if (!target) {
        NSString *message = pages.count ?
            @"More than one page is open. Focus a window with a distinct page title and try again." :
            @"No navigable page was found in this Chrome process.";
        completion(nil, DCBrowserError(6, message));
        return;
      }
      completion(target, nil);
    });
  }];
  [task resume];
}

- (void)currentPageInfo:(void (^)(NSDictionary *, NSError *))completion {
  DCOnMain(^{
    NSWindow *owner = self.targetWindow ?: NSApp.mainWindow;
    [self resolveTargetForWindow:owner completion:^(NSDictionary *target, NSError *error) {
      if (error) { completion(nil, error); return; }
      completion(@{ @"url": target[@"url"] ?: @"", @"title": target[@"title"] ?: @"",
                    @"targetId": target[@"id"] }, nil);
    }];
  });
}

- (NSURL *)browserSocketURL:(NSError **)error {
  const char *profile = getenv("DECHROME_PROFILE_PATH");
  NSString *directory = profile ? @(profile) : nil;
  NSString *contents = directory.isAbsolutePath ? [NSString stringWithContentsOfFile:
      [directory stringByAppendingPathComponent:@"DevToolsActivePort"]
      encoding:NSUTF8StringEncoding error:nil] : nil;
  NSArray<NSString *> *lines = [contents componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
  NSInteger port = lines.count ? lines[0].integerValue : 0;
  NSString *path = lines.count > 1 ? lines[1] : @"";
  if (port < 1 || port > 65535 || ![path hasPrefix:@"/devtools/browser/"] ||
      [path rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) {
    if (error) *error = DCBrowserError(20, @"Chrome's tab service is starting. Try again in a moment.");
    return nil;
  }
  NSURLComponents *components = [NSURLComponents new];
  components.scheme = @"ws"; components.host = @"127.0.0.1";
  components.port = @(port); components.path = path;
  return components.URL;
}

- (void)listTabs:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
  DCOnMain(^{
    NSWindow *owner = self.targetWindow ?: NSApp.mainWindow;
    [self listTabsForWindow:owner completion:completion];
  });
}

- (void)listTabsForWindow:(NSWindow *)owner completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
  NSAssert(NSThread.isMainThread, @"Read AppKit state on the main thread");
    NSError *ownerError = DCBrowserWindowError(owner);
    if (ownerError) { completion(nil, ownerError); return; }
    NSError *error;
    NSURL *socket = [self browserSocketURL:&error];
    if (!socket) { completion(nil, error); return; }
    NSNumber *cachedID = objc_getAssociatedObject(owner, DCTabWindowIDKey);
    DCCDPConnection *connection = [[DCCDPConnection alloc] initWithURL:socket];
    [connection sendMethod:@"Target.getTargets"
                   params:@{@"filter": @[@{@"type":@"tab", @"exclude":@NO}, @{@"exclude":@YES}]}
               completion:^(NSDictionary *result, NSError *targetError) {
      NSError *closedError = DCBrowserWindowError(owner);
      if (closedError) { [connection close]; completion(nil, closedError); return; }
      if (targetError) { [connection close]; completion(nil, targetError); return; }
      NSArray *infos = [result[@"targetInfos"] isKindOfClass:NSArray.class] ? result[@"targetInfos"] : @[];
      NSMutableArray<NSDictionary *> *tabInfos = [NSMutableArray new];
      NSUInteger tabTargetCount = 0;
      NSUInteger auxiliaryCount = 0;
      for (NSDictionary *info in infos) {
        if (![info isKindOfClass:NSDictionary.class] || ![info[@"type"] isEqual:@"tab"]) continue;
        tabTargetCount++;
        if (DCTargetHasTabStripMetadata(info)) [tabInfos addObject:info];
        else auxiliaryCount++;
      }
      if (!tabInfos.count) {
        [connection close];
        DCLogTabTargetCounts(tabTargetCount, auxiliaryCount, 0, 0, 0);
        completion(nil, DCBrowserError(21, tabTargetCount ?
            @"Chrome exposed page targets but no usable tab-strip metadata. Complete any Chrome profile or sign-in setup, then retry. This Chrome build may require single-page mode." :
            @"Chrome has not exposed a browser tab yet. Complete any Chrome profile or sign-in setup, then retry; single-page mode is also available."));
        return;
      }
      __block NSUInteger remaining = tabInfos.count;
      __block NSUInteger missingWindowCount = 0;
      __block NSUInteger failureCount = 0;
      __block NSError *firstError;
      __block BOOL complete = NO;
      NSMutableArray<NSDictionary *> *tabs = [NSMutableArray new];
      for (NSDictionary *info in tabInfos) {
        [connection sendMethod:@"Browser.getWindowForTarget" params:@{@"targetId":info[@"targetId"]}
                    completion:^(NSDictionary *windowInfo, NSError *windowError) {
          if (complete) return;
          NSDictionary *embedder = [info[@"embedderData"] isKindOfClass:NSDictionary.class] ? info[@"embedderData"] : nil;
          NSNumber *windowID = [windowInfo[@"windowId"] isKindOfClass:NSNumber.class] ? windowInfo[@"windowId"] : nil;
          if (DCTargetWindowLookupCanBeSkipped(windowError)) {
            // A tab may be detached or closed between the target snapshot and
            // this lookup. It must not invalidate surviving browser tabs.
            missingWindowCount++;
          } else if (windowError || !windowID || !DCTargetHasTabStripMetadata(info)) {
            failureCount++;
            if (!firstError) firstError = windowError ?: DCBrowserError(22, @"Chrome's tab metadata is unavailable in this build. Use single-page mode as a fallback.");
          } else {
            [tabs addObject:@{@"id":info[@"targetId"], @"title":info[@"title"] ?: @"Untitled",
                             @"url":info[@"url"] ?: @"", @"active":embedder[@"tabActive"],
                             @"index":embedder[@"tabStripIndex"], @"windowId":windowID,
                             @"bounds":windowInfo[@"bounds"] ?: @{}}];
          }
          if (--remaining) return;
          complete = YES;
          [connection close];
          DCLogTabTargetCounts(tabTargetCount, auxiliaryCount, missingWindowCount,
                               tabs.count, failureCount);
          NSError *closedError = DCBrowserWindowError(owner);
          if (closedError) { completion(nil, closedError); return; }
          if (firstError) { completion(nil, firstError); return; }
          if (!tabs.count) {
            completion(nil, DCBrowserError(28,
                @"Chrome's page targets do not belong to an available browser window. Complete any Chrome profile or sign-in setup, or wait for its browser window, then retry. Single-page mode is also available."));
            return;
          }
          NSRect frame = owner.frame;
          CGFloat screenTop = NSMaxY(NSScreen.screens.firstObject.frame);
          NSMutableSet<NSNumber *> *windowIDs = [NSMutableSet new];
          for (NSDictionary *tab in tabs) [windowIDs addObject:tab[@"windowId"]];
          NSNumber *selectedWindow = cachedID && [windowIDs containsObject:cachedID] ? cachedID : nil;
          if (!selectedWindow && windowIDs.count == 1) {
            NSUInteger nativeWindowCount = 0;
            for (NSWindow *window in NSApp.windows)
              if (DCBrowserWindowEligible(window)) nativeWindowCount++;
            if (nativeWindowCount == 1) selectedWindow = windowIDs.anyObject;
          }
          if (!selectedWindow) {
            NSMutableSet<NSNumber *> *candidates = [NSMutableSet new];
            for (NSDictionary *tab in tabs) {
              NSDictionary *bounds = tab[@"bounds"];
              if (fabs([bounds[@"left"] doubleValue] - NSMinX(frame)) <= 3 &&
                  fabs([bounds[@"top"] doubleValue] - (screenTop - NSMaxY(frame))) <= 3 &&
                  fabs([bounds[@"width"] doubleValue] - NSWidth(frame)) <= 3 &&
                  fabs([bounds[@"height"] doubleValue] - NSHeight(frame)) <= 3)
                [candidates addObject:tab[@"windowId"]];
            }
            // Already mapped native windows retain their own tabs even when
            // AeroSpace's accordion layout gives multiple windows equal bounds.
            for (NSWindow *other in NSApp.windows) {
              if (other == owner || !DCBrowserWindowUsable(other)) continue;
              NSNumber *claimed = objc_getAssociatedObject(other, DCTabWindowIDKey);
              if (claimed) [candidates removeObject:claimed];
            }
            if (candidates.count == 1) selectedWindow = candidates.anyObject;
            if (!selectedWindow) {
              NSMutableSet *titles = [NSMutableSet new];
              NSString *nativeTitle = owner.title ?: @"";
              if ([nativeTitle hasSuffix:@" - Google Chrome"])
                nativeTitle = [nativeTitle substringToIndex:nativeTitle.length - @" - Google Chrome".length];
              for (NSDictionary *tab in tabs) {
                if ([candidates containsObject:tab[@"windowId"]] && [tab[@"active"] boolValue] &&
                    [tab[@"title"] isEqual:nativeTitle]) [titles addObject:tab[@"windowId"]];
              }
              if (titles.count == 1) selectedWindow = titles.anyObject;
            }
          }
          if (!selectedWindow) {
            completion(nil, DCBrowserError(23, @"Could not safely match tabs to this window. Focus a distinct Chrome window and try again."));
            return;
          }
          objc_setAssociatedObject(owner, DCTabWindowIDKey, selectedWindow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
          NSMutableArray *scoped = [NSMutableArray new];
          for (NSDictionary *tab in tabs) if ([tab[@"windowId"] isEqual:selectedWindow]) [scoped addObject:tab];
          [scoped sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"index"] compare:b[@"index"]];
          }];
          completion(scoped, nil);
        }];
      }
    }];
}

- (void)activateTab:(NSString *)targetId completion:(void (^)(NSError *))completion {
  DCOnMain(^{
    NSWindow *owner = self.targetWindow ?: NSApp.mainWindow;
    [self activateTab:targetId window:owner completion:completion];
  });
}

- (void)activateTab:(NSString *)targetId window:(NSWindow *)owner completion:(void (^)(NSError *))completion {
  [self listTabsForWindow:owner completion:^(NSArray<NSDictionary *> *tabs, NSError *error) {
    if (error) { completion(error); return; }
    BOOL found = NO;
    for (NSDictionary *tab in tabs) if ([tab[@"id"] isEqual:targetId]) found = YES;
    if (!found) { completion(DCBrowserError(24, @"That tab has closed or belongs to another window.")); return; }
    NSURL *socket = [self browserSocketURL:&error];
    if (!socket) { completion(error); return; }
    DCCDPConnection *connection = [[DCCDPConnection alloc] initWithURL:socket];
    [connection sendMethod:@"Target.activateTarget" params:@{@"targetId":targetId}
                completion:^(__unused NSDictionary *result, NSError *activationError) {
      [connection close];
      completion(DCBrowserWindowError(owner) ?: activationError);
    }];
  }];
}

- (void)focusCurrentPage {
  DCOnMain(^{
    NSWindow *owner = self.targetWindow ?: NSApp.mainWindow;
    if (!owner.visible) return;
    NSView *renderer = nil;
    CGFloat area = 0;
    DCFindFocusView(owner.contentView, &renderer, &area);
    [owner makeKeyAndOrderFront:nil];
    if (renderer) [owner makeFirstResponder:renderer];
  });
}

- (void)resolveTabPageForWindow:(NSWindow *)owner completion:(void (^)(NSDictionary *, NSError *))completion {
  [self resolveTabPageForTabID:nil window:owner completion:completion];
}

- (void)resolveTabPageForTabID:(NSString *)tabID window:(NSWindow *)owner completion:(void (^)(NSDictionary *, NSError *))completion {
  [self listTabsForWindow:owner completion:^(NSArray<NSDictionary *> *tabs, NSError *error) {
    if (error) { completion(nil, error); return; }
    NSDictionary *selectedTab;
    for (NSDictionary *tab in tabs) {
      BOOL selected = tabID.length ? [tab[@"id"] isEqual:tabID] : [tab[@"active"] boolValue];
      if (!selected) continue;
      if (selectedTab) { completion(nil, DCBrowserError(25, @"Chrome reported more than one selected tab in this window.")); return; }
      selectedTab = tab;
    }
    if (!selectedTab) {
      completion(nil, DCBrowserError(tabID.length ? 24 : 26, tabID.length ?
          @"That tab has closed or belongs to another window." : @"There is no active tab in this window."));
      return;
    }
    NSURL *socket = [self browserSocketURL:&error];
    if (!socket) { completion(nil, error); return; }
    DCCDPConnection *connection = [[DCCDPConnection alloc] initWithURL:socket];
    __block NSString *tabSession;
    __block BOOL finished = NO;
    void (^finish)(NSDictionary *, NSError *) = ^(NSDictionary *page, NSError *pageError) {
      if (finished) return;
      finished = YES;
      [connection close];
      NSError *closedError = DCBrowserWindowError(owner);
      completion(closedError ? nil : page, closedError ?: pageError);
    };
    connection.eventHandler = ^(NSDictionary *event) {
      if (![event[@"method"] isEqual:@"Target.attachedToTarget"] || ![event[@"sessionId"] isEqual:tabSession]) return;
      NSDictionary *info = event[@"params"][@"targetInfo"];
      if (![info[@"type"] isEqual:@"page"] || [info[@"subtype"] isEqual:@"prerender"] ||
          ![info[@"targetId"] isKindOfClass:NSString.class]) return;
      NSURLComponents *pageSocket = [NSURLComponents componentsWithURL:socket resolvingAgainstBaseURL:NO];
      pageSocket.path = [@"/devtools/page/" stringByAppendingString:info[@"targetId"]];
      finish(@{@"id":info[@"targetId"], @"title":info[@"title"] ?: selectedTab[@"title"],
               @"url":info[@"url"] ?: selectedTab[@"url"], @"webSocketDebuggerUrl":pageSocket.URL.absoluteString}, nil);
    };
    [connection sendMethod:@"Target.attachToTarget" params:@{@"targetId":selectedTab[@"id"], @"flatten":@YES}
                completion:^(NSDictionary *attached, NSError *attachError) {
      NSError *closedError = DCBrowserWindowError(owner);
      if (closedError) { finish(nil, closedError); return; }
      if (attachError) { finish(nil, attachError); return; }
      tabSession = attached[@"sessionId"];
      [connection sendMethod:@"Target.setAutoAttach"
                     params:@{@"autoAttach":@YES, @"waitForDebuggerOnStart":@NO, @"flatten":@YES,
                              @"filter":@[@{@"type":@"page", @"exclude":@NO}, @{@"exclude":@YES}]}
                  sessionID:tabSession completion:^(__unused NSDictionary *result, NSError *autoError) {
        if (autoError) finish(nil, autoError);
      }];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 7 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      if (!finished) finish(nil, DCBrowserError(27, @"Chrome did not expose this tab's page. Try again."));
    });
  }];
}

- (void)checkCommandInterface:(void (^)(NSError *))completion {
  DCOnMain(^{
    NSWindow *owner = self.targetWindow ?: NSApp.mainWindow;
    [self resolveTargetForWindow:owner completion:^(NSDictionary *target, NSError *error) {
      if (error) { completion(error); return; }
      DCCDPConnection *connection = [[DCCDPConnection alloc]
          initWithURL:[NSURL URLWithString:target[@"webSocketDebuggerUrl"]]];
      [connection sendMethod:@"Page.getNavigationHistory" params:@{}
                  completion:^(__unused NSDictionary *result, NSError *commandError) {
        [connection close];
        completion(DCBrowserWindowError(owner) ?: commandError);
      }];
    }];
  });
}

- (void)navigate:(NSString *)url completion:(void (^)(NSError *))completion {
  DCOnMain(^{
    NSWindow *owner = self.targetWindow ?: NSApp.mainWindow;
    [self navigateURL:url tabID:nil window:owner completion:completion];
  });
}

- (void)navigate:(NSString *)url tabID:(NSString *)tabID completion:(void (^)(NSError *))completion {
  DCOnMain(^{
    NSWindow *owner = self.targetWindow ?: NSApp.mainWindow;
    if (!DCTabMode() || !tabID.length) {
      completion(DCBrowserError(24, @"Choose a browser tab before navigating."));
      return;
    }
    [self navigateURL:url tabID:tabID window:owner completion:completion];
  });
}

- (void)navigateURL:(NSString *)url tabID:(NSString *)tabID window:(NSWindow *)owner completion:(void (^)(NSError *))completion {
  NSAssert(NSThread.isMainThread, @"Read AppKit state on the main thread");
    NSURLComponents *components = [NSURLComponents componentsWithString:url];
    if (![@[@"http", @"https", @"file", @"chrome", @"about"] containsObject:components.scheme.lowercaseString]) {
      completion(DCBrowserError(7, @"Enter an http, https, file, chrome, or about URL."));
      return;
    }
    void (^resolved)(NSDictionary *, NSError *) = ^(NSDictionary *target, NSError *error) {
      if (error) { completion(error); return; }
      DCCDPConnection *connection = [[DCCDPConnection alloc]
          initWithURL:[NSURL URLWithString:target[@"webSocketDebuggerUrl"]]];
      [connection sendMethod:@"Page.navigate" params:@{@"url":url}
                  completion:^(NSDictionary *result, NSError *commandError) {
        [connection close];
        NSString *navigationError = [result[@"errorText"] isKindOfClass:NSString.class] ? result[@"errorText"] : nil;
        completion(DCBrowserWindowError(owner) ?: commandError ?:
            (navigationError.length ? DCBrowserError(8, navigationError) : nil));
      }];
    };
    if (tabID.length) [self resolveTabPageForTabID:tabID window:owner completion:resolved];
    else [self resolveTargetForWindow:owner completion:resolved];
}

static NSMenuItem *DCFindShortcut(NSMenu *menu, NSArray<NSString *> *keys,
                                  NSEventModifierFlags wanted, BOOL allowShift) {
  [menu update];
  NSEventModifierFlags relevant = NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                 NSEventModifierFlagControl | NSEventModifierFlagShift;
  for (NSMenuItem *item in menu.itemArray) {
    NSEventModifierFlags modifiers = item.keyEquivalentModifierMask & relevant;
    if (allowShift) modifiers &= ~NSEventModifierFlagShift;
    if ([keys containsObject:item.keyEquivalent.lowercaseString] && modifiers == wanted &&
        item.action && item.enabled && !item.hidden) return item;
    if (item.submenu) {
      NSMenuItem *found = DCFindShortcut(item.submenu, keys, wanted, allowShift);
      if (found) return found;
    }
  }
  return nil;
}

- (BOOL)performMenuAction:(NSString *)action window:(NSWindow *)owner error:(NSError **)error {
  NSArray<NSString *> *keys;
  NSEventModifierFlags flags = NSEventModifierFlagCommand;
  BOOL allowShift = NO;
  if ([action isEqualToString:@"new-tab"]) keys = @[@"t"];
  else if ([action isEqualToString:@"close-tab"]) keys = @[@"w"];
  else if ([action isEqualToString:@"close-window"]) { keys = @[@"w"]; flags |= NSEventModifierFlagShift; }
  else if ([action isEqualToString:@"zoom-in"]) { keys = @[@"+", @"="]; allowShift = YES; }
  else if ([action isEqualToString:@"zoom-out"]) keys = @[@"-"];
  else if ([action isEqualToString:@"zoom-reset"]) keys = @[@"0"];
  else if ([action isEqualToString:@"find"]) keys = @[@"f"];
  else if ([action isEqualToString:@"devtools"]) { keys = @[@"i"]; flags |= NSEventModifierFlagOption; }
  else if ([action isEqualToString:@"close"]) keys = @[@"w"];
  else return NO;
  NSError *ownerError = DCBrowserWindowError(owner);
  if (ownerError) {
    if (error) *error = ownerError;
    return YES;
  }
  // A different palette may have opened while an earlier request was waiting
  // for Chrome. Never steal its focus or dispatch a menu command in its window.
  if ((self.targetWindow ?: NSApp.mainWindow) != owner) {
    if (error) *error = DCBrowserError(30, @"The active Chrome window changed. Try the command again.");
    return YES;
  }
  if (!owner.isKeyWindow) [owner makeKeyAndOrderFront:nil];
  if ([action isEqualToString:@"close-window"]) {
    // Use this window's native close path. Chrome's delegate retains its normal
    // before-unload checks; menu shortcuts differ between Chrome/macOS builds.
    [owner performClose:nil];
    return YES;
  }
  NSMenuItem *item = DCFindShortcut(NSApp.mainMenu, keys, flags, allowShift);
  if (!item || ![NSApp sendAction:item.action to:item.target from:item]) {
    if (error) *error = DCBrowserError(9, @"That Chrome command is not available in this window.");
  }
  return YES;
}

- (void)performAction:(NSString *)action completion:(void (^)(NSError *))completion {
  DCOnMain(^{
    NSWindow *owner = self.targetWindow ?: NSApp.mainWindow;
    if ([action isEqualToString:@"new-tab"]) {
      // Dispatch Chrome's native command before returning this key event so the
      // palette can take focus immediately. An asynchronous preflight here
      // drops characters typed quickly after CmdT into the hidden omnibox.
      NSError *menuError;
      [self performMenuAction:action window:owner error:&menuError];
      completion(menuError);
      return;
    }
    if (DCTabMode() && [action isEqualToString:@"close-tab"]) {
      // Chrome's AppKit CmdW menu item can dispatch Close Window. Address the
      // active page directly so only its tab closes, preserving before-unload.
      [self resolveTabPageForWindow:owner completion:^(NSDictionary *target, NSError *error) {
        if (error) { completion(error); return; }
        DCCDPConnection *connection = [[DCCDPConnection alloc]
            initWithURL:[NSURL URLWithString:target[@"webSocketDebuggerUrl"]]];
        [connection sendMethod:@"Page.close" params:@{}
                    completion:^(__unused NSDictionary *result, NSError *closeError) {
          [connection close];
          // Closing the last tab intentionally destroys its owner window.
          completion(closeError);
        }];
      }];
      return;
    }
    if ([action isEqualToString:@"next-tab"] || [action isEqualToString:@"previous-tab"]) {
      [self listTabsForWindow:owner completion:^(NSArray<NSDictionary *> *tabs, NSError *error) {
        if (error) { completion(error); return; }
        NSInteger current = -1;
        for (NSUInteger i = 0; i < tabs.count; i++) if ([tabs[i][@"active"] boolValue]) current = (NSInteger)i;
        if (current < 0 || !tabs.count) { completion(DCBrowserError(26, @"There is no active tab in this window.")); return; }
        NSInteger offset = [action isEqualToString:@"next-tab"] ? 1 : -1;
        NSUInteger next = (NSUInteger)((current + offset + (NSInteger)tabs.count) % (NSInteger)tabs.count);
        [self activateTab:tabs[next][@"id"] window:owner completion:completion];
      }];
      return;
    }
    NSError *menuError;
    if ([self performMenuAction:action window:owner error:&menuError]) { completion(menuError); return; }
    if (![@[@"back", @"forward", @"reload", @"hard-reload"] containsObject:action]) {
      completion(DCBrowserError(10, @"Unknown browser command."));
      return;
    }
    [self resolveTargetForWindow:owner completion:^(NSDictionary *target, NSError *error) {
      if (error) { completion(error); return; }
      DCCDPConnection *connection = [[DCCDPConnection alloc]
          initWithURL:[NSURL URLWithString:target[@"webSocketDebuggerUrl"]]];
      DCProtocolReply finish = ^(__unused NSDictionary *result, NSError *commandError) {
        [connection close];
        completion(DCBrowserWindowError(owner) ?: commandError);
      };
      if ([action isEqualToString:@"reload"] || [action isEqualToString:@"hard-reload"]) {
        [connection sendMethod:@"Page.reload" params:@{@"ignoreCache": @([action isEqualToString:@"hard-reload"])} completion:finish];
        return;
      }
      [connection sendMethod:@"Page.getNavigationHistory" params:@{}
                  completion:^(NSDictionary *history, NSError *historyError) {
        NSError *closedError = DCBrowserWindowError(owner);
        if (closedError) { finish(nil, closedError); return; }
        if (historyError) { finish(nil, historyError); return; }
        NSArray *entries = [history[@"entries"] isKindOfClass:NSArray.class] ? history[@"entries"] : @[];
        NSInteger index = [history[@"currentIndex"] integerValue] + ([action isEqualToString:@"back"] ? -1 : 1);
        if (index < 0 || index >= (NSInteger)entries.count) {
          finish(nil, DCBrowserError(15, [action isEqualToString:@"back"] ?
              @"There is no previous page in this window." : @"There is no next page in this window."));
          return;
        }
        id entry = entries[(NSUInteger)index];
        NSNumber *entryID = [entry isKindOfClass:NSDictionary.class] && [entry[@"id"] isKindOfClass:NSNumber.class] ? entry[@"id"] : nil;
        if (!entryID) { finish(nil, DCBrowserError(16, @"Chrome returned invalid navigation history.")); return; }
        [connection sendMethod:@"Page.navigateToHistoryEntry" params:@{@"entryId":entryID} completion:finish];
      }];
    }];
  });
}
@end
