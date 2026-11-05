#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

// Chrome also exposes auxiliary WebContents as type "tab". Its tab-strip
// metadata is present only for a real tab belonging to a browser window.
static inline BOOL DCTargetHasTabStripMetadata(NSDictionary *target) {
  if (![target isKindOfClass:NSDictionary.class] ||
      ![target[@"type"] isEqual:@"tab"] ||
      ![target[@"targetId"] isKindOfClass:NSString.class] ||
      ![target[@"targetId"] length]) return NO;
  NSDictionary *metadata = [target[@"embedderData"] isKindOfClass:NSDictionary.class] ?
      target[@"embedderData"] : nil;
  NSNumber *index = metadata[@"tabStripIndex"];
  NSNumber *active = metadata[@"tabActive"];
  if (![index isKindOfClass:NSNumber.class] || ![active isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)index) != CFNumberGetTypeID() ||
      CFNumberIsFloatType((__bridge CFNumberRef)index) ||
      CFGetTypeID((__bridge CFTypeRef)active) != CFBooleanGetTypeID()) return NO;
  int64_t position;
  return CFNumberGetValue((__bridge CFNumberRef)index, kCFNumberSInt64Type, &position) &&
      position >= 0;
}

// Only this precise per-target lookup failure is safe to ignore. In particular,
// network failures, enterprise restrictions, and unsupported commands remain
// failures even if another tab happened to return valid metadata.
static inline BOOL DCTargetWindowLookupCanBeSkipped(NSError *error) {
  NSNumber *protocolCode = error.userInfo[@"CDPCode"];
  return [error.domain isEqualToString:@"DeChrome.Browser"] && error.code == 12 &&
      [protocolCode isKindOfClass:NSNumber.class] &&
      [protocolCode compare:@(-32000)] == NSOrderedSame &&
      [error.localizedDescription isEqualToString:@"Browser window not found"];
}
