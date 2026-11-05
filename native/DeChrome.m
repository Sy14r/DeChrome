// Experimental Chrome-only AppKit shim. No changes to Chromium's on-disk code.
// Build: clang -dynamiclib -fobjc-arc -framework Cocoa -framework QuartzCore \
//        native/DeChrome.m -o build/libDeChrome.dylib
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "DCPalette.h"
#import "DCBrowser.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static const void *DCStateKey = &DCStateKey;
static const void *DCDiagnosticKey = &DCDiagnosticKey;
static BOOL DCInspectOnly;
static BOOL DCVerbose;
static BOOL DCSelfTestResize;
static BOOL DCExperimentalCrop;
static BOOL DCTabMode;
static BOOL DCPaletteReady;
static BOOL DCHealthWritten;
static BOOL DCHealthPending;
static CFTimeInterval DCHealthNextAttempt;
static CGFloat DCForcedInset = -1;
static FILE *DCLogFile;
static FILE *DCDumpFile;
static NSRect (*DCOriginalContentRect)(id, SEL, NSRect);
static NSRect (*DCOriginalFrameRect)(id, SEL, NSRect);

@interface DCWindowState : NSObject
@property CGFloat inset;
@property BOOL configured;
@property BOOL loggedTree;
@property BOOL adjusting;
@property NSUInteger scans;
@property CFTimeInterval layoutChangedAt;
@property BOOL selfTestStarted;
@property BOOL hasMeasurement;
@property BOOL closing;
@end
@implementation DCWindowState
@end

static void DCFindRenderer(NSView *view, NSView *root, NSView **best,
                           CGFloat *bestArea);

static void DCLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void DCLog(NSString *format, ...) {
  va_list args;
  va_start(args, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  if (!DCLogFile) return;
  fprintf(DCLogFile, "[DeChrome pid=%d] %s\n", getpid(), message.UTF8String);
  fflush(DCLogFile);
}

static BOOL DCIsPotentialBrowserWindow(NSWindow *window) {
  if (!window || [window isKindOfClass:NSPanel.class] || window.parentWindow ||
      window.sheetParent || window.level != NSNormalWindowLevel) return NO;
  if (!(window.styleMask & NSWindowStyleMaskTitled) ||
      !(window.styleMask & NSWindowStyleMaskResizable)) return NO;
  // Raw --app URLs use NativeWidgetMacNSWindow, while installed web apps and
  // ordinary Chrome windows use BrowserNativeWidgetWindow.
  for (Class cls = window.class; cls; cls = class_getSuperclass(cls)) {
    NSString *name = NSStringFromClass(cls);
    if ([name isEqualToString:@"BrowserNativeWidgetWindow"] ||
        [name isEqualToString:@"NativeWidgetMacNSWindow"])
      return YES;
  }
  return NO;
}

static BOOL DCIsBrowserWindow(NSWindow *window) {
  if (!DCIsPotentialBrowserWindow(window) || !window.contentView) return NO;
  // A tab switch can briefly detach its renderer. Keep maintaining a window
  // already selected by the shim while Chrome attaches the next tab's view.
  DCWindowState *existing = objc_getAssociatedObject(window, DCStateKey);
  if (existing) return !existing.closing;
  // Require a large live renderer before selecting a window, excluding
  // Chromium UI dialogs, menus, and popovers that share native classes.
  NSView *renderer = nil;
  CGFloat area = 0;
  NSView *root = window.contentView;
  DCFindRenderer(root, root, &renderer, &area);
  return renderer && area > root.bounds.size.width * root.bounds.size.height * 0.35;
}

static DCWindowState *DCState(NSWindow *window) {
  return objc_getAssociatedObject(window, DCStateKey);
}

// Chrome ignores a direct contentView frame resize: its BridgedContentView
// recomputes the size from this method. Report an oversized content rect so the
// compositor lays out the browser header above the real window's clipped top.
// The NSWindow frame itself remains real and unchanged for AX/AeroSpace.
static NSRect DCContentRect(id self, SEL selector, NSRect frame) {
  NSRect result = DCOriginalContentRect(self, selector, frame);
  DCWindowState *state = DCState(self);
  if (state && !DCInspectOnly && state.inset > 0 &&
      !([(NSWindow *)self styleMask] & NSWindowStyleMaskFullScreen)) {
    result.size.height += state.inset;
  }
  return result;
}

static NSRect DCFrameRect(id self, SEL selector, NSRect content) {
  DCWindowState *state = DCState(self);
  if (state && !DCInspectOnly && state.inset > 0 &&
      !([(NSWindow *)self styleMask] & NSWindowStyleMaskFullScreen)) {
    content.size.height = MAX(1, content.size.height - state.inset);
  }
  return DCOriginalFrameRect(self, selector, content);
}

static void DCDumpView(NSView *view, NSUInteger depth) {
  if (!view || depth > 14) return;
  NSString *line = [NSString stringWithFormat:@"%@%@ frame=%@ bounds=%@ hidden=%d flipped=%d layer=%@",
        [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0],
        NSStringFromClass(view.class), NSStringFromRect(view.frame),
        NSStringFromRect(view.bounds), view.hidden, view.flipped,
        view.layer ? NSStringFromClass(view.layer.class) : @"none"];
  DCLog(@"%@", line);
  if (DCDumpFile) {
    fprintf(DCDumpFile, "%s\n", line.UTF8String);
    fflush(DCDumpFile);
  }
  for (NSView *child in view.subviews) DCDumpView(child, depth + 1);
}

static void DCFindRenderer(NSView *view, NSView *root, NSView **best,
                           CGFloat *bestArea) {
  if (view.hidden || view.alphaValue == 0) return;
  NSString *className = NSStringFromClass(view.class);
  if ([className containsString:@"RenderWidgetHostViewCocoa"] ||
      [className containsString:@"RenderWidgetHostNSView"]) {
    NSRect rect = [view convertRect:view.bounds toView:root];
    CGFloat area = rect.size.width * rect.size.height;
    if (area > *bestArea && rect.size.width > root.bounds.size.width * 0.6) {
      *best = view;
      *bestArea = area;
    }
  }
  for (NSView *child in view.subviews) DCFindRenderer(child, root, best, bestArea);
}

static CGFloat DCMeasureHeader(NSView *root) {
  NSView *renderer = nil;
  CGFloat area = 0;
  DCFindRenderer(root, root, &renderer, &area);
  if (!renderer || area < root.bounds.size.width * root.bounds.size.height * 0.35)
    return -1;
  NSRect rect = [renderer convertRect:renderer.bounds toView:root];
  CGFloat header = root.flipped ? NSMinY(rect) - NSMinY(root.bounds) :
                                NSMaxY(root.bounds) - NSMaxY(rect);
  // Measure in the oversized root's own coordinates. This is the Chrome
  // header's actual height, not the difference from the physical NSWindow;
  // measuring against the latter would add the inset again on every scan.
  // Refuse a partial page/popup/devtools measurement. A forced inset remains
  // available for builds whose view tree changes.
  if (!isfinite(header) || header < 0 || header > 160) return -1;
  return round(header);
}

static void DCLogWindowState(NSWindow *window, NSString *tag) {
  NSView *content = window.contentView;
  NSView *renderer = nil;
  CGFloat area = 0;
  DCFindRenderer(content, content, &renderer, &area);
  NSRect rendererRect = renderer ? [renderer convertRect:renderer.bounds toView:content] : NSZeroRect;
  DCLog(@"%@ window=%ld role=%@ subrole=%@ key=%d canBecomeKey=%d frame=%@ content=%@ renderer=%@ headerInset=%.1f tabMode=%d firstResponder=%@",
        tag, (long)window.windowNumber, window.accessibilityRole,
        window.accessibilitySubrole, window.keyWindow, window.canBecomeKeyWindow,
        NSStringFromRect(window.frame), NSStringFromRect(content.frame),
        NSStringFromRect(rendererRect), DCState(window).inset, DCTabMode,
        window.firstResponder ? NSStringFromClass(window.firstResponder.class) : @"nil");
}

static NSRect DCVisibleContentRect(NSView *content) {
  if (!content.superview) return content.bounds;
  // In tab mode, the root extends above the NSWindow by Chrome's header
  // height. Only the root portion inside its real frame view is visible.
  NSRect frameBounds = [content.superview convertRect:content.superview.bounds toView:content];
  return NSIntersectionRect(content.bounds, frameBounds);
}

// The launcher checks a nonce-bound report before declaring a new Chrome/macOS
// combination ready. No page title, URL, or browsing data goes into this file.
static void DCWriteHealth(NSWindow *window) {
  if (DCHealthWritten || DCHealthPending || !DCPaletteReady ||
      CACurrentMediaTime() < DCHealthNextAttempt) return;
  const char *path = getenv("DECHROME_HEALTH_PATH");
  const char *launchID = getenv("DECHROME_LAUNCH_ID");
  if (!path || !*path || !launchID || !*launchID) return;
  DCWindowState *state = DCState(window);
  NSView *content = window.contentView;
  NSView *renderer = nil;
  CGFloat area = 0;
  DCFindRenderer(content, content, &renderer, &area);
  if (!state.configured || !renderer || !window.canBecomeKeyWindow) return;
  NSRect rendererRect = [renderer convertRect:renderer.bounds toView:content];
  NSRect visibleContent = DCVisibleContentRect(content);
  NSSize frameSize = window.frame.size;
  NSSize contentSize = DCTabMode ? visibleContent.size : content.frame.size;
  BOOL fillsWindow = fabs(frameSize.width - contentSize.width) < 1 &&
                     fabs(frameSize.height - contentSize.height) < 1 &&
                     fabs(frameSize.width - rendererRect.size.width) < 1 &&
                     fabs(frameSize.height - rendererRect.size.height) < 1;
  if (DCTabMode) {
    // Matching sizes alone could conceal clipping at one end of the page.
    // Require the complete renderer to line up with the visible viewport.
    fillsWindow = fillsWindow && fabs(NSMinX(rendererRect) - NSMinX(visibleContent)) < 1 &&
                  fabs(NSMinY(rendererRect) - NSMinY(visibleContent)) < 1;
  }
  if (!fillsWindow || ![window.accessibilityRole isEqualToString:NSAccessibilityWindowRole] ||
      ![window.accessibilitySubrole isEqualToString:NSAccessibilityStandardWindowSubrole]) return;
  NSMutableDictionary *report = [@{
    @"schema": @1, @"launchID": @(launchID), @"pid": @(getpid()),
    @"configured": @YES, @"paletteInstalled": @YES, @"commandInterfaceReady": @NO,
    @"windowNumber": @(window.windowNumber),
    @"role": window.accessibilityRole, @"subrole": window.accessibilitySubrole,
    @"frame": @{@"width": @(frameSize.width), @"height": @(frameSize.height)},
    @"content": @{@"width": @(contentSize.width), @"height": @(contentSize.height)},
    @"renderer": @{@"width": @(rendererRect.size.width), @"height": @(rendererRect.size.height)},
    @"contentRoot": @{@"width": @(content.frame.size.width), @"height": @(content.frame.size.height)},
    @"contentViewport": @(DCTabMode), @"tabMode": @(DCTabMode),
    @"chromeHeaderInset": @(state.inset)
  } mutableCopy];
  NSString *healthPath = @(path);
  DCHealthPending = YES;
  [DCBrowser sharedBrowser].targetWindow = window;
  [[DCBrowser sharedBrowser] checkCommandInterface:^(NSError *error) {
    DCHealthPending = NO;
    DCHealthNextAttempt = CACurrentMediaTime() + 1;
    if (error) {
      DCLog(@"startup command interface not ready: %@", error.localizedDescription);
      report[@"commandError"] = error.localizedDescription;
    } else {
      report[@"commandInterfaceReady"] = @YES;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    if (data && [data writeToFile:healthPath options:NSDataWritingAtomic error:nil]) {
      if (!error) {
        DCHealthWritten = YES;
        DCLog(@"startup health verified window=%ld", (long)window.windowNumber);
      }
    }
  }];
}

static void DCHideControls(NSWindow *window) {
  for (NSNumber *buttonType in @[@(NSWindowCloseButton),
                                 @(NSWindowMiniaturizeButton),
                                 @(NSWindowZoomButton),
                                 @(NSWindowToolbarButton)]) {
    NSButton *button = [window standardWindowButton:buttonType.unsignedIntegerValue];
    if (button && !button.hidden) button.hidden = YES;
  }
  if (window.titleVisibility != NSWindowTitleHidden)
    window.titleVisibility = NSWindowTitleHidden;
  if (!window.titlebarAppearsTransparent) window.titlebarAppearsTransparent = YES;
  if (window.titlebarSeparatorStyle != NSTitlebarSeparatorStyleNone)
    window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
  if (window.hasShadow) window.hasShadow = NO;
  // AppKit 26's native titlebar and glass backdrop sit above full-size content.
  // Hide those siblings as well as their buttons, so page pixels receive input
  // in the reclaimed area. Do not walk or alter web content's own view tree.
  NSView *content = window.contentView;
  for (NSView *sibling in content.superview.subviews) {
    if (sibling == content) continue;
    NSString *name = NSStringFromClass(sibling.class);
    if ([name containsString:@"Titlebar"] ||
        ([name containsString:@"BackdropView"] &&
         NSMinY(sibling.frame) >= NSHeight(content.superview.bounds) - 80)) {
      if (!sibling.hidden) sibling.hidden = YES;
    }
  }
}

static void DCApplyWindow(NSWindow *window) {
  if (!DCIsBrowserWindow(window) || !window.contentView || !window.visible) return;
  DCWindowState *state = DCState(window);
  if (!state) {
    state = [DCWindowState new];
    objc_setAssociatedObject(window, DCStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    DCLog(@"selected window=%ld class=%@ frame=%@ mask=0x%lx content=%@",
          (long)window.windowNumber, NSStringFromClass(window.class),
          NSStringFromRect(window.frame), (unsigned long)window.styleMask,
          NSStringFromClass(window.contentView.class));
  }
  if (state.adjusting) return;
  state.scans++;
  NSView *content = window.contentView;
  if ((DCVerbose && !state.loggedTree && state.scans > 8) ||
      (DCInspectOnly && state.scans == 10)) {
    DCLog(@"view-tree window=%ld", (long)window.windowNumber);
    DCDumpView(content.superview ?: content, 0);
    state.loggedTree = YES;
  }
  if (DCInspectOnly || (window.styleMask & NSWindowStyleMaskFullScreen)) return;
  state.adjusting = YES;
  @try {
    if (!state.configured) {
      // Retaining Titled preserves key-window behavior and AXStandardWindow.
      // FullSizeContentView permits drawing below the native titlebar.
      NSRect physicalFrame = window.frame;
      window.styleMask |= NSWindowStyleMaskFullSizeContentView;
      // AppKit preserves the previous content size while changing style masks,
      // which can shrink the outer frame by the old native titlebar height.
      // AeroSpace owns the real frame: restore it before laying out the page.
      [window setFrame:physicalFrame display:NO];
      state.configured = YES;
      state.layoutChangedAt = CACurrentMediaTime();
      NSRect contentRect = [window contentRectForFrameRect:physicalFrame];
      [content setFrame:NSMakeRect(0, 0, contentRect.size.width, contentRect.size.height)];
      [window setFrame:physicalFrame display:YES];
      DCLog(@"window=%ld configured full-size content=%@ frame=%@",
            (long)window.windowNumber, NSStringFromRect(content.frame), NSStringFromRect(window.frame));
    }
    DCHideControls(window);
    // Give Chromium's renderer a moment to accept the initial native titlebar
    // expansion; otherwise its old viewport looks like a custom browser header.
    // Raw --app windows only need the native titlebar removed. Inferring a
    // compositor header can mistake docked DevTools or another panel for one,
    // so cropping must be explicitly requested for other Chrome window types.
    // Opt-in tab mode is a normal Chrome browser window: its compositor still
    // lays out a tab strip and toolbar, which are placed above the real window.
    CGFloat measured = DCForcedInset >= 0 ? DCForcedInset :
        (!DCExperimentalCrop ? 0 :
         (CACurrentMediaTime() - state.layoutChangedAt >= 0.5 ? DCMeasureHeader(content) : -1));
    if (measured >= 0) state.hasMeasurement = YES;
    if (measured >= 0 && fabs(measured - state.inset) > 0.5) {
      DCLog(@"window=%ld header inset %.1f -> %.1f points",
            (long)window.windowNumber, state.inset, measured);
      state.inset = measured;
      state.layoutChangedAt = CACurrentMediaTime();
      // Ask AppKit to lay out using the interposed content rectangle. Calling
      // BridgedContentView setFrameSize also notifies Chromium's renderer host.
      NSRect contentRect = [window contentRectForFrameRect:window.frame];
      [content setFrame:NSMakeRect(0, 0, contentRect.size.width, contentRect.size.height)];
      [window setFrame:window.frame display:YES];
      [content setNeedsDisplay:YES];
    }
    if (state.scans == 30 && DCExperimentalCrop && !state.hasMeasurement && DCForcedInset < 0) {
      DCLog(@"window=%ld no header measurement yet; use DECHROME_DEBUG=1 for tree or DECHROME_TOP_INSET=<points>",
            (long)window.windowNumber);
      if (!state.loggedTree) DCDumpView(content.superview ?: content, 0);
      state.loggedTree = YES;
    }
    if (state.scans == 12) DCLogWindowState(window, @"settled");
    if (state.scans >= 3) DCWriteHealth(window);
    if (DCSelfTestResize && !state.selfTestStarted && state.scans >= 20) {
      state.selfTestStarted = YES;
      NSRect originalFrame = window.frame;
      NSRect smaller = originalFrame;
      smaller.size.width = MAX(400, smaller.size.width - 120);
      smaller.size.height = MAX(300, smaller.size.height - 80);
      smaller.origin.y += originalFrame.size.height - smaller.size.height;
      DCLogWindowState(window, @"selftest-before");
      [window setFrame:smaller display:YES];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
        DCLogWindowState(window, @"selftest-resized");
        [window setFrame:originalFrame display:YES];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
          DCLogWindowState(window, @"selftest-restored");
        });
      });
    }
  } @catch (NSException *exception) {
    DCLog(@"window=%ld exception %@: %@", (long)window.windowNumber,
          exception.name, exception.reason);
  }
  state.adjusting = NO;
}

static void DCScanWindows(void) {
  static NSUInteger scans;
  scans++;
  NSArray<NSWindow *> *windows = NSApp.windows;
  if (DCVerbose && (scans <= 5 || scans % 20 == 0)) {
    DCLog(@"scan=%lu NSApp=%@ windowCount=%lu", (unsigned long)scans,
          NSApp ? NSStringFromClass(NSApp.class) : @"nil", (unsigned long)windows.count);
  }
  for (NSWindow *window in windows) {
    if (DCVerbose && !objc_getAssociatedObject(window, DCDiagnosticKey)) {
      NSMutableArray<NSString *> *classes = [NSMutableArray new];
      for (Class cls = window.class; cls; cls = class_getSuperclass(cls))
        [classes addObject:NSStringFromClass(cls)];
      DCLog(@"candidate window=%ld classes=%@ visible=%d level=%ld parent=%@ sheetParent=%@ frame=%@ mask=0x%lx content=%@",
            (long)window.windowNumber, [classes componentsJoinedByString:@" -> "],
            window.visible, (long)window.level,
            window.parentWindow ? NSStringFromClass(window.parentWindow.class) : @"nil",
            window.sheetParent ? NSStringFromClass(window.sheetParent.class) : @"nil",
            NSStringFromRect(window.frame), (unsigned long)window.styleMask,
            window.contentView ? NSStringFromClass(window.contentView.class) : @"nil");
      DCDumpView(window.contentView.superview ?: window.contentView, 0);
      objc_setAssociatedObject(window, DCDiagnosticKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    DCApplyWindow(window);
  }
}

static void DCBrowserWindowWillClose(NSNotification *notification) {
  if (!DCTabMode || ![notification.object isKindOfClass:NSWindow.class]) return;
  NSWindow *closingWindow = notification.object;
  DCWindowState *state = DCState(closingWindow);
  if (!state.configured || state.closing) return;
  // WillClose is delivered after Chrome has approved closing its window,
  // including any page beforeunload handling. Do not replace that approval.
  state.closing = YES;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    for (NSWindow *candidate in NSApp.windows) {
      if (candidate == closingWindow) continue;
      DCWindowState *otherState = DCState(candidate);
      if (otherState.closing) continue;
      // Minimized or application-hidden browser windows still hold tabs.
      // A closing flag also excludes closed objects retained by AppKit.
      if (otherState.configured) return;
      // A newly opened visible Chrome window may not have its renderer yet.
      // Keep it alive while startup attaches and configures that renderer.
      if (candidate.visible && DCIsPotentialBrowserWindow(candidate)) return;
    }
    DCLog(@"last browser window closed; requesting normal application termination");
    [NSApp terminate:nil];
  });
}

static void DCInstall(void) {
  Method contentMethod = class_getInstanceMethod(NSWindow.class,
                                                 @selector(contentRectForFrameRect:));
  Method frameMethod = class_getInstanceMethod(NSWindow.class,
                                               @selector(frameRectForContentRect:));
  DCOriginalContentRect = (void *)method_setImplementation(contentMethod, (IMP)DCContentRect);
  DCOriginalFrameRect = (void *)method_setImplementation(frameMethod, (IMP)DCFrameRect);
  NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
  [center addObserverForName:NSWindowWillCloseNotification object:nil
                      queue:NSOperationQueue.mainQueue
                 usingBlock:^(NSNotification *notification) { DCBrowserWindowWillClose(notification); }];
  for (NSString *name in @[NSWindowDidBecomeKeyNotification,
                           NSWindowDidResizeNotification,
                           NSWindowDidEndLiveResizeNotification,
                           NSApplicationDidFinishLaunchingNotification]) {
    [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                   usingBlock:^(__unused NSNotification *note) { DCScanWindows(); }];
  }
  // Chromium classes and renderer views load after this dylib's constructor.
  // A gentle poll also catches titlebar controls recreated by AppKit on resize.
  NSTimer *timer = [NSTimer timerWithTimeInterval:0.25 repeats:YES
                                         block:^(__unused NSTimer *unused) { DCScanWindows(); }];
  [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
  DCLog(@"installed inspectOnly=%d experimentalCrop=%d tabMode=%d forcedInset=%.1f",
        DCInspectOnly, DCExperimentalCrop, DCTabMode, DCForcedInset);
  if (!DCInspectOnly) {
    DCPaletteInstall();
    DCPaletteReady = YES;
  }
  DCScanWindows();
}

__attribute__((constructor)) static void DCStart(void) {
  // Do this before NSProcessInfo/AppKit initialization: Chrome's signed helper
  // processes must never inherit injection, even when this shim opts out.
  unsetenv("DYLD_INSERT_LIBRARIES");
  const char *enabled = getenv("DECHROME_ENABLED");
  if (!enabled || strcmp(enabled, "1") != 0) return;
  @autoreleasepool {
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    BOOL appMode = NO;
    DCTabMode = getenv("DECHROME_TAB_MODE") && strcmp(getenv("DECHROME_TAB_MODE"), "1") == 0;
    for (NSString *argument in arguments) {
      if ([argument hasPrefix:@"--type="] || [argument isEqualToString:@"--type"]) return;
      if ([argument hasPrefix:@"--app="]) appMode = YES;
    }
    if (!appMode && !DCTabMode) return;
    const char *logPath = getenv("DECHROME_LOG_PATH");
    DCLogFile = fopen(logPath ?: "/tmp/dechrome-shim.log", "a");
    const char *dumpPath = getenv("DECHROME_DUMP_PATH");
    if (dumpPath && *dumpPath) DCDumpFile = fopen(dumpPath, "a");
    DCVerbose = getenv("DECHROME_DEBUG") && strcmp(getenv("DECHROME_DEBUG"), "0") != 0;
    if (getenv("DECHROME_DIAGNOSTICS") && strcmp(getenv("DECHROME_DIAGNOSTICS"), "0") != 0)
      DCVerbose = YES;
    DCSelfTestResize = getenv("DECHROME_SELFTEST_RESIZE") &&
                      strcmp(getenv("DECHROME_SELFTEST_RESIZE"), "1") == 0;
    DCExperimentalCrop = DCTabMode || (getenv("DECHROME_EXPERIMENTAL_CROP") &&
                         strcmp(getenv("DECHROME_EXPERIMENTAL_CROP"), "1") == 0);
    DCInspectOnly = getenv("DECHROME_INSPECT_ONLY") && strcmp(getenv("DECHROME_INSPECT_ONLY"), "0") != 0;
    const char *inset = getenv("DECHROME_TOP_INSET");
    if (inset && *inset) {
      char *end;
      double value = strtod(inset, &end);
      if (*end == '\0' && isfinite(value) && value >= 0 && value <= 200)
        DCForcedInset = value;
    }
    DCLog(@"loaded executable=%@ appMode=%d tabMode=%d", NSProcessInfo.processInfo.arguments.firstObject,
          appMode, DCTabMode);
    dispatch_async(dispatch_get_main_queue(), ^{ DCInstall(); });
  }
}
