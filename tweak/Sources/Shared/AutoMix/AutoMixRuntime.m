#import "AutoMix.h"
#import "Core/SGPrefs.h"
#import "Core/SGLog.h"
#import "Shared/Player/PlayerState.h"
#import <objc/message.h>
#include <math.h>

static id sg_preferences;
static id sg_state;
static __weak id sg_player;
static BOOL sg_writing;
static NSString *sg_applied;
static NSString *sg_status = @"Waiting for Spotify's player";
static NSString *sg_lastTransition, *sg_lastTrackURI, *sg_lastEngine;
static NSString *const kSavedPreferences = @"spotifyglass.automix.savedPreferences";

static id get(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static BOOL available(id preferences) {
    for (NSString *selector in @[@"audioAutomix", @"setAudioAutomix:", @"audioCrossfade", @"setAudioCrossfade:",
                                 @"audioCrossfadeTime", @"setAudioCrossfadeTime:"]) {
        if (![preferences respondsToSelector:NSSelectorFromString(selector)]) return NO;
    }
    return YES;
}

static BOOL readBool(id preferences, NSString *name) {
    return ((BOOL (*)(id, SEL))objc_msgSend)(preferences, NSSelectorFromString(name));
}

static NSInteger readTime(id preferences) {
    return ((NSInteger (*)(id, SEL))objc_msgSend)(preferences, NSSelectorFromString(@"audioCrossfadeTime"));
}

static NSDictionary *snapshot(void) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:kSavedPreferences];
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *key in @[@"automix", @"crossfade", @"time"]) {
        if (![value[key] isKindOfClass:NSNumber.class]) return nil;
    }
    return value;
}

static void setStatus(NSString *status) {
    if ([sg_status isEqualToString:status]) return;
    sg_status = [status copy];
    SGLog(@"automix: %@", status);
    [NSNotificationCenter.defaultCenter postNotificationName:SGAutoMixStatusDidChangeNotification object:nil];
}

static BOOL writePreferences(BOOL automix, BOOL crossfade, NSInteger time) {
    if (!available(sg_preferences)) return NO;
    sg_writing = YES;
    @try {
        if (readTime(sg_preferences) != time)
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(sg_preferences, NSSelectorFromString(@"setAudioCrossfadeTime:"), time);
        if (readBool(sg_preferences, @"audioCrossfade") != crossfade)
            ((void (*)(id, SEL, BOOL))objc_msgSend)(sg_preferences, NSSelectorFromString(@"setAudioCrossfade:"), crossfade);
        if (readBool(sg_preferences, @"audioAutomix") != automix)
            ((void (*)(id, SEL, BOOL))objc_msgSend)(sg_preferences, NSSelectorFromString(@"setAudioAutomix:"), automix);
        return YES;
    } @catch (NSException *exception) {
        SGLog(@"automix: preferences failed: %@", exception.reason);
        return NO;
    } @finally {
        sg_writing = NO;
    }
}

static void restorePreferences(void) {
    NSDictionary *saved = snapshot();
    if (!saved) return;
    if (writePreferences([saved[@"automix"] boolValue], [saved[@"crossfade"] boolValue], [saved[@"time"] integerValue])) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kSavedPreferences];
        sg_applied = nil;
    }
}

void SGAutoMixRestorePreferences(void) {
    if (NSThread.isMainThread) restorePreferences();
}

static NSDictionary *metadata(id track) {
    id value = get(track, @"metadata");
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

static BOOL eligibleState(id state) {
    NSString *context = SGURIString(get(state, @"contextURI"));
    id track = get(state, @"track");
    if (!SGAutoMixContextAllowed(context) || !SGAutoMixTrackAllowed(SGURIString(get(track, @"URI")), get(track, @"provider"))) return NO;
    id future = get(state, @"future");
    if ([future isKindOfClass:NSArray.class] && [future count]) {
        id next = [future firstObject];
        if (!SGAutoMixTrackAllowed(SGURIString(get(next, @"URI")), get(next, @"provider"))) return NO;
    }
    return YES;
}

static void apply(void) {
    if (sg_writing) return;
    if (!SGAutoMixEnabled()) {
        restorePreferences();
        setStatus(@"Off · Spotify's playback settings");
        return;
    }
    if (!sg_state) { setStatus(@"Waiting for Spotify's player"); return; }
    if (!eligibleState(sg_state)) {
        restorePreferences();
        setStatus(@"Spotify's settings · outside selected music contexts");
        return;
    }
    if (!available(sg_preferences)) { setStatus(@"Waiting for Spotify's playback preferences"); return; }
    id track = get(sg_state, @"track");
    BOOL planned = SGAutoMixHasTransition(metadata(track));
    BOOL beat = SGAutoMixUsesBeatMatching();
    BOOL fade = !beat || !planned;
    NSInteger time = fade ? SGAutoMixBlendSeconds() * 1000 : 0;
    NSString *signature = [NSString stringWithFormat:@"%d:%d:%ld", beat, fade, (long)time];
    if (![signature isEqualToString:sg_applied]) {
        if (!snapshot()) {
            NSDictionary *saved = @{@"automix": @(readBool(sg_preferences, @"audioAutomix")),
                @"crossfade": @(readBool(sg_preferences, @"audioCrossfade")), @"time": @(readTime(sg_preferences))};
            [NSUserDefaults.standardUserDefaults setObject:saved forKey:kSavedPreferences];
        }
        if (!writePreferences(beat, fade, time)) { setStatus(@"Spotify's playback preferences unavailable"); return; }
        sg_applied = signature;
    }
    if (beat && planned) setStatus(@"Next transition · Spotify plan");
    else setStatus([NSString stringWithFormat:beat ? @"Next transition · %ld s crossfade (no Spotify plan)" : @"Next transition · %ld s crossfade", (long)SGAutoMixBlendSeconds()]);
}

void SGAutoMixPlayerAvailable(id player) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGAutoMixPlayerAvailable(player); });
        return;
    }
    sg_player = player;
}

BOOL SGAutoMixApplyCurrentPlayback(void) {
    if (!NSThread.isMainThread) return NO;
    id observedPlayer = SGPlaybackPlayer();
    if (observedPlayer) sg_player = observedPlayer;
    id state = SGPlayerState() ?: get(sg_player, @"state") ?: sg_state;
    if (state) sg_state = state;
    sg_applied = nil;
    apply();
    SGLog(@"automix: Apply enabled=%d state=%@ player=%@ preferences=%@ result=%@", SGAutoMixEnabled(),
        NSStringFromClass([state class]), NSStringFromClass([sg_player class]), NSStringFromClass([sg_preferences class]), sg_status);
    return SGAutoMixEnabled() && state && eligibleState(state) && available(sg_preferences) && sg_applied != nil;
}

BOOL SGAutoMixPreviewTransition(void) {
    if (!SGAutoMixApplyCurrentPlayback()) return NO;
    id player = sg_player;
    SEL durationSelector = NSSelectorFromString(@"duration");
    SEL seekSelector = NSSelectorFromString(@"seekTo:");
    id future = get(sg_state, @"future");
    if (![player respondsToSelector:seekSelector] || ![sg_state respondsToSelector:durationSelector]
        || ![future isKindOfClass:NSArray.class] || ![future count]) return NO;
    double duration = ((double (*)(id, SEL))objc_msgSend)(sg_state, durationSelector);
    if (!isfinite(duration) || duration <= 15) return NO;
    ((id (*)(id, SEL, double))objc_msgSend)(player, seekSelector, duration - 15);
    return YES;
}

void SGAutoMixPreferencesAvailable(id preferences) {
    dispatch_block_t update = ^{
        if (sg_preferences == preferences || !available(preferences)) return;
        sg_applied = nil;
        sg_preferences = preferences;
        SGLog(@"automix: captured playback preferences from %@", NSStringFromClass([preferences class]));
        apply();
    };
    if (NSThread.isMainThread) update(); else dispatch_async(dispatch_get_main_queue(), update);
}

void SGAutoMixPreferenceChanged(id preferences, NSString *key, id value) {
    if (!NSThread.isMainThread || sg_writing || preferences != sg_preferences || !snapshot()) return;
    NSMutableDictionary *saved = [snapshot() mutableCopy];
    saved[key] = value;
    [NSUserDefaults.standardUserDefaults setObject:saved forKey:kSavedPreferences];
    sg_applied = nil;
}

void SGAutoMixPlayerStateChanged(id state) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGAutoMixPlayerStateChanged(state); });
        return;
    }
    sg_state = state;
    // A track change reports the outgoing selection, not proof of an audible mix.
    if (SGAutoMixEnabled() && eligibleState(state)) {
        id track = get(state, @"track");
        NSString *uri = SGURIString(get(track, @"URI"));
        if (uri.length && sg_lastTrackURI.length && ![uri isEqualToString:sg_lastTrackURI]) {
            NSString *title = get(track, @"trackTitle");
            if (![title isKindOfClass:NSString.class]) title = nil;
            NSString *engine = sg_lastEngine ?: @"Spotify settings";
            NSDateFormatter *clock = [NSDateFormatter new];
            clock.dateFormat = @"HH:mm";
            sg_lastTransition = [NSString stringWithFormat:@"%@ · %@ · %@",
                [clock stringFromDate:NSDate.date], engine,
                title.length ? title : @"Song"];
            [NSNotificationCenter.defaultCenter postNotificationName:SGAutoMixStatusDidChangeNotification object:nil];
        }
        sg_lastTrackURI = [uri copy];
        sg_lastEngine = SGAutoMixUsesBeatMatching() && SGAutoMixHasTransition(metadata(track)) ?
            @"Spotify plan selected" : @"crossfade selected";
    } else {
        sg_lastTrackURI = nil;
        sg_lastEngine = nil;
    }
    apply();
}

void SGAutoMixSettingsChanged(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ SGAutoMixSettingsChanged(); }); return; }
    sg_applied = nil;
    apply();
}

NSString *SGAutoMixStatus(void) {
    return sg_status;
}

NSString *SGAutoMixLastTransition(void) {
    return sg_lastTransition;
}

// Spotify writes fade times in milliseconds on long songs and seconds on short ones. Decide the
// unit once for the whole plan: judging each value alone turns a 100 s start + 5 s overlap into
// 100 s..1,005 s.
static double planScale(double start, double length, double duration) {
    if (duration > 0) return (start > duration * 10.0 || length > duration * 10.0) ? 1000.0 : 1.0;
    return (start > 3600.0 || length > 3600.0) ? 1000.0 : 1.0;
}

static double metadataNumber(NSDictionary *metadata, NSString *key) {
    id value = metadata[key];
    if ([value isKindOfClass:NSNumber.class]) return [value doubleValue];
    if (![value isKindOfClass:NSString.class]) return NAN;
    double number;
    NSScanner *scanner = [NSScanner scannerWithString:value];
    return [scanner scanDouble:&number] && scanner.isAtEnd ? number : NAN;
}

BOOL SGAutoMixMixWindow(double *outStart, double *outEnd, NSString **outNext) {
    // The newest report, not the last one AutoMix applied: a skip or a queue edit can land between
    // observer callbacks, and the pill must follow the song that is actually current.
    id state = SGPlayerState() ?: sg_state;
    if (!SGAutoMixEnabled() || !state || !eligibleState(state)) return NO;
    NSDictionary *details = metadata(get(state, @"track"));
    SEL durationSelector = NSSelectorFromString(@"duration");
    double duration = [state respondsToSelector:durationSelector]
        ? ((double (*)(id, SEL))objc_msgSend)(state, durationSelector) : 0;
    if (!isfinite(duration) || duration < 0) duration = 0;
    // apply()'s rule: Spotify's plan only when Smart blend supplied one; every other case is the
    // configured crossfade over the song's end, so the pill and the sound always name one window.
    BOOL planned = SGAutoMixUsesBeatMatching() && SGAutoMixHasTransition(details);
    double start, length;
    if (planned) {
        double rawLength = metadataNumber(details, @"audio.fade_out_duration");
        if (!isfinite(rawLength) || rawLength <= 0) rawLength = metadataNumber(details, @"audio.fade_overlap");
        if (details[@"audio.fade_out_start_time"] != nil) {
            double rawStart = metadataNumber(details, @"audio.fade_out_start_time");
            double scale = planScale(rawStart, rawLength, duration);
            start = rawStart / scale;
            length = rawLength / scale;
        } else {
            double rawStop = metadataNumber(details, @"media.stop_position");
            if (isfinite(rawStop) && rawStop > 0 && isfinite(rawLength) && rawLength > 0) {
                double scale = planScale(rawStop, rawLength, duration);
                length = rawLength / scale;
                start = (rawStop / scale) - length;
            } else if (duration > 0 && isfinite(rawLength) && rawLength > 0) {
                double scale = planScale(0, rawLength, duration);
                length = rawLength / scale;
                start = duration - length;
            } else {
                return NO;
            }
        }
        if (!isfinite(length) || length <= 0) return NO;
    } else {
        length = SGAutoMixBlendSeconds();
        if (duration <= length) return NO;
        start = duration - length;
    }
    if (!isfinite(start) || start < 0 || (duration > 0 && start >= duration)) return NO;
    NSString *next = nil;
    id future = get(state, @"future");
    NSArray *tracks = [future isKindOfClass:NSArray.class] ? future : @[];
    id transition = details[@"automix.transition_uri"];
    BOOL named = planned && [transition isKindOfClass:NSString.class];
    for (id track in tracks) {
        if (named && ![SGURIString(get(track, @"URI")) isEqualToString:transition]) continue;
        id title = get(track, @"trackTitle");
        if ([title isKindOfClass:NSString.class]) next = title;
        break;   // the plan's own song, or the next one for the crossfade
    }
    if (outStart) *outStart = start;
    if (outEnd) *outEnd = MIN(start + length, duration > 0 ? duration : start + length);
    if (outNext) *outNext = next;
    return YES;
}

NSString *SGAutoMixTransitionDetails(void) {
    id state = SGPlayerState() ?: sg_state;
    NSDictionary *details = metadata(get(state, @"track"));
    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:(SGPlaybackPlayer() ?: sg_player) ? @"Playback controls: connected" : @"Playback controls: waiting for the player"];
    if (available(sg_preferences)) {
        [lines addObject:[NSString stringWithFormat:@"Spotify AutoMix: %@", readBool(sg_preferences, @"audioAutomix") ? @"on" : @"off"]];
        [lines addObject:[NSString stringWithFormat:@"Spotify crossfade: %@ · %.1f s", readBool(sg_preferences, @"audioCrossfade") ? @"on" : @"off", readTime(sg_preferences) / 1000.0]];
    } else [lines addObject:@"Playback settings: waiting for Spotify"];
    [lines addObject:@"\nTransition metadata:"];
    NSUInteger before = lines.count;
    for (NSString *key in @[@"automix.mode", @"automix.transition_uri", @"audio.fade_overlap", @"audio.fade_out_start_time",
                            @"audio.fade_out_duration", @"media.stop_position", @"audio.speed_automation"]) {
        id value = details[key];
        if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) [lines addObject:[NSString stringWithFormat:@"%@: %@", key, value]];
    }
    if (lines.count == before) [lines addObject:@"Spotify has supplied no transition metadata for this song."];
    return [lines componentsJoinedByString:@"\n"];
}

static NSString *contextURI(id context) {
    for (NSString *sel in @[@"URI", @"uri", @"URL", @"url"]) {
        NSString *value = SGURIString(get(context, sel));
        if (value.length > 0) return value;
    }
    id pages = get(context, @"pages");
    if ([pages isKindOfClass:NSArray.class] && [pages count] > 0) {
        id firstPage = [pages firstObject];
        for (NSString *sel in @[@"pageURL", @"pageURI", @"URI", @"URL"]) {
            NSString *value = SGURIString(get(firstPage, sel));
            if (value.length > 0) return value;
        }
    }
    return nil;
}

id SGAutoMixCopyContext(id context) {
    if (!SGAutoMixEnabled() || ![context conformsToProtocol:@protocol(NSCopying)]
        || ![context respondsToSelector:NSSelectorFromString(@"metadata")]
        || ![context respondsToSelector:NSSelectorFromString(@"setMetadata:")]) return context;
    @try {
        NSString *uri = contextURI(context);
        if (!uri.length) return context;
        NSDictionary *patched = SGAutoMixContextMetadata(uri, get(context, @"metadata"));
        if (!patched) return context;
        id copy = [context copy];
        if (!copy || copy == context) return context;
        ((void (*)(id, SEL, id))objc_msgSend)(copy, NSSelectorFromString(@"setMetadata:"), [patched mutableCopy]);
        return copy;
    } @catch (NSException *exception) {
        SGLog(@"automix: context left unchanged: %@", exception.reason);
        return context;
    }
}

id SGAutoMixCopyRequest(id request, BOOL nested) {
    if (!SGAutoMixEnabled() || ![request conformsToProtocol:@protocol(NSCopying)]) return request;
    @try {
        id owner = nested ? get(request, @"preparePlayRequest") : request;
        id context = get(owner, @"context");
        id changed = SGAutoMixCopyContext(context);
        if (!context || changed == context) return request;
        id copy = [request copy];
        if (!copy || copy == request) return request;
        id copiedOwner = nested ? get(copy, @"preparePlayRequest") : copy;
        if (!copiedOwner || copiedOwner == owner || ![copiedOwner respondsToSelector:NSSelectorFromString(@"setContext:")]) return request;
        ((void (*)(id, SEL, id))objc_msgSend)(copiedOwner, NSSelectorFromString(@"setContext:"), changed);
        return copy;
    } @catch (NSException *exception) {
        SGLog(@"automix: request left unchanged: %@", exception.reason);
        return request;
    }
}
