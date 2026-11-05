#import "DCPalette.h"
#import <objc/runtime.h>
#import "DCBrowser.h"

@interface DCPalettePanel : NSPanel
@end
@implementation DCPalettePanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface DCPaletteRow : NSTableRowView
@end
@implementation DCPaletteRow
- (void)drawSelectionInRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  [[NSColor colorWithRed:0.24 green:0.47 blue:0.70 alpha:0.32] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 4, 2)
                                  xRadius:7 yRadius:7] fill];
}
@end

@interface DCPaletteController : NSObject <NSTableViewDataSource, NSTableViewDelegate,
                                           NSSearchFieldDelegate, NSWindowDelegate>
@property (nonatomic, strong) DCPalettePanel *panel;
@property (nonatomic, strong) NSSearchField *search;
@property (nonatomic, strong) NSTableView *table;
@property (nonatomic, strong) NSScrollView *scroll;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *footer;
@property (nonatomic, strong) NSBox *separator;
@property (nonatomic, strong) NSArray<NSDictionary *> *commands;
@property (nonatomic, strong) NSArray<NSDictionary *> *results;
@property (nonatomic, strong) NSArray<NSDictionary *> *tabs;
@property (nonatomic) BOOL tabMode;
@property (nonatomic) BOOL tabsOnly;
@property (nonatomic, weak) NSWindow *owner;
@property (nonatomic, weak) NSResponder *previousResponder;
@property (nonatomic, copy) NSString *currentURL;
@property (nonatomic) BOOL dismissing;
@property (nonatomic) BOOL busy;
@property (nonatomic) BOOL focusPageOnDismiss;
@property (nonatomic) NSUInteger requestGeneration;
- (void)togglePrefillingURL:(BOOL)prefill;
- (void)dismissRestoringFocus:(BOOL)restore;
- (void)runTabAction:(NSString *)action showLocationAfterward:(BOOL)showLocation;
- (void)activateTabAtShortcutIndex:(NSUInteger)index;
- (NSWindow *)browserWindowForShortcut;
@end

static BOOL DCPaletteIsBrowserWindow(NSWindow *window) {
  if (!window || [window isKindOfClass:NSPanel.class] || window.parentWindow ||
      window.level != NSNormalWindowLevel) return NO;
  for (Class cls = window.class; cls; cls = class_getSuperclass(cls)) {
    NSString *name = NSStringFromClass(cls);
    if ([name isEqualToString:@"NativeWidgetMacNSWindow"] ||
        [name isEqualToString:@"BrowserNativeWidgetWindow"]) return YES;
  }
  return NO;
}

static NSDictionary *DCCommand(NSString *action, NSString *title, NSString *detail,
                                NSString *symbol, NSString *shortcut, NSString *keywords) {
  return @{@"action": action, @"title": title, @"detail": detail,
           @"symbol": symbol, @"shortcut": shortcut, @"keywords": keywords};
}

static BOOL DCActionChangesPage(NSString *action) {
  return [@[@"new-tab", @"close-tab", @"next-tab", @"previous-tab",
             @"back", @"forward", @"reload", @"hard-reload"] containsObject:action];
}

static void DCPaletteOnMain(dispatch_block_t block) {
  if (NSThread.isMainThread) block();
  else dispatch_async(dispatch_get_main_queue(), block);
}

@implementation DCPaletteController

- (instancetype)init {
  if (!(self = [super init])) return nil;
  _tabMode = getenv("DECHROME_TAB_MODE") && strcmp(getenv("DECHROME_TAB_MODE"), "1") == 0;
  _tabs = @[];
  _commands = @[
    DCCommand(@"back", @"Go back", @"Previous page in this window", @"arrow.left", @"⌘[", @"back previous history"),
    DCCommand(@"forward", @"Go forward", @"Next page in this window", @"arrow.right", @"⌘]", @"forward next history"),
    DCCommand(@"reload", @"Reload page", @"Refresh the current page", @"arrow.clockwise", @"⌘R", @"reload refresh page"),
    DCCommand(@"hard-reload", @"Reload ignoring cache", @"Fetch the page again without cached resources", @"arrow.trianglehead.2.clockwise.rotate.90", @"⇧⌘R", @"hard reload cache refresh"),
    DCCommand(@"zoom-in", @"Zoom in", @"Make page content larger", @"plus.magnifyingglass", @"⌘+", @"zoom in larger increase"),
    DCCommand(@"zoom-out", @"Zoom out", @"Make page content smaller", @"minus.magnifyingglass", @"⌘−", @"zoom out smaller decrease"),
    DCCommand(@"zoom-reset", @"Reset zoom", @"Return page zoom to 100%", @"1.magnifyingglass", @"⌘0", @"reset zoom actual size 100"),
    DCCommand(@"find", @"Find in page", @"Search for text on the current page", @"text.magnifyingglass", @"⌘F", @"find page text search"),
    DCCommand(@"copy-url", @"Copy page URL", @"Copy the current page address", @"link", @"", @"copy url address link clipboard"),
    DCCommand(@"devtools", @"Toggle Developer Tools", @"Inspect and debug the current page", @"curlybraces", @"⌥⌘I", @"developer devtools inspect console tools"),
    DCCommand(@"manage-profiles", @"Profiles and sync", @"Import or update a copy of a Chrome profile", @"person.crop.circle", @"", @"profiles work extensions import sync update copy settings"),
    DCCommand(@"close", @"Close window", @"Close this Chrome window", @"xmark", @"⌘W", @"close window quit")
  ];
  if (_tabMode) {
    NSMutableArray *commands = [_commands mutableCopy];
    [commands removeLastObject];
    NSIndexSet *positions = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 4)];
    [commands insertObjects:@[
      DCCommand(@"new-tab", @"New tab", @"Open another page in this window", @"plus", @"⌘T", @"new tab page create"),
      DCCommand(@"show-tabs", @"Switch tab", @"Find an open tab by title or address", @"rectangle.on.rectangle", @"", @"switch tabs list open pages"),
      DCCommand(@"next-tab", @"Next tab", @"Switch to the next tab", @"arrow.right.to.line", @"⌃⇥", @"next tab switch"),
      DCCommand(@"previous-tab", @"Previous tab", @"Switch to the previous tab", @"arrow.left.to.line", @"⌃⇧⇥", @"previous tab switch")
    ] atIndexes:positions];
    [commands addObject:DCCommand(@"close-tab", @"Close tab", @"Close the current tab", @"xmark", @"⌘W", @"close current tab page")];
    [commands addObject:DCCommand(@"close-window", @"Close window", @"Close every tab in this window", @"xmark.rectangle", @"⇧⌘W", @"close window all tabs quit")];
    _commands = commands;
  }
  _currentURL = @"";
  [self buildPanel];
  [self rebuildResults];
  return self;
}

- (void)buildPanel {
  self.panel = [[DCPalettePanel alloc] initWithContentRect:NSMakeRect(0, 0, 640, 474)
                                               styleMask:NSWindowStyleMaskBorderless
                                                 backing:NSBackingStoreBuffered defer:NO];
  self.panel.delegate = self;
  self.panel.releasedWhenClosed = NO;
  self.panel.floatingPanel = YES;
  self.panel.hidesOnDeactivate = YES;
  self.panel.level = NSFloatingWindowLevel;
  self.panel.opaque = NO;
  self.panel.backgroundColor = NSColor.clearColor;
  self.panel.hasShadow = YES;
  self.panel.title = @"DeChrome command palette";
  self.panel.accessibilityLabel = @"DeChrome command palette";
  self.panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
  NSVisualEffectView *background = [[NSVisualEffectView alloc] initWithFrame:self.panel.contentView.bounds];
  background.material = NSVisualEffectMaterialHUDWindow;
  background.blendingMode = NSVisualEffectBlendingModeWithinWindow;
  background.state = NSVisualEffectStateActive;
  background.wantsLayer = YES;
  background.layer.cornerRadius = 12;
  background.layer.masksToBounds = YES;
  self.panel.contentView = background;
  self.titleLabel = [NSTextField labelWithString:@"Go to a page or run a command"];
  self.titleLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
  self.titleLabel.textColor = NSColor.secondaryLabelColor;
  [background addSubview:self.titleLabel];
  self.search = [[NSSearchField alloc] initWithFrame:NSZeroRect];
  self.search.delegate = self;
  self.search.font = [NSFont systemFontOfSize:18];
  self.search.placeholderString = @"Search commands, enter a URL, or search the web";
  self.search.accessibilityLabel = @"Command palette search";
  self.search.sendsSearchStringImmediately = YES;
  self.search.sendsWholeSearchString = NO;
  self.search.focusRingType = NSFocusRingTypeNone;
  [background addSubview:self.search];
  self.separator = [[NSBox alloc] initWithFrame:NSZeroRect];
  self.separator.boxType = NSBoxSeparator;
  [background addSubview:self.separator];
  self.table = [[NSTableView alloc] initWithFrame:NSZeroRect];
  NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"command"];
  column.resizingMask = NSTableColumnAutoresizingMask;
  [self.table addTableColumn:column];
  self.table.headerView = nil;
  self.table.dataSource = self;
  self.table.delegate = self;
  self.table.rowHeight = 56;
  self.table.intercellSpacing = NSMakeSize(0, 0);
  self.table.backgroundColor = NSColor.clearColor;
  self.table.focusRingType = NSFocusRingTypeNone;
  self.table.allowsEmptySelection = NO;
  self.table.target = self;
  self.table.action = @selector(tableClicked:);
  self.table.accessibilityLabel = @"Command results";
  self.scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  self.scroll.documentView = self.table;
  self.scroll.hasVerticalScroller = YES;
  self.scroll.autohidesScrollers = YES;
  self.scroll.drawsBackground = NO;
  [background addSubview:self.scroll];
  self.footer = [NSTextField labelWithString:@"↑ ↓ to choose     ↵ to run     esc to dismiss"];
  self.footer.font = [NSFont systemFontOfSize:11];
  self.footer.textColor = NSColor.tertiaryLabelColor;
  self.footer.lineBreakMode = NSLineBreakByTruncatingTail;
  self.footer.accessibilityLabel = @"Palette status";
  [background addSubview:self.footer];
}

- (void)layoutPanel {
  CGFloat resultsHeight = MIN(6, MAX(1, self.results.count)) * 56;
  CGFloat width = MIN(640, MAX(360, self.owner.frame.size.width - 48));
  NSScreen *screen = self.owner.screen ?: NSScreen.mainScreen;
  width = MIN(width, screen.visibleFrame.size.width - 32);
  CGFloat height = resultsHeight + 138;
  NSRect ownerFrame = self.owner ? self.owner.frame : screen.visibleFrame;
  CGFloat top = NSMaxY(ownerFrame) - MIN(100, ownerFrame.size.height * 0.12);
  NSRect frame = NSMakeRect(NSMidX(ownerFrame) - width / 2, top - height, width, height);
  NSRect visible = screen.visibleFrame;
  frame.origin.x = MAX(NSMinX(visible) + 12, MIN(frame.origin.x, NSMaxX(visible) - width - 12));
  frame.origin.y = MAX(NSMinY(visible) + 12, MIN(frame.origin.y, NSMaxY(visible) - height - 12));
  [self.panel setFrame:frame display:YES];
  self.titleLabel.frame = NSMakeRect(20, height - 36, width - 40, 20);
  self.search.frame = NSMakeRect(18, height - 88, width - 36, 38);
  self.separator.frame = NSMakeRect(20, height - 102, width - 40, 1);
  self.scroll.frame = NSMakeRect(12, 36, width - 24, resultsHeight);
  self.table.frame = NSMakeRect(0, 0, width - 24,
                               MAX(resultsHeight, self.results.count * 56));
  self.table.tableColumns.firstObject.width = width - 24;
  self.footer.frame = NSMakeRect(20, 11, width - 40, 17);
}

- (NSDictionary *)navigationForQuery:(NSString *)query {
  if (!query.length) return nil;
  NSString *lower = query.lowercaseString;
  BOOL explicitURL = [lower hasPrefix:@"http://"] || [lower hasPrefix:@"https://"] ||
                     [lower hasPrefix:@"file://"] || [lower hasPrefix:@"chrome://"];
  BOOL noSpaces = [query rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound;
  BOOL local = [lower isEqualToString:@"localhost"] || [lower hasPrefix:@"localhost:"] ||
               [lower hasPrefix:@"localhost/"] || [lower hasPrefix:@"127."] ||
               [lower hasPrefix:@"[::1]"];
  BOOL hostname = noSpaces && ([query containsString:@"."] || local) &&
                  ![query containsString:@"://"];
  NSString *url;
  NSString *title;
  NSString *detail;
  if (explicitURL || hostname) {
    NSString *candidate = explicitURL ? query :
        [NSString stringWithFormat:@"%@://%@", local ? @"http" : @"https", query];
    NSURLComponents *components = [NSURLComponents componentsWithString:candidate];
    url = components.URL.absoluteString ?: candidate;
    title = [NSString stringWithFormat:@"Open %@", query];
    detail = @"Navigate in this window";
  } else {
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://www.google.com/search"];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"q" value:query]];
    url = components.URL.absoluteString;
    title = [NSString stringWithFormat:@"Search Google for “%@”", query];
    detail = @"Search the web in this window";
  }
  return @{@"action": @"navigate", @"title": title, @"detail": detail,
           @"symbol": explicitURL || hostname ? @"globe" : @"magnifyingglass",
           @"shortcut": @"↵", @"url": url, @"isURL": @(explicitURL || hostname)};
}

- (void)rebuildResults {
  NSString *query = [self.search.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSArray *tokens = [query.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  NSMutableArray *matches = [NSMutableArray new];
  for (NSDictionary *command in self.tabsOnly ? @[] : self.commands) {
    NSString *haystack = [NSString stringWithFormat:@"%@ %@", command[@"title"], command[@"keywords"]].lowercaseString;
    BOOL matchesAll = YES;
    for (NSString *token in tokens) {
      if (token.length && ![haystack containsString:token]) { matchesAll = NO; break; }
    }
    if (matchesAll) [matches addObject:command];
  }
  NSMutableArray *tabMatches = [NSMutableArray new];
  if (self.tabMode) {
    NSUInteger index = 0;
    for (NSDictionary *tab in self.tabs) {
      NSString *targetId = [tab[@"id"] isKindOfClass:NSString.class] ? tab[@"id"] : nil;
      if (!targetId.length) { index++; continue; }
      NSString *url = [tab[@"url"] isKindOfClass:NSString.class] ? tab[@"url"] : @"";
      NSString *title = [tab[@"title"] isKindOfClass:NSString.class] ? tab[@"title"] : @"";
      if (!title.length) title = url.length ? url : @"Untitled tab";
      NSString *haystack = [NSString stringWithFormat:@"%@ %@", title, url].lowercaseString;
      BOOL matchesAll = YES;
      for (NSString *token in tokens) {
        if (token.length && ![haystack containsString:token]) { matchesAll = NO; break; }
      }
      if (matchesAll) {
        BOOL active = [tab[@"active"] boolValue];
        NSString *shortcut = index < 8 ? [NSString stringWithFormat:@"⌘%lu", (unsigned long)index + 1] :
            (index == self.tabs.count - 1 ? @"⌘9" : @"");
        [tabMatches addObject:@{
          @"action": @"activate-tab", @"targetId": targetId,
          @"title": [NSString stringWithFormat:@"Switch to %@", title],
          @"detail": active ? [@"Current tab · " stringByAppendingString:url] : url,
          @"symbol": active ? @"checkmark.circle.fill" : @"rectangle.on.rectangle",
          @"shortcut": shortcut, @"active": @(active)
        }];
      }
      index++;
    }
  }
  if (!query.length || self.tabsOnly) [matches insertObjects:tabMatches atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, tabMatches.count)]];
  else [matches addObjectsFromArray:tabMatches];
  NSDictionary *navigation = self.tabsOnly ? nil : [self navigationForQuery:query];
  if (navigation) {
    if (([navigation[@"isURL"] boolValue] && !tabMatches.count) || !matches.count) [matches insertObject:navigation atIndex:0];
    else [matches addObject:navigation];
  }
  self.results = matches;
  [self.table reloadData];
  NSUInteger selection = 0;
  if (!query.length) {
    NSUInteger active = [matches indexOfObjectPassingTest:^BOOL(NSDictionary *item, __unused NSUInteger index, __unused BOOL *stop) {
      return [item[@"active"] boolValue];
    }];
    if (active != NSNotFound) selection = active;
  }
  if (matches.count) {
    [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:selection] byExtendingSelection:NO];
    [self.table scrollRowToVisible:(NSInteger)selection];
  }
  [self layoutPanel];
}

- (void)showForOwner:(NSWindow *)owner query:(NSString *)query {
  self.owner = owner;
  self.previousResponder = owner.firstResponder;
  self.focusPageOnDismiss = NO;
  self.tabsOnly = NO;
  self.tabs = @[];
  self.titleLabel.stringValue = self.tabMode ? @"Switch tabs, go to a page, or run a command" : @"Go to a page or run a command";
  self.search.stringValue = query ?: @"";
  self.busy = NO;
  self.footer.textColor = NSColor.tertiaryLabelColor;
  self.footer.stringValue = @"↑ ↓ to choose     ↵ to run     esc to dismiss";
  [self rebuildResults];
  [owner addChildWindow:self.panel ordered:NSWindowAbove];
  [self.panel makeKeyAndOrderFront:nil];
  [self.panel makeFirstResponder:self.search];
  [self.search selectText:nil];
  [DCBrowser sharedBrowser].targetWindow = owner;
}

- (void)refreshTabsForGeneration:(NSUInteger)generation {
  if (!self.tabMode) return;
  NSWindow *owner = self.owner;
  [DCBrowser sharedBrowser].targetWindow = owner;
  [[DCBrowser sharedBrowser] listTabs:^(NSArray<NSDictionary *> *tabs, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (generation != self.requestGeneration || !self.panel.visible || self.owner != owner) return;
      if (error) { [self showError:error]; return; }
      self.tabs = tabs ?: @[];
      [self rebuildResults];
    });
  }];
}

- (void)togglePrefillingURL:(BOOL)prefill {
  if (self.panel.visible) { [self dismissRestoringFocus:YES]; return; }
  NSWindow *owner = DCPaletteIsBrowserWindow(NSApp.keyWindow) ? NSApp.keyWindow : NSApp.mainWindow;
  if (!DCPaletteIsBrowserWindow(owner)) return;
  [self showForOwner:owner query:@""];
  NSUInteger generation = ++self.requestGeneration;
  [self refreshTabsForGeneration:generation];
  [[DCBrowser sharedBrowser] currentPageInfo:^(NSDictionary *info, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (generation != self.requestGeneration || !self.panel.visible) return;
      if (error) { [self showError:error]; return; }
      self.currentURL = info[@"url"] ?: @"";
      if (prefill && !self.search.stringValue.length) {
        self.search.stringValue = self.currentURL;
        [self rebuildResults];
        [self.search selectText:nil];
      }
    });
  }];
}

- (void)dismissRestoringFocus:(BOOL)restore {
  if (self.dismissing || !self.panel.visible) return;
  self.dismissing = YES;
  ++self.requestGeneration;
  [self.owner removeChildWindow:self.panel];
  [self.panel orderOut:nil];
  if (restore && self.owner.visible) {
    if (self.focusPageOnDismiss) {
      // CmdT can briefly leave Chrome's hidden omnibox focused while its new
      // renderer is being installed. Escape must focus the current page then,
      // rather than restore that transient responder or a previous tab's view.
      [DCBrowser sharedBrowser].targetWindow = self.owner;
      [[DCBrowser sharedBrowser] focusCurrentPage];
    } else {
      [self.owner makeKeyAndOrderFront:nil];
      if (self.previousResponder) [self.owner makeFirstResponder:self.previousResponder];
    }
  }
  self.focusPageOnDismiss = NO;
  self.dismissing = NO;
}

- (void)showError:(NSError *)error {
  self.busy = NO;
  self.footer.textColor = NSColor.systemRedColor;
  self.footer.stringValue = error.localizedDescription ?: @"The command could not be completed.";
  NSBeep();
}

- (void)executeSelection {
  if (self.busy || self.table.selectedRow < 0 || (NSUInteger)self.table.selectedRow >= self.results.count) return;
  NSDictionary *result = self.results[self.table.selectedRow];
  NSString *action = result[@"action"];
  // Discard a pending URL prefill, and keep this command from changing a later
  // palette session if the user dismisses or reopens the panel while it runs.
  NSUInteger generation = ++self.requestGeneration;
  [DCBrowser sharedBrowser].targetWindow = self.owner;
  self.busy = YES;
  self.footer.textColor = NSColor.secondaryLabelColor;
  self.footer.stringValue = @"Working…";
  if ([action isEqualToString:@"show-tabs"]) {
    self.busy = NO;
    self.tabsOnly = YES;
    self.titleLabel.stringValue = @"Switch to an open tab";
    self.search.stringValue = @"";
    self.footer.textColor = NSColor.tertiaryLabelColor;
    self.footer.stringValue = @"↑ ↓ to choose     ↵ to switch     esc to dismiss";
    [self rebuildResults];
    [self refreshTabsForGeneration:generation];
  } else if ([action isEqualToString:@"activate-tab"]) {
    [[DCBrowser sharedBrowser] activateTab:result[@"targetId"] completion:^(NSError *error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self.requestGeneration || !self.panel.visible) return;
        if (error) [self showError:error];
        else {
          self.busy = NO;
          [self dismissRestoringFocus:NO];
          [[DCBrowser sharedBrowser] focusCurrentPage];
        }
      });
    }];
  } else if ([action isEqualToString:@"navigate"]) {
    NSString *targetID = nil;
    if (self.tabMode) {
      // Freeze the selected page before CDP work begins: an immediate CmdT
      // must not redirect this navigation into the newly active tab.
      for (NSDictionary *tab in self.tabs) {
        if ([tab[@"active"] boolValue] && [tab[@"id"] isKindOfClass:NSString.class]) {
          targetID = tab[@"id"];
          break;
        }
      }
      if (!targetID.length) {
        [self showError:[NSError errorWithDomain:@"DeChrome" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Tab is still starting; try again"}]];
        [self refreshTabsForGeneration:generation];
        return;
      }
    }
    void (^completion)(NSError *) = ^(NSError *error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self.requestGeneration || !self.panel.visible) return;
        if (error) [self showError:error];
        else {
          self.busy = NO;
          [self dismissRestoringFocus:NO];
          [[DCBrowser sharedBrowser] focusCurrentPage];
        }
      });
    };
    if (self.tabMode) [[DCBrowser sharedBrowser] navigate:result[@"url"] tabID:targetID completion:completion];
    else [[DCBrowser sharedBrowser] navigate:result[@"url"] completion:completion];
  } else if ([action isEqualToString:@"manage-profiles"]) {
    const char *appPath = getenv("DECHROME_LAUNCHER_APP");
    NSURL *url = appPath ? [NSURL fileURLWithPath:@(appPath) isDirectory:YES] : nil;
    NSBundle *bundle = url ? [NSBundle bundleWithURL:url] : nil;
    if (![bundle.bundleIdentifier isEqualToString:@"local.dechrome.launcher"] ||
        ![NSFileManager.defaultManager isExecutableFileAtPath:bundle.executablePath]) {
      [self showError:[NSError errorWithDomain:@"DeChrome" code:1
          userInfo:@{NSLocalizedDescriptionKey:@"Reopen DeChrome to access Profiles and sync."}]];
      return;
    }
    NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
    configuration.arguments = @[@"profiles-ui"];
    configuration.createsNewApplicationInstance = YES;
    NSMutableDictionary *environment = [NSMutableDictionary new];
    for (NSString *key in @[@"DECHROME_DATA_DIR", @"DECHROME_LOG_DIR", @"DECHROME_CHROME_PATH",
                            @"DECHROME_RESOURCES_DIR", @"DECHROME_PROFILE_SOURCE_DIR"]) {
      NSString *value = NSProcessInfo.processInfo.environment[key];
      if (value.length) environment[key] = value;
    }
    configuration.environment = environment;
    NSWindow *owner = self.owner;
    [self dismissRestoringFocus:NO];
    [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:configuration
        completionHandler:^(__unused NSRunningApplication *application, NSError *error) {
      if (!error) return;
      DCPaletteOnMain(^{
        if (!owner.visible) return;
        [self showForOwner:owner query:@"Profiles and sync"];
        [self showError:error];
      });
    }];
  } else if ([action isEqualToString:@"copy-url"]) {
    [[DCBrowser sharedBrowser] currentPageInfo:^(NSDictionary *info, NSError *error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self.requestGeneration || !self.panel.visible) return;
        if (error) { [self showError:error]; return; }
        NSString *url = info[@"url"];
        if (!url.length) {
          [self showError:[NSError errorWithDomain:@"DeChrome" code:1 userInfo:@{NSLocalizedDescriptionKey: @"This page has no URL to copy."}]];
          return;
        }
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:url forType:NSPasteboardTypeString];
        self.busy = NO;
        [self dismissRestoringFocus:YES];
      });
    }];
  } else {
    NSWindow *owner = self.owner;
    NSString *query = self.search.stringValue;
    BOOL changesPage = DCActionChangesPage(action);
    [self dismissRestoringFocus:!changesPage];
    NSUInteger actionGeneration = self.requestGeneration;
    [[DCBrowser sharedBrowser] performAction:action completion:^(NSError *error) {
      DCPaletteOnMain(^{
        if (actionGeneration != self.requestGeneration) return;
        self.busy = NO;
        if (error && owner.visible) {
          [self showForOwner:owner query:query];
          [self showError:error];
        } else if (!error && owner.visible && NSApp.active) {
          if (changesPage) [[DCBrowser sharedBrowser] focusCurrentPage];
          if ([action isEqualToString:@"new-tab"]) {
            [self togglePrefillingURL:NO];
            self.focusPageOnDismiss = self.panel.visible;
          }
        }
      });
    }];
  }
}

- (NSWindow *)browserWindowForShortcut {
  NSWindow *window = self.panel.visible ? self.owner : NSApp.keyWindow;
  if (!DCPaletteIsBrowserWindow(window)) window = NSApp.mainWindow;
  return DCPaletteIsBrowserWindow(window) ? window : nil;
}

- (void)runTabAction:(NSString *)action showLocationAfterward:(BOOL)showLocation {
  NSWindow *owner = [self browserWindowForShortcut];
  if (!owner) return;
  [self dismissRestoringFocus:NO];
  NSUInteger generation = ++self.requestGeneration;
  [DCBrowser sharedBrowser].targetWindow = owner;
  [[DCBrowser sharedBrowser] performAction:action completion:^(NSError *error) {
    DCPaletteOnMain(^{
      if (generation != self.requestGeneration || !owner.visible || !NSApp.active) return;
      if (error) {
        [self showForOwner:owner query:@""];
        [self showError:error];
      } else {
        [[DCBrowser sharedBrowser] focusCurrentPage];
        if (showLocation) {
          // The field becomes key synchronously with CmdT's native command;
          // metadata can arrive later without replacing the user's typing.
          [self togglePrefillingURL:NO];
          self.focusPageOnDismiss = self.panel.visible;
        }
      }
    });
  }];
}

- (void)activateTabAtShortcutIndex:(NSUInteger)index {
  NSWindow *owner = [self browserWindowForShortcut];
  if (!owner) return;
  [self dismissRestoringFocus:NO];
  NSUInteger generation = ++self.requestGeneration;
  [DCBrowser sharedBrowser].targetWindow = owner;
  [[DCBrowser sharedBrowser] listTabs:^(NSArray<NSDictionary *> *tabs, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (generation != self.requestGeneration || !owner.visible || !NSApp.active) return;
      if (error || !tabs.count) {
        if (error) { [self showForOwner:owner query:@""]; [self showError:error]; }
        return;
      }
      NSUInteger selected = index == 9 ? tabs.count - 1 : index - 1;
      if (selected >= tabs.count) return;
      NSString *target = tabs[selected][@"id"];
      if (!target.length) return;
      [[DCBrowser sharedBrowser] activateTab:target completion:^(NSError *activationError) {
        dispatch_async(dispatch_get_main_queue(), ^{
          if (generation != self.requestGeneration || !owner.visible || !NSApp.active) return;
          if (activationError) { [self showForOwner:owner query:@""]; [self showError:activationError]; }
          else [[DCBrowser sharedBrowser] focusCurrentPage];
        });
      }];
    });
  }];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
  (void)tableView;
  return (NSInteger)self.results.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
  (void)column;
  NSDictionary *result = self.results[row];
  NSTableCellView *cell = [tableView makeViewWithIdentifier:@"command-cell" owner:self];
  if (!cell) {
    cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableView.bounds.size.width, 56)];
    cell.identifier = @"command-cell";
    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(16, 17, 22, 22)];
    icon.imageScaling = NSImageScaleProportionallyDown;
    icon.contentTintColor = NSColor.secondaryLabelColor;
    cell.imageView = icon;
    [cell addSubview:icon];
    NSTextField *title = [NSTextField labelWithString:@""];
    title.frame = NSMakeRect(52, 29, tableView.bounds.size.width - 150, 19);
    title.autoresizingMask = NSViewWidthSizable;
    title.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    cell.textField = title;
    [cell addSubview:title];
    NSTextField *detail = [NSTextField labelWithString:@""];
    detail.identifier = @"detail";
    detail.frame = NSMakeRect(52, 10, tableView.bounds.size.width - 150, 16);
    detail.autoresizingMask = NSViewWidthSizable;
    detail.font = [NSFont systemFontOfSize:11];
    detail.textColor = NSColor.secondaryLabelColor;
    detail.lineBreakMode = NSLineBreakByTruncatingTail;
    [cell addSubview:detail];
    NSTextField *shortcut = [NSTextField labelWithString:@""];
    shortcut.identifier = @"shortcut";
    shortcut.frame = NSMakeRect(tableView.bounds.size.width - 82, 19, 64, 20);
    shortcut.autoresizingMask = NSViewMinXMargin;
    shortcut.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    shortcut.textColor = NSColor.tertiaryLabelColor;
    shortcut.alignment = NSTextAlignmentRight;
    [cell addSubview:shortcut];
  }
  cell.textField.stringValue = result[@"title"];
  cell.imageView.image = [NSImage imageWithSystemSymbolName:result[@"symbol"] accessibilityDescription:nil];
  for (NSView *view in cell.subviews) {
    if ([view.identifier isEqualToString:@"detail"]) ((NSTextField *)view).stringValue = result[@"detail"];
    if ([view.identifier isEqualToString:@"shortcut"]) ((NSTextField *)view).stringValue = result[@"shortcut"];
  }
  return cell;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
  (void)tableView; (void)row;
  return [DCPaletteRow new];
}

- (void)tableClicked:(id)sender { (void)sender; [self executeSelection]; }

- (void)controlTextDidChange:(NSNotification *)notification {
  (void)notification;
  if (self.busy) return;
  self.footer.textColor = NSColor.tertiaryLabelColor;
  self.footer.stringValue = @"↑ ↓ to choose     ↵ to run     esc to dismiss";
  [self rebuildResults];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
  (void)control; (void)textView;
  if (selector == @selector(cancelOperation:)) { [self dismissRestoringFocus:YES]; return YES; }
  if (selector == @selector(insertNewline:)) { [self executeSelection]; return YES; }
  if (selector == @selector(moveUp:) || selector == @selector(moveDown:)) {
    NSInteger row = self.table.selectedRow + (selector == @selector(moveDown:) ? 1 : -1);
    row = MAX(0, MIN((NSInteger)self.results.count - 1, row));
    if (row >= 0) {
      [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
      [self.table scrollRowToVisible:row];
    }
    return YES;
  }
  return NO;
}

- (void)windowDidResignKey:(NSNotification *)notification {
  (void)notification;
  if (!self.dismissing) [self dismissRestoringFocus:NO];
}
@end

void DCPaletteInstall(void) {
  static DCPaletteController *controller;
  static id keyMonitor;
  static id clickMonitor;
  if (controller) return;
  controller = [DCPaletteController new];
  keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    NSEventModifierFlags relevant = flags & (NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                             NSEventModifierFlagControl | NSEventModifierFlagShift);
    NSString *key = event.charactersIgnoringModifiers.lowercaseString;
    if (relevant == NSEventModifierFlagCommand &&
        ([key isEqualToString:@"k"] || [key isEqualToString:@"l"]) &&
        (controller.panel.visible || DCPaletteIsBrowserWindow(NSApp.keyWindow) || DCPaletteIsBrowserWindow(NSApp.mainWindow))) {
      [controller togglePrefillingURL:[key isEqualToString:@"l"]];
      return nil;
    }
    if (controller.tabMode && [controller browserWindowForShortcut]) {
      if (relevant == NSEventModifierFlagCommand && [key isEqualToString:@"t"]) {
        [controller runTabAction:@"new-tab" showLocationAfterward:YES];
        return nil;
      }
      if (relevant == NSEventModifierFlagCommand && [key isEqualToString:@"w"]) {
        [controller runTabAction:@"close-tab" showLocationAfterward:NO];
        return nil;
      }
      if (relevant == (NSEventModifierFlagCommand | NSEventModifierFlagShift) && [key isEqualToString:@"w"]) {
        [controller runTabAction:@"close-window" showLocationAfterward:NO];
        return nil;
      }
      // Chrome's own tab shortcuts preserve its true tab order. While our
      // search field owns focus, dispatch their equivalent to the tab bridge.
      if (controller.panel.visible && event.keyCode == 48 &&
          (relevant == NSEventModifierFlagControl ||
           relevant == (NSEventModifierFlagControl | NSEventModifierFlagShift))) {
        [controller runTabAction:(relevant & NSEventModifierFlagShift) ? @"previous-tab" : @"next-tab"
            showLocationAfterward:NO];
        return nil;
      }
      if (controller.panel.visible && relevant == NSEventModifierFlagCommand &&
          key.length == 1 && [@"123456789" containsString:key]) {
        [controller activateTabAtShortcutIndex:(NSUInteger)key.integerValue];
        return nil;
      }
    }
    if (controller.panel.visible && event.keyCode == 53) {
      [controller dismissRestoringFocus:YES];
      return nil;
    }
    return event;
  }];
  clickMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown handler:^NSEvent *(NSEvent *event) {
    if (controller.panel.visible && event.window != controller.panel)
      [controller dismissRestoringFocus:NO];
    return event;
  }];
  [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidResignActiveNotification
                                                  object:nil queue:NSOperationQueue.mainQueue
                                              usingBlock:^(__unused NSNotification *note) {
    ++controller.requestGeneration;
    [controller dismissRestoringFocus:NO];
  }];
  (void)keyMonitor; (void)clickMonitor;
}
