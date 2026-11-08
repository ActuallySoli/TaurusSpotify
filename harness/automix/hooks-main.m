#import "Core/SGCore.h"
#import "Shared/AutoMix/AutoMix.h"
#import "Shared/Player/PlayerState.h"

static void check(BOOL value, NSString *message) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
void SGLogMessage(NSString *message) {}
void SGRequireClasses(NSArray *names) {}
void SGRegisterFlagForcer(BOOL beats, SGFlagForcer launch, SGFlagForcer locked) {}
void SGAddPlayerStateObserver(id observer) {}
SPTPlayerState *SGPlayerState(void) { return nil; }
id<SPTPlayer> SGPlaybackPlayer(void) { return nil; }
NSString *SGURIString(id uri) {
    return [uri isKindOfClass:NSString.class] ? uri : [uri isKindOfClass:NSURL.class] ? [uri absoluteString] : nil;
}

@interface HookTrack : NSObject
@property NSString *URI, *provider;
@property NSDictionary *metadata;
@end
@implementation HookTrack @end
@interface HookState : NSObject
@property NSString *contextURI;
@property HookTrack *track;
@property NSArray *future;
@end
@implementation HookState @end

@interface HookPreferences : NSObject
@property(nonatomic) BOOL audioAutomix, audioCrossfade;
@property(nonatomic) NSInteger audioCrossfadeTime;
@property NSUInteger writes, schedulerInitializations;
- (id)initWithScheduler:(id)scheduler;
@end
@implementation HookPreferences
- (instancetype)init { if ((self = [super init])) { _audioCrossfade = YES; _audioCrossfadeTime = 3000; } return self; }
- (id)initWithScheduler:(id)scheduler { self = [self init]; self.schedulerInitializations++; return self; }
- (void)setAudioAutomix:(BOOL)value { _audioAutomix = value; _writes++; }
- (void)setAudioCrossfade:(BOOL)value { _audioCrossfade = value; _writes++; }
- (void)setAudioCrossfadeTime:(NSInteger)value { _audioCrossfadeTime = value; _writes++; }
@end

#include "AutoMixHooks.m"

int main(void) {
    @autoreleasepool {
        NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
        for (NSString *key in store.dictionaryRepresentation) if ([key hasPrefix:@"spotifyglass."]) [store removeObjectForKey:key];
        check(SGAutoMixSupportedVersion([NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]), @"Fixture has a supported bundle version");
        SGSetEnabled(SGKeyAutoMix, YES);
        Class preferencesClass = objc_allocateClassPair(HookPreferences.class,
            "_TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation", 0);
        objc_registerClassPair(preferencesClass);
        SGTestInstallHooks();
        HookPreferences *preferences = [preferencesClass new];
        HookTrack *track = [HookTrack new]; track.URI = @"spotify:track:fixture"; track.metadata = @{};
        HookState *state = [HookState new]; state.contextURI = @"spotify:playlist:fixture"; state.track = track; state.future = @[];
        SGAutoMixPlayerStateChanged(state);
        check(!SGAutoMixApplyCurrentPlayback() && [SGAutoMixStatus() containsString:@"playback preferences"], @"Reproduce a live player whose preference initializer was not observed");
        NSInteger time = preferences.audioCrossfadeTime;
        check(time == 5000 && preferences.audioAutomix && SGAutoMixApplyCurrentPlayback(), @"The production getter hook captures existing preferences and applies AutoMix");
        check(preferences.schedulerInitializations == 0, @"Discovery does not depend on initWithScheduler:");
        NSUInteger writes = preferences.writes;
        for (NSUInteger i = 0; i < 1000; i++) {
            (void)preferences.audioCrossfadeTime; (void)preferences.audioAutomix; (void)preferences.audioCrossfade;
        }
        check(preferences.writes == writes, @"Getter hooks do not recurse or repeatedly rewrite settings");
        SGSetEnabled(SGKeyAutoMix, NO); SGAutoMixSettingsChanged();
        check(!preferences.audioAutomix && preferences.audioCrossfade && preferences.audioCrossfadeTime == 3000, @"Original preferences restore after getter discovery");
        HookPreferences *replacement = [preferencesClass new];
        replacement.audioCrossfadeTime = 7000;
        SGSetEnabled(SGKeyAutoMix, YES); SGAutoMixSettingsChanged();
        check(replacement.audioCrossfadeTime == 5000, @"A replacement preference object is discovered through its setter");
        SGSetEnabled(SGKeyAutoMix, NO); SGAutoMixSettingsChanged();
        check(replacement.audioCrossfadeTime == 7000, @"Replacement restores its own original value");
        puts("PASS: production AutoMix hooks discover preferences without initWithScheduler; no getter recursion/repeated writes; replacement discovery and restoration");
    }
    return 0;
}
