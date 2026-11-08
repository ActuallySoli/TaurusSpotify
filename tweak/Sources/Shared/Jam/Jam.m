#import "Core/SGPrefs.h"
#import "Core/SGLog.h"
#import "Core/SGFlagForce.h"
#import "Shared/Navigation/Links.h"
#import "Jam.h"
#import <objc/message.h>
#import <objc/runtime.h>

// `spotify:internal:startgroupsession` is not a link the dispatcher knows: it is matched by the
// URI subtype registry, which is where the Jam navigation event source lives. Going through the
// registry is the difference between Spotify's own start dialog and "can't open this type of link".
BOOL SGJamOpenStartSheet(void) {
    id dispatcher = SGLinkDispatcher();
    SGLog(@"jam: start sheet dispatcher %@", dispatcher ? NSStringFromClass([dispatcher class]) : @"nil");
    if (!dispatcher) return NO;
    @try {
        SEL handlerSelector = NSSelectorFromString(@"spotifyLinkHandler");
        id linkHandler = [dispatcher respondsToSelector:handlerSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(dispatcher, handlerSelector) : nil;
        SGLog(@"jam: link handler %@", linkHandler ? NSStringFromClass([linkHandler class]) : @"nil");
        SEL registrySelector = NSSelectorFromString(@"URISubtypeRegistry");
        id registry = linkHandler && [linkHandler respondsToSelector:registrySelector]
            ? ((id (*)(id, SEL))objc_msgSend)(linkHandler, registrySelector) : nil;
        SGLog(@"jam: subtype registry %@", registry ? NSStringFromClass([registry class]) : @"nil");
        NSURL *uri = [NSURL URLWithString:@"spotify:internal:startgroupsession"];
        SEL handle = NSSelectorFromString(@"handleURI:context:");
        if (registry && [registry respondsToSelector:handle]) {
            long long result = ((long long (*)(id, SEL, id, id))objc_msgSend)(registry, handle, uri, nil);
            SGLog(@"jam: registry handled %@ -> %lld", uri.absoluteString, result);
            return YES;
        }
        SEL spotify = NSSelectorFromString(@"handleSpotifyURL:context:");
        if (linkHandler && [linkHandler respondsToSelector:spotify]) {
            long long result = ((long long (*)(id, SEL, id, id))objc_msgSend)(linkHandler, spotify, uri, nil);
            SGLog(@"jam: link handler handled %@ -> %lld", uri.absoluteString, result);
            return YES;
        }
        return NO;
    } @catch (NSException *exception) {
        SGLog(@"jam: start URI refused: %@", exception.reason);
        return NO;
    }
}

// Two switches, two jobs. Unlock Jam frees the flow: with a spoofed premium product state the
// session itself checks out, but Spotify's own sheets would still jump in front of it, so the
// upsell sheets go off and the free in-person host gate goes on. Show Jam controls owns the queue
// shortcut itself: the now-playing button flag and the referrals banner that is the real Queue entry.
static NSString *const kQueueButtonFlag = @"ios-feature-nowplaying.jam_queue_button_enabled";
static NSString *const kQueueEntryFlag = @"ios-referrals-jamqueueentrypointimpl.referrals_jam_queue_enabled";

static id unlockValue(NSString *key) {
    if ([key isEqualToString:@"ios-jam-freehostedjamsupsell-impl.free_hosted_jams_upsell_enabled"]) return @(NO);
    if ([key isEqualToString:@"ios-jam-adsdisclaimersheetpage-impl.ads_disclaimer_sheet_enabled"]) return @(NO);
    if ([key isEqualToString:@"ios-jam-freeusershuffleupsellsheetpage-impl.free_user_shuffle_upsell_sheet_enabled"]) return @(NO);
    if ([key isEqualToString:@"ios-jam-freeuserskipupsellpage-impl.free_user_skip_upsell_sheet_enabled"]) return @(NO);
    if ([key isEqualToString:@"ios-sociallistening-configuration-impl.free_user_enabled_to_host_in_person_jam"]) return @(YES);
    if ([key isEqualToString:@"ios-sociallistening-configuration-impl.is_nearby_jam_invite_deeplink_enabled"]) return @(YES);
    if ([key isEqualToString:@"ios-sociallistening-configuration-impl.join_sheet_from_join_options_enabled"]) return @(YES);
    if ([key isEqualToString:@"ios-sociallistening-configuration-impl.nearby_session_invitation_enabled"]) return @(YES);
    return nil;
}

NSString *SGJamProductStateValueForKey(NSString *key) {
    if (![key isKindOfClass:NSString.class] || !SGFlag(SGKeyJamUnlock, YES)) return nil;
    if ([key isEqualToString:@"jam-social-session"]) return @"EXPANDED";
    if ([key isEqualToString:@"jam-queue-commands-feedback"]) return @"1";
    if ([key isEqualToString:@"social-session"]) return @"1";
    if ([key isEqualToString:@"social-session-free-tier"]) return @"0";
    return nil;
}

static void setByteIvarIfPresent(id target, const char *name, uint8_t value) {
    Ivar ivar = class_getInstanceVariable(object_getClass(target), name);
    if (!ivar) return;
    ptrdiff_t offset = ivar_getOffset(ivar);
    if (offset < (ptrdiff_t)sizeof(void *)) return;
    *((uint8_t *)((__bridge void *)target) + offset) = value;
}

BOOL SGJamForceUserCapabilities(id target) {
    if (!target || !SGFlag(SGKeyJamUnlock, YES)) return NO;
    Class cls = object_getClass(target);
    Ivar capIvar = class_getInstanceVariable(cls, "userCapabilities");
    if (!capIvar) return NO;
    ptrdiff_t offset = ivar_getOffset(capIvar);
    if (offset < (ptrdiff_t)sizeof(void *)) return NO;
    // JamUserCapabilities (7 bytes):
    // [0] featureEnabled = 1
    // [1] canHostJam = 1
    // [2] canHostWithRemoteParticipants = 1
    // [3] canJoinInPerson = 1
    // [4] canJoinRemotely = 1
    // [5] canShowPremiumUpsell = 0
    // [6] canShowPremiumGatedStartJamEntryPoint = 0
    static const uint8_t kExpandedCapabilities[7] = {1, 1, 1, 1, 1, 0, 0};
    memcpy((uint8_t *)((__bridge void *)target) + offset, kExpandedCapabilities, sizeof(kExpandedCapabilities));
    setByteIvarIfPresent(target, "isNearbyJamInviteDeeplinkEnabled", 1);
    setByteIvarIfPresent(target, "isJoinSheetFromJoinOptionsEnabled", 1);
    Ivar presenterIvar = class_getInstanceVariable(cls, "joinSheetPresenter");
    if (presenterIvar && ivar_getOffset(presenterIvar) >= (ptrdiff_t)sizeof(void *)) {
        void *presenter = *(void **)((uint8_t *)((__bridge void *)target) + ivar_getOffset(presenterIvar));
        if (presenter && presenter != (__bridge void *)target) SGJamForceUserCapabilities((__bridge id)presenter);
    }
    return YES;
}

static NSString *(*orig_productStateStringForKey)(id, SEL, NSString *);
static NSString *swizzled_productStateStringForKey(id self, SEL _cmd, NSString *key) {
    NSString *forced = SGJamProductStateValueForKey(key);
    return forced ?: (orig_productStateStringForKey ? orig_productStateStringForKey(self, _cmd, key) : nil);
}

static id (*orig_productStateSubscript)(id, SEL, NSString *);
static id swizzled_productStateSubscript(id self, SEL _cmd, NSString *key) {
    NSString *forced = SGJamProductStateValueForKey(key);
    return forced ?: (orig_productStateSubscript ? orig_productStateSubscript(self, _cmd, key) : nil);
}

static NSDictionary *(*orig_productStateValues)(id, SEL);
static NSDictionary *swizzled_productStateValues(id self, SEL _cmd) {
    NSDictionary *base = orig_productStateValues ? orig_productStateValues(self, _cmd) : nil;
    if (!SGFlag(SGKeyJamUnlock, YES) || ![base isKindOfClass:NSDictionary.class]) return base;
    NSMutableDictionary *merged = [base mutableCopy];
    for (NSString *key in @[@"jam-social-session", @"jam-queue-commands-feedback", @"social-session", @"social-session-free-tier"]) {
        NSString *val = SGJamProductStateValueForKey(key);
        if (val) merged[key] = val;
    }
    return merged;
}

static BOOL (*orig_jamCanHandleURI)(id, SEL, id);
static BOOL swizzled_jamCanHandleURI(id self, SEL _cmd, id uri) {
    SGJamForceUserCapabilities(self);
    return orig_jamCanHandleURI ? orig_jamCanHandleURI(self, _cmd, uri) : NO;
}

static long long (*orig_jamOpenURI)(id, SEL, id, id);
static long long swizzled_jamOpenURI(id self, SEL _cmd, id uri, id context) {
    SGJamForceUserCapabilities(self);
    return orig_jamOpenURI ? orig_jamOpenURI(self, _cmd, uri, context) : 0;
}

static void installJamRuntimeHooks(void) {
    Class productStateCls = objc_getClass("SPTCoreProductState");
    if (productStateCls) {
        Method mStr = class_getInstanceMethod(productStateCls, @selector(stringForKey:));
        if (mStr) {
            orig_productStateStringForKey = (void *)method_getImplementation(mStr);
            method_setImplementation(mStr, (IMP)swizzled_productStateStringForKey);
        }
        Method mSub = class_getInstanceMethod(productStateCls, @selector(objectForKeyedSubscript:));
        if (mSub) {
            orig_productStateSubscript = (void *)method_getImplementation(mSub);
            method_setImplementation(mSub, (IMP)swizzled_productStateSubscript);
        }
        Method mVal = class_getInstanceMethod(productStateCls, @selector(values));
        if (mVal) {
            orig_productStateValues = (void *)method_getImplementation(mVal);
            method_setImplementation(mVal, (IMP)swizzled_productStateValues);
        }
    }
    Class deeplinkCls = objc_getClass("_TtC24Jam_JoinGroupSessionImpl22JamDeeplinkHandlerImpl");
    if (deeplinkCls) {
        SEL canSel = NSSelectorFromString(@"URISubtypeHandlerCanHandleURI:");
        Method mCan = class_getInstanceMethod(deeplinkCls, canSel);
        if (mCan) {
            orig_jamCanHandleURI = (void *)method_getImplementation(mCan);
            method_setImplementation(mCan, (IMP)swizzled_jamCanHandleURI);
        }
        SEL openSel = NSSelectorFromString(@"URISubtypeHandlerOpenURI:context:");
        Method mOpen = class_getInstanceMethod(deeplinkCls, openSel);
        if (mOpen) {
            orig_jamOpenURI = (void *)method_getImplementation(mOpen);
            method_setImplementation(mOpen, (IMP)swizzled_jamOpenURI);
        }
    }
}

static id controlsValue(NSString *key) {
    if ([key isEqualToString:kQueueButtonFlag] || [key isEqualToString:kQueueEntryFlag]) return @(YES);
    // The Queue's Start a Jam header is the premium-gated start button, drawn by QueueIntegration;
    // both gates have to be on for the header to exist at all.
    if ([key isEqualToString:@"ios-sociallistening-configuration-impl.premium_gated_start_jam_buttons_enabled"]) return @(YES);
    if ([key isEqualToString:@"ios-jam-queueintegrationimpl.enable_listen_along_queue_header"]) return @(YES);
    return nil;
}

NSNumber *SGJamForcedFlag(NSString *key) {
    id value = SGFlag(SGKeyJamUnlock, YES) ? unlockValue(key) : nil;
    if (!value && SGEnabled(SGKeyJamControls)) value = controlsValue(key);
    return value;
}

BOOL SGJamUsesAccountIdentity(void) {
    return SGFlag(SGKeyJamAccountIdentity, NO);
}

__attribute__((constructor)) static void registerJam(void) {
    SGRegisterFlagForcer(NO, ^id(NSString *key) {
        static dispatch_once_t once;
        static BOOL unlock, controls;
        dispatch_once(&once, ^{
            unlock = SGFlag(SGKeyJamUnlock, YES);
            controls = SGEnabled(SGKeyJamControls);
        });
        id value = unlock ? unlockValue(key) : nil;
        if (!value && controls) value = controlsValue(key);
        return value;
    }, ^id(NSString *key) { return SGJamForcedFlag(key); });
    installJamRuntimeHooks();
}
