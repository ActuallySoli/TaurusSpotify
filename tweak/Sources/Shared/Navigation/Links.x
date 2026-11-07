#import "Core/SGCore.h"
#import "Headers/SPTLinkDispatcherImplementation.h"
#import "Links.h"
#import <objc/message.h>
#import <objc/runtime.h>

static __weak SPTLinkDispatcherImplementation *sg_linkDispatcher;

id SGLinkDispatcher(void) {
    return sg_linkDispatcher;
}

static id sg_send(id target, NSString *selector);

BOOL SGOpenSpotifyURI(NSURL *uri) {
    SPTLinkDispatcherImplementation *dispatcher = sg_linkDispatcher;
    if (![uri.scheme.lowercaseString isEqualToString:@"spotify"] || !dispatcher) return NO;
    SEL navigate = NSSelectorFromString(@"navigateToInternalURI:options:reason:resultHandler:");
    id reason = sg_send(NSClassFromString(@"SPTUBINavigationReason"), @"unknown");
    if (reason && [dispatcher respondsToSelector:navigate]) {
        @try {
            BOOL opened = ((BOOL (*)(id, SEL, id, long long, id, id))objc_msgSend)(dispatcher, navigate,
                uri, 0, reason, nil);
            SGLog(@"links: destination-stack navigate %@ -> %@", uri.absoluteString, opened ? @"YES" : @"NO");
            return opened;
        } @catch (NSException *e) {
            SGLog(@"links: navigation dispatcher threw %@", e.reason);
            return NO;
        }
    }
    SGLog(@"links: internal navigation unavailable for %@", uri.absoluteString);
    return NO;
}

// The navigate entry point has moved between Spotify majors; keep the actual list in the log
// so the next rename is a log read, not a crash hunt.
static void logDispatcherMethods(id dispatcher) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        unsigned count = 0;
        Method *methods = class_copyMethodList(object_getClass(dispatcher), &count);
        if (!methods) return;
        NSMutableString *list = [[NSString stringWithFormat:@"dispatcher methods (%u):", count] mutableCopy];
        for (unsigned i = 0; i < count; i++)
            [list appendFormat:@"\n  %s %s", sel_getName(method_getName(methods[i])),
                method_getTypeEncoding(methods[i])];
        free(methods);
        SGLogLong(@"links", list);
    });
}

#pragma mark - asking before opening

static void logDispatcherMethods(id dispatcher);

static id sg_send(id target, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

static id sg_send1(id target, NSString *selector, id arg) {
    SEL sel = NSSelectorFromString(selector);
    if (![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(target, sel, arg);
}

static NSString *takerFor(id<NSFastEnumeration> handlers, NSURL *uri, NSUInteger *asked) {
    SEL canHandle = NSSelectorFromString(@"URISubtypeHandlerCanHandleURI:");
    for (id handler in handlers) {
        NSString *name = NSStringFromClass([handler class]);
        if ([name containsString:@"EventSource"] || ![handler respondsToSelector:canHandle]) continue;
        (*asked)++;
        if (((BOOL (*)(id, SEL, id))objc_msgSend)(handler, canHandle, uri)) return name;
    }
    return nil;
}

SGLinkRoute SGSpotifyURIRoute(NSURL *uri, NSString **via) {
    if (via) *via = nil;
    if (!uri) return SGLinkRouteNone;
    id linkHandler = sg_send(sg_linkDispatcher, @"spotifyLinkHandler");
    id handlers = sg_send(sg_send(linkHandler, @"URISubtypeRegistry"), @"handlers");
    if (![handlers conformsToProtocol:@protocol(NSFastEnumeration)]) return SGLinkRouteUnknown;
    @try {
        NSURL *clean = sg_send(uri, @"spt_normalizedSpotifyURI");
        if (![clean isKindOfClass:NSURL.class]) clean = uri;
        NSUInteger asked = 0;
        NSString *taker = takerFor(handlers, clean, &asked);
        if (!taker) {
            NSURL *remapped = sg_send1(linkHandler, @"remapURI:", clean);
            if ([remapped isKindOfClass:NSURL.class] && ![remapped isEqual:clean]) {
                taker = takerFor(handlers, remapped, &asked);
                if (taker) taker = [NSString stringWithFormat:@"remap %@ %@", remapped.absoluteString, taker];
            }
        }
        if (!asked) return SGLinkRouteUnknown;
        if (via) *via = taker;
        return taker ? SGLinkRouteOpens : SGLinkRouteNone;
    } @catch (NSException *e) {
        SGLog(@"links: asking about %@ threw %@", uri, e.reason);
        return SGLinkRouteUnknown;
    }
}

NSURL *SGSpotifyURIFromText(NSString *text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithString:trimmed];
    NSString *host = parts.host.lowercaseString;
    if ([parts.scheme.lowercaseString hasPrefix:@"http"] && [host isEqualToString:@"open.spotify.com"]) {
        NSMutableArray<NSString *> *path = [NSMutableArray array];
        for (NSString *piece in [parts.path componentsSeparatedByString:@"/"]) {
            if (piece.length) [path addObject:piece];
        }
        if (path.count && [path.firstObject hasPrefix:@"intl-"]) [path removeObjectAtIndex:0];
        if (path.count >= 2) {
            NSString *destination = [@"spotify:" stringByAppendingString:[path componentsJoinedByString:@":"]];
            if ([path.firstObject isEqualToString:@"socialsession"] && parts.percentEncodedQuery.length)
                destination = [destination stringByAppendingFormat:@"?%@", parts.percentEncodedQuery];
            return [NSURL URLWithString:destination];
        }
    }
    return [NSURL URLWithString:trimmed];
}

%hook SPTLinkDispatcherImplementation
- (void)setMainUILoaded:(BOOL)loaded {
    %orig;
    sg_linkDispatcher = (SPTLinkDispatcherImplementation *)self;
    logDispatcherMethods(self);
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"SPTLinkDispatcherImplementation"]);
}
