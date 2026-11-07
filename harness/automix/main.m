#import <Foundation/Foundation.h>
#import "Core/SGPrefs.h"
#import "Shared/AutoMix/AutoMix.h"
#import "Shared/AdBlock/Protobuf.h"
#import "Headers/SPTPlayer.h"

static void check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
void SGLogMessage(NSString *message) {}
NSString *SGURIString(id uri) {
    return [uri isKindOfClass:NSString.class] ? uri : [uri isKindOfClass:NSURL.class] ? [uri absoluteString] : nil;
}
static id sg_reportedState;
SPTPlayerState *SGPlayerState(void) { return (SPTPlayerState *)sg_reportedState; }
static id sg_fixturePlaybackPlayer;
id<SPTPlayer> SGPlaybackPlayer(void) { return sg_fixturePlaybackPlayer; }

@interface FixtureContext : NSObject <NSCopying>
@property id URI;
@property NSDictionary *metadata;
@end
@implementation FixtureContext
- (id)copyWithZone:(NSZone *)zone {
    FixtureContext *copy = [FixtureContext new]; copy.URI = self.URI; copy.metadata = self.metadata; return copy;
}
@end
@interface FixtureProtoContext : NSObject <NSCopying>
@property NSString *uri;
@property NSString *url;
@property NSMutableDictionary *metadata;
@end
@implementation FixtureProtoContext
- (id)copyWithZone:(NSZone *)zone {
    FixtureProtoContext *copy = [FixtureProtoContext new];
    copy.uri = self.uri;
    copy.url = self.url;
    copy.metadata = [self.metadata mutableCopy];
    return copy;
}
@end
@interface FixtureRequest : NSObject <NSCopying>
@property id context;
@property FixtureRequest *preparePlayRequest;
@property BOOL shallow;
@end
@implementation FixtureRequest
- (id)copyWithZone:(NSZone *)zone {
    FixtureRequest *copy = [FixtureRequest new]; copy.context = self.context;
    copy.preparePlayRequest = self.shallow ? self.preparePlayRequest : [self.preparePlayRequest copy];
    return copy;
}
@end
@interface FixtureTrack : NSObject
@property id URI;
@property NSString *provider;
@property NSString *trackTitle;
@property NSDictionary *metadata;
@end
@implementation FixtureTrack @end
@interface FixtureState : NSObject
@property id contextURI;
@property FixtureTrack *track;
@property NSArray *future;
@property double duration;
@end
@implementation FixtureState @end
@interface FixturePlayer : NSObject
@property FixtureState *state;
@property NSUInteger seeks;
@property double lastSeek;
- (id)seekTo:(double)seconds;
@end
@implementation FixturePlayer
- (id)seekTo:(double)seconds { self.seeks++; self.lastSeek = seconds; return nil; }
@end
@interface FixturePreferences : NSObject
@property (nonatomic) BOOL audioAutomix, audioCrossfade;
@property (nonatomic) NSInteger audioCrossfadeTime;
@property NSUInteger writes;
@end
@implementation FixturePreferences
- (void)setAudioAutomix:(BOOL)value {
    SGAutoMixPreferenceChanged(self, @"automix", @(value)); _audioAutomix = value; _writes++;
}
- (void)setAudioCrossfade:(BOOL)value {
    SGAutoMixPreferenceChanged(self, @"crossfade", @(value)); _audioCrossfade = value; _writes++;
}
- (void)setAudioCrossfadeTime:(NSInteger)value {
    SGAutoMixPreferenceChanged(self, @"time", @(value)); _audioCrossfadeTime = value; _writes++;
}
@end

static SGPBField *property(NSString *component, NSString *name, BOOL value) {
    return SGPBBytes(3, SGPBSerialize(@[
        SGPBBytes(1, SGPBSerialize(@[SGPBString(1, component), SGPBString(2, name)])),
        SGPBBytes(3, SGPBSerialize(@[SGPBVarint(1, value)])),
        SGPBString(9, @"keep"),
    ]));
}

static NSDictionary *configurationValues(NSData *configuration) {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (SGPBField *field in SGPBParse(configuration)) {
        if (field.number != 3) continue;
        NSArray *value = SGPBParse(field.payload), *identifier = SGPBParse(SGPBFirst(value, 1).payload);
        NSString *component = SGPBText(SGPBFirst(identifier, 1));
        if (component) values[component] = @(SGPBFirst(SGPBParse(SGPBFirst(value, 3).payload), 1).varint != 0);
    }
    return values;
}

int main(void) {
    @autoreleasepool {
        NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
        for (NSString *key in store.dictionaryRepresentation) if ([key hasPrefix:@"spotifyglass."]) [store removeObjectForKey:key];
        check(!SGAutoMixEnabled(), @"AutoMix is opt-in");
        check(SGAutoMixSupportedVersion(@"9.1.90") && SGAutoMixSupportedVersion(@"9.1.94") && !SGAutoMixSupportedVersion(@"9.1.95"), @"Only verified Spotify versions install hooks");
        SGSetEnabled(SGKeyAutoMix, YES);
        for (NSString *uri in @[@"spotify:playlist:test", @"context://spotify:playlist:test", @"spotify:user:test:playlist:one", @"spotify:album:test", @"spotify:artist:test", @"spotify:station:track:test", @"spotify:collection:tracks"])
            check(SGAutoMixContextAllowed(uri), [@"Supported music context " stringByAppendingString:uri]);
        for (NSString *uri in @[@"spotify:show:test", @"context://spotify:show:test", @"spotify:episode:test", @"spotify:collection:your-episodes", @"spotify:audiobook:test", @"https://example.com", @"spotify:track:test"])
            check(!SGAutoMixContextAllowed(uri), [@"Excluded context " stringByAppendingString:uri]);
        SGSetEnabled(SGKeyAutoMixAlbums, NO);
        check(!SGAutoMixContextAllowed(@"spotify:album:test"), @"Context setting is respected");
        SGSetEnabled(SGKeyAutoMixAlbums, YES);
        check(!SGAutoMixTrackAllowed(@"spotify:episode:test", nil) && !SGAutoMixTrackAllowed(@"spotify:ad:test", nil), @"No spoken content or ads");
        SGSetEnabled(SGKeyAutoMixQueue, NO);
        check(!SGAutoMixTrackAllowed(@"spotify:track:test", @"queue"), @"Queue setting respected");
        SGSetEnabled(SGKeyAutoMixQueue, YES);
        SGSetEnabled(SGKeyAutoMixAutoplay, NO);
        check(!SGAutoMixTrackAllowed(@"spotify:track:test", @"autoplay"), @"Autoplay setting respected");
        SGSetEnabled(SGKeyAutoMixAutoplay, YES);
        SGSetInt(SGKeyAutoMixLength, 999); check(SGAutoMixBlendSeconds() == 12, @"Upper duration bound");
        SGSetInt(SGKeyAutoMixLength, -1); check(SGAutoMixBlendSeconds() == 1, @"Lower duration bound");
        SGSetInt(SGKeyAutoMixLength, 5);

        NSDictionary *original = @{@"unrelated": @"unchanged"};
        NSDictionary *patched = SGAutoMixContextMetadata(@"spotify:playlist:test", original);
        check([patched[@"automix.mode"] isEqual:@"regular"] && [patched[@"automix.ignore_setting"] isEqual:@"true"], @"Native AutoMix metadata uses regular S-curve planner for general music contexts");
        check(!original[@"automix.mode"] && [patched[@"unrelated"] isEqual:@"unchanged"], @"Preserve caller metadata");
        check(!SGAutoMixContextMetadata(@"spotify:playlist:test", @{@"automix.mode": @"manual"}), @"Preserve explicit native mixing mode");
        check(!SGAutoMixContextMetadata(@"spotify:show:test", original), @"Do not patch podcast contexts");
        FixtureContext *context = [FixtureContext new]; context.URI = [NSURL URLWithString:@"spotify:playlist:test"]; context.metadata = original;
        FixtureContext *copy = SGAutoMixCopyContext(context);
        check(copy != context && [copy.metadata[@"automix.mode"] isEqual:@"regular"] && !context.metadata[@"automix.mode"], @"Copy context instead of mutating Spotify's shared object");
        FixtureProtoContext *proto = [FixtureProtoContext new]; proto.uri = @"spotify:album:test"; proto.metadata = [original mutableCopy];
        FixtureRequest *prepare = [FixtureRequest new]; prepare.context = proto;
        FixtureRequest *changedPrepare = SGAutoMixCopyRequest(prepare, NO);
        check(changedPrepare != prepare && [changedPrepare.context metadata][@"automix.mode"] && !proto.metadata[@"automix.mode"], @"Direct Esperanto prepare/update request copies");
        FixtureProtoContext *urlProto = [FixtureProtoContext new]; urlProto.uri = @""; urlProto.url = @"context://spotify:playlist:test"; urlProto.metadata = [original mutableCopy];
        FixtureProtoContext *copiedUrlProto = SGAutoMixCopyContext(urlProto);
        check(copiedUrlProto != urlProto && [copiedUrlProto.metadata[@"automix.mode"] isEqual:@"regular"] && !urlProto.metadata[@"automix.mode"], @"ESPContext with empty uri and context:// url is patched");
        FixtureRequest *play = [FixtureRequest new]; play.preparePlayRequest = prepare;
        FixtureRequest *changedPlay = SGAutoMixCopyRequest(play, YES);
        check(changedPlay != play && [changedPlay.preparePlayRequest.context metadata][@"automix.mode"] && !proto.metadata[@"automix.mode"], @"Nested Esperanto play request copy");
        play.shallow = YES;
        check(SGAutoMixCopyRequest(play, YES) == play && !proto.metadata[@"automix.mode"], @"Shallow nested copies cannot mutate a shared request");
        SGSetInt(SGKeyAutoMixStyle, 1);
        check(SGAutoMixCopyContext(context) == context, @"Crossfade leaves native context metadata alone");
        SGSetInt(SGKeyAutoMixStyle, 0);
        check(SGAutoMixHasTransition(@{@"automix.transition_uri": @"spotify:transition:test"}), @"Transition URI detected");
        check(SGAutoMixHasTransition(@{@"audio.fade_out_start_time": @"0"}), @"Zero-time outgoing plan is valid");
        check(SGAutoMixHasTransition(@{@"audio.fade_out_duration": @"8000"}) && SGAutoMixHasTransition(@{@"audio.fade_overlap": @"5000"}), @"Positive fade duration/overlap detected");
        check(!SGAutoMixHasTransition(@{@"audio.fade_out_start_time": @"nonsense"}) && !SGAutoMixHasTransition(@{@"audio.fade_out_start_time": @(-1)}), @"Malformed outgoing plans ignored");
        check(!SGAutoMixHasTransition(@{@"audio.fade_in_start_time": @"2"}), @"Incoming plan does not prove an outgoing transition");

        NSData *config = SGPBSerialize(@[SGPBString(11, @"untouched"), property(@"core-automix", @"automix_enabled", NO), property(@"unrelated", @"property", NO)]);
        NSData *changed = SGAutoMixConfiguration(config);
        NSDictionary *values = configurationValues(changed);
        check([values[@"core-automix"] boolValue] && [values[@"core-playback-setup"] boolValue], @"Enable player core, including missing fields");
        check(![values[@"unrelated"] boolValue] && [SGPBText(SGPBFirst(SGPBParse(changed), 11)) isEqual:@"untouched"], @"Keep unrelated core configuration");
        check([SGAutoMixConfiguration(changed) isEqual:changed], @"Configuration patch is idempotent");
        NSData *malformed = [NSData dataWithBytes:"\xff" length:1];
        check([SGAutoMixConfiguration(malformed) isEqual:malformed], @"Malformed config passes through");

        FixturePreferences *preferences = [FixturePreferences new];
        preferences.audioAutomix = NO; preferences.audioCrossfade = YES; preferences.audioCrossfadeTime = 3000;
        NSUInteger initialWrites = preferences.writes;
        SGAutoMixPreferencesAvailable(preferences);
        check(preferences.writes == initialWrites, @"No writes without playback state");
        FixtureState *state = [FixtureState new]; state.contextURI = @"spotify:playlist:test";
        state.track = [FixtureTrack new]; state.track.URI = @"spotify:track:current"; state.track.metadata = @{};
        FixtureTrack *next = [FixtureTrack new]; next.URI = @"spotify:track:next"; next.trackTitle = @"Next Song"; state.future = @[next];
        SGAutoMixPlayerStateChanged(state);
        check(SGAutoMixLastTransition() == nil, @"Initial playback is not presented as an observed transition");
        check(preferences.audioAutomix && preferences.audioCrossfade && preferences.audioCrossfadeTime == 5000, @"Smart blend enables native AutoMix with milliseconds fallback");
        FixturePlayer *player = [FixturePlayer new]; player.state = state; state.duration = 200;
        sg_fixturePlaybackPlayer = player;
        check(SGAutoMixApplyCurrentPlayback() && player.seeks == 0, @"Apply is immediate without moving playback");
        check(SGAutoMixPreviewTransition() && player.seeks == 1 && player.lastSeek == 185, @"Explicit preview seeks to the last 15 seconds");
        state.duration = 10;
        check(!SGAutoMixPreviewTransition() && player.seeks == 1, @"Short songs cannot seek outside their length");
        state.duration = 200; state.future = @[];
        check(!SGAutoMixPreviewTransition() && player.seeks == 1, @"A preview needs a following song");
        state.future = @[next];
        NSUInteger appliedWrites = preferences.writes;
        for (NSUInteger i = 0; i < 1000; i++) SGAutoMixPlayerStateChanged(state);
        check(preferences.writes == appliedWrites, @"Repeated reports settle without writes or notification loops");
        state.track.metadata = @{@"audio.fade_out_start_time": @"123000", @"audio.fade_out_duration": @"5000",
                                 @"automix.transition_uri": @"spotify:track:next"};
        SGAutoMixPlayerStateChanged(state);
        check(preferences.audioAutomix && !preferences.audioCrossfade && preferences.audioCrossfadeTime == 0, @"Native transition plan disables competing fallback");
        check([SGAutoMixTransitionDetails() containsString:@"audio.fade_out_start_time: 123000"], @"Diagnostics show actual supplied metadata");
        double ws = 0, we = 0; NSString *wNext = nil;
        check(SGAutoMixMixWindow(&ws, &we, &wNext) && fabs(ws - 123) < 1e-3 && fabs(we - 128) < 1e-3 && [wNext isEqual:@"Next Song"],
              @"The pill's window: Spotify's millisecond fades lower to seconds with the incoming title");
        check(SGAutoMixMixWindow(nil, nil, nil), @"Window answers NULL destinations without touching memory");
        state.track.metadata = @{@"audio.fade_out_start_time": @"100.0", @"audio.fade_out_duration": @"10.0"};
        SGAutoMixPlayerStateChanged(state);
        check(SGAutoMixMixWindow(&ws, &we, nil) && fabs(ws - 100) < 1e-3 && fabs(we - 110) < 1e-3, @"Second-valued fades ride along unchanged");
        state.track.metadata = @{@"audio.fade_out_start_time": @"100000", @"audio.fade_out_duration": @"1000"};
        SGAutoMixPlayerStateChanged(state);
        check(SGAutoMixMixWindow(&ws, &we, nil) && fabs(ws - 100) < 1e-3 && fabs(we - 101) < 1e-3,
              @"A short fade takes the plan's unit, not its own scale");
        state.track.metadata = @{@"audio.fade_out_start_time": @"0", @"audio.fade_out_duration": @"5"};
        SGAutoMixPlayerStateChanged(state);
        check(SGAutoMixMixWindow(&ws, &we, nil) && fabs(ws) < 1e-3 && fabs(we - 5) < 1e-3,
              @"A plan that starts at zero still names its window");
        state.track.metadata = @{@"media.stop_position": @"180000", @"audio.fade_out_duration": @"8000"};
        SGAutoMixPlayerStateChanged(state);
        check(SGAutoMixMixWindow(&ws, &we, nil) && fabs(ws - 172) < 1e-3 && fabs(we - 180) < 1e-3,
              @"A plan with stop_position and fade_out_duration computes its window");
        for (id bad in @[@"garbage", @"1oops", NSNull.null]) {
            state.track.metadata = @{@"automix.transition_uri": @"spotify:track:next",
                @"audio.fade_out_start_time": bad, @"audio.fade_out_duration": @"5"};
            SGAutoMixPlayerStateChanged(state);
            check(!SGAutoMixMixWindow(nil, nil, nil), @"Malformed plan starts cannot fabricate a window at zero");
        }
        state.track.metadata = @{};
        SGAutoMixPlayerStateChanged(state);
        check(SGAutoMixMixWindow(&ws, &we, &wNext) && fabs(ws - 195) < 1e-3 && fabs(we - 200) < 1e-3 && [wNext isEqual:@"Next Song"],
              @"Smart blend without a plan shows the same fallback crossfade playback applies");
        FixtureTrack *third = [FixtureTrack new]; third.URI = @"spotify:track:third"; third.trackTitle = @"Third Song";
        FixtureState *fresh = [FixtureState new];
        fresh.contextURI = state.contextURI; fresh.track = state.track; fresh.future = @[third]; fresh.duration = 100;
        sg_reportedState = fresh;
        check(SGAutoMixMixWindow(&ws, &we, &wNext) && fabs(ws - 95) < 1e-3 && fabs(we - 100) < 1e-3 && [wNext isEqual:@"Third Song"],
              @"The window follows the newest player report: a queue edit retitles it and a new length moves it without a track change");
        fresh.duration = 3; fresh.future = @[];
        check(!SGAutoMixMixWindow(nil, nil, nil), @"A skip to a short song leaves no stale window from the previous song's stored state");
        sg_reportedState = nil;
        check(SGAutoMixMixWindow(&ws, &we, &wNext) && fabs(ws - 195) < 1e-3 && fabs(we - 200) < 1e-3 && [wNext isEqual:@"Next Song"],
              @"Without a newer report the window falls back to the stored player state");
        SGSetInt(SGKeyAutoMixStyle, 1); SGAutoMixSettingsChanged();
        state.track.metadata = @{@"audio.fade_out_start_time": @"100.0", @"audio.fade_out_duration": @"10.0"};
        SGAutoMixPlayerStateChanged(state);
        check(SGAutoMixMixWindow(&ws, &we, nil) && fabs(ws - 195) < 1e-3 && fabs(we - 200) < 1e-3,
              @"Explicit crossfade uses its own window even when Spotify supplies a plan");
        SGSetInt(SGKeyAutoMixStyle, 0); SGAutoMixSettingsChanged();
        state.duration = 0;
        state.track.metadata = @{};
        SGAutoMixPlayerStateChanged(state);
        ws = 42; we = 43; wNext = @"sentinel";
        check(!SGAutoMixMixWindow(&ws, &we, &wNext) && ws == 42 && we == 43 && [wNext isEqual:@"sentinel"],
              @"No window leaves the caller's outputs untouched");
        state.duration = 200;
        SGAutoMixPlayerStateChanged(state);
        check(preferences.audioCrossfade && preferences.audioCrossfadeTime == 5000, @"Missing plan restores fallback on next report");
        next.provider = @"queue"; SGSetEnabled(SGKeyAutoMixQueue, NO); SGAutoMixSettingsChanged();
        check(!preferences.audioAutomix && preferences.audioCrossfade && preferences.audioCrossfadeTime == 3000, @"Excluded queue item restores original preferences");
        next.provider = nil; SGSetEnabled(SGKeyAutoMixQueue, YES); SGAutoMixSettingsChanged();
        SGSetInt(SGKeyAutoMixStyle, 1); SGAutoMixSettingsChanged();
        check(!preferences.audioAutomix && preferences.audioCrossfade && preferences.audioCrossfadeTime == 5000, @"Explicit crossfade disables native AutoMix");
        preferences.audioCrossfadeTime = 8000;
        SGSetEnabled(SGKeyAutoMix, NO); SGAutoMixSettingsChanged();
        check(!preferences.audioAutomix && preferences.audioCrossfade && preferences.audioCrossfadeTime == 8000, @"Restore deliberate user edits rather than stale native settings");
        check([SGAutoMixConfiguration(config) isEqual:config] && SGAutoMixCopyContext(context) == context, @"Disabled feature is transparent");
        SGSetEnabled(SGKeyAutoMix, YES); SGAutoMixSettingsChanged(); SGAutoMixRestorePreferences();
        check(preferences.audioCrossfadeTime == 8000 && ![store objectForKey:@"spotifyglass.automix.savedPreferences"], @"Restore before reset/import");
        puts("PASS: AutoMix contexts, copy semantics, native metadata preservation, core configuration, transition detection, fallback, native preference restoration, no repeated writes and actual metadata diagnostics");
    }
    return 0;
}
