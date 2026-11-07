#import "Core/SGCore.h"
#import "AutoMix.h"
#import "Shared/Player/PlayerState.h"

@interface SGAutoMixWatch : NSObject <SGPlayerStateObserver>
@end
@implementation SGAutoMixWatch
- (void)playerStateDidChange:(SPTPlayerState *)state {
    SGAutoMixPlayerStateChanged(state);
}
@end

%hook SPTEsperantoPlayer
- (void)addPlayerObserver:(id)observer {
    %orig;
    SGAutoMixPlayerAvailable(self);
}
- (id)playContext:(id)context options:(id)options loggingParams:(id)logging origin:(id)origin {
    SGAutoMixPlayerAvailable(self);
    return %orig(SGAutoMixCopyContext(context), options, logging, origin);
}
- (id)executePlayCommand:(id)context options:(id)options loggingParams:(id)logging origin:(id)origin {
    SGAutoMixPlayerAvailable(self);
    return %orig(SGAutoMixCopyContext(context), options, logging, origin);
}
- (id)preparePlaybackOfContext:(id)context options:(id)options viewURI:(id)uri playOrigin:(id)origin {
    return %orig(SGAutoMixCopyContext(context), options, uri, origin);
}
- (id)preparePlaybackOfContext:(id)context options:(id)options viewURI:(id)uri {
    return %orig(SGAutoMixCopyContext(context), options, uri);
}
- (id)updateWithContext:(id)context {
    return %orig(SGAutoMixCopyContext(context));
}
%end

%hook ESPContextPlayerClientImpl
- (id)play:(id)request onResponse:(id)response {
    return %orig(SGAutoMixCopyRequest(request, YES), response);
}
- (id)preparePlay:(id)request onResponse:(id)response {
    return %orig(SGAutoMixCopyRequest(request, NO), response);
}
- (id)updateContext:(id)request onResponse:(id)response {
    return %orig(SGAutoMixCopyRequest(request, NO), response);
}
%end

%hook _TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation
- (id)initWithScheduler:(id)scheduler {
    id preferences = %orig;
    SGAutoMixPreferencesAvailable(preferences);
    return preferences;
}
- (BOOL)audioAutomix {
    SGAutoMixPreferencesAvailable(self);
    return %orig;
}
- (BOOL)audioCrossfade {
    SGAutoMixPreferencesAvailable(self);
    return %orig;
}
- (NSInteger)audioCrossfadeTime {
    SGAutoMixPreferencesAvailable(self);
    return %orig;
}
- (void)setAudioAutomix:(BOOL)value {
    SGAutoMixPreferenceChanged(self, @"automix", @(value));
    %orig;
    SGAutoMixPreferencesAvailable(self);
}
- (void)setAudioCrossfade:(BOOL)value {
    SGAutoMixPreferenceChanged(self, @"crossfade", @(value));
    %orig;
    SGAutoMixPreferencesAvailable(self);
}
- (void)setAudioCrossfadeTime:(NSInteger)value {
    SGAutoMixPreferenceChanged(self, @"time", @(value));
    %orig;
    SGAutoMixPreferencesAvailable(self);
}
%end

%hook SPTRemoteConfigCoreImpl
- (BOOL)setConfigurationProto:(id)configuration bootstrap:(BOOL)bootstrap {
    return %orig(SGAutoMixConfiguration(configuration), bootstrap);
}
%end

%ctor {
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (!SGAutoMixSupportedVersion(version)) return;
    if (SGAutoMixEnabled()) {
        SGFlagForcer force = ^id(NSString *key) {
            return [@[@"ios-feature-settings.automix_enabled", @"ios-feature-settings.crossfade_enabled"] containsObject:key] ? @YES : nil;
        };
        SGRegisterFlagForcer(YES, force, force);
    }
    %init;
    static SGAutoMixWatch *watch;
    watch = [SGAutoMixWatch new];
    SGAddPlayerStateObserver(watch);
    SGRequireClasses(@[@"SPTEsperantoPlayer", @"SPTPlayerContext", @"ESPContextPlayerClientImpl", @"ESPContext", @"SPTRemoteConfigCoreImpl",
        @"_TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation"]);
}
