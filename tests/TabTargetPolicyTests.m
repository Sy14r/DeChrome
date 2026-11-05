#import <Foundation/Foundation.h>
#import "../native/DCBrowserTargetPolicy.h"

static NSUInteger checks;
static NSUInteger failures;

static void Require(BOOL condition, NSString *description) {
  checks++;
  if (!condition) {
    failures++;
    fprintf(stderr, "FAIL: %s\n", description.UTF8String);
  }
}

static NSDictionary *Tab(NSString *identifier, id index, id active) {
  return @{@"type":@"tab", @"targetId":identifier,
           @"embedderData":@{@"tabStripIndex":index, @"tabActive":active}};
}

static NSError *ProtocolError(NSNumber *code, NSString *message) {
  return [NSError errorWithDomain:@"DeChrome.Browser" code:12
                        userInfo:@{@"CDPCode":code, NSLocalizedDescriptionKey:message}];
}

int main(void) {
  @autoreleasepool {
    NSDictionary *first = Tab(@"normal-a", @0, @YES);
    NSDictionary *second = Tab(@"normal-b", @1, @NO);
    // Chrome can expose a WebContents tab target without tab-strip membership.
    NSDictionary *auxiliary = @{@"type":@"tab", @"targetId":@"auxiliary"};
    Require(DCTargetHasTabStripMetadata(first), @"active browser tab is eligible");
    Require(DCTargetHasTabStripMetadata(second), @"inactive browser tab is eligible");
    Require(!DCTargetHasTabStripMetadata(auxiliary), @"auxiliary WebContents target is excluded");

    NSPredicate *candidate = [NSPredicate predicateWithBlock:^BOOL(id target, __unused NSDictionary *bindings) {
      return DCTargetHasTabStripMetadata(target);
    }];
    NSArray *mixed = [@[first, auxiliary, second] filteredArrayUsingPredicate:candidate];
    Require([mixed isEqual:@[first, second]], @"auxiliary target does not poison valid tabs");
    Require([@[auxiliary] filteredArrayUsingPredicate:candidate].count == 0,
            @"an auxiliary-only response supplies no ready browser tabs");

    NSMutableDictionary *changed = [first mutableCopy];
    changed[@"type"] = @"page";
    Require(!DCTargetHasTabStripMetadata(changed), @"page target is not a tab-strip candidate");
    changed = [first mutableCopy];
    changed[@"targetId"] = @"";
    Require(!DCTargetHasTabStripMetadata(changed), @"empty target ID is excluded");
    changed[@"targetId"] = @42;
    Require(!DCTargetHasTabStripMetadata(changed), @"non-string target ID is excluded");
    [changed removeObjectForKey:@"targetId"];
    Require(!DCTargetHasTabStripMetadata(changed), @"missing target ID is excluded");

    for (id index in @[@(-1), @"0", @YES, @0.5, @1.0, NSNull.null]) {
      Require(!DCTargetHasTabStripMetadata(Tab(@"invalid-index", index, @YES)),
              [NSString stringWithFormat:@"invalid tab index %@ (%@) is excluded", index, [index class]]);
    }
    for (id active in @[@0, @1, @"true", NSNull.null]) {
      Require(!DCTargetHasTabStripMetadata(Tab(@"invalid-active", @0, active)),
              [NSString stringWithFormat:@"non-boolean active flag %@ (%@) is excluded", active, [active class]]);
    }
    for (id metadata in @[@"invalid", @1, NSNull.null, @{}]) {
      changed = [first mutableCopy];
      changed[@"embedderData"] = metadata;
      Require(!DCTargetHasTabStripMetadata(changed), @"malformed or missing tab metadata is excluded");
    }
    Require(!DCTargetHasTabStripMetadata((id)NSNull.null), @"non-dictionary response item is excluded");
    Require(!DCTargetHasTabStripMetadata(nil), @"missing response item is excluded");

    Require(DCTargetWindowLookupCanBeSkipped(ProtocolError(@(-32000), @"Browser window not found")),
            @"known unassociated or vanished window does not poison surviving tabs");
    Require(!DCTargetWindowLookupCanBeSkipped(ProtocolError(@(-32601), @"Browser window not found")),
            @"unsupported protocol method remains fatal");
    Require(!DCTargetWindowLookupCanBeSkipped(ProtocolError(@(-32000), @"Not allowed by policy")),
            @"policy rejection remains fatal");
    Require(!DCTargetWindowLookupCanBeSkipped(ProtocolError(@(-32000), @"No target with given id found")),
            @"unrecognized target error remains fatal");
    Require(!DCTargetWindowLookupCanBeSkipped(ProtocolError(@(-32000), @"Browser window not found: detail")),
            @"only the exact known protocol message is recoverable");
    Require(!DCTargetWindowLookupCanBeSkipped([NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut
                                                                    userInfo:@{NSLocalizedDescriptionKey:@"Browser window not found"}]),
            @"transport failure cannot masquerade as a recoverable protocol response");
    Require(!DCTargetWindowLookupCanBeSkipped([NSError errorWithDomain:@"DeChrome.Browser" code:12
                                                                    userInfo:@{NSLocalizedDescriptionKey:@"Browser window not found"}]),
            @"missing CDP code remains fatal");
    Require(!DCTargetWindowLookupCanBeSkipped([NSError errorWithDomain:@"DeChrome.Browser" code:22
                       userInfo:@{@"CDPCode":@(-32000), NSLocalizedDescriptionKey:@"Browser window not found"}]),
            @"metadata errors cannot masquerade as a recoverable protocol response");
    Require(!DCTargetWindowLookupCanBeSkipped(nil), @"absence of an error is not classified as recoverable");

    printf("Tab target policy: %lu/%lu checks passed.\n", (unsigned long)(checks - failures), (unsigned long)checks);
    return failures ? 1 : 0;
  }
}
