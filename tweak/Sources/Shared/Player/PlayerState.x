// PlayerState.h names the hooks and why they are the ones.
#import "Core/SGCore.h"
#import "PlayerState.h"

NSString *SGURIString(id uri) {
    if ([uri isKindOfClass:NSString.class]) return uri;
    if ([uri isKindOfClass:NSURL.class]) return ((NSURL *)uri).absoluteString;
    return nil;
}

static NSHashTable<id<SGPlayerStateObserver>> *sg_stateObservers;
static SPTPlayerState *sg_playerState;
static __weak id<SPTPlayer> sg_playbackPlayer;
static NSString *sg_stateKey;
// Set once the now playing platform has reported; the mod's own observer on the player stands down.
static BOOL sg_platformReported = NO;

void SGAddPlayerStateObserver(id<SGPlayerStateObserver> observer) {
    if (!observer) return;
    if (!sg_stateObservers) sg_stateObservers = [NSHashTable weakObjectsHashTable];
    [sg_stateObservers addObject:observer];
}

SPTPlayerState *SGPlayerState(void) {
    return sg_playerState;
}

id<SPTPlayer> SGPlaybackPlayer(void) {
    return sg_playbackPlayer;
}

// What an observer is told about; the state object itself is new with every position report.
static NSString *transitionKey(SPTPlayerTrack *track) {
    NSDictionary *metadata = [track.metadata isKindOfClass:NSDictionary.class] ? track.metadata : nil;
    NSString *provider = [track respondsToSelector:@selector(provider)] && [track.provider isKindOfClass:NSString.class] ? track.provider : @"";
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:provider];
    for (NSString *key in @[@"automix.mode", @"automix.transition_uri", @"automix.auto_preset_id",
                            @"audio.fade_out_start_time", @"audio.fade_out_duration",
                            @"audio.fade_in_start_time", @"audio.fade_in_duration", @"audio.fade_overlap"]) {
        id value = metadata[key];
        [parts addObject:[value isKindOfClass:NSString.class] ? value
            : [value isKindOfClass:NSNumber.class] ? [value stringValue] : @""];
    }
    return [parts componentsJoinedByString:@"|"];
}

static NSString *keyOf(SPTPlayerState *state) {
    SPTPlayerOptions *options = [state respondsToSelector:@selector(options)] ? state.options : nil;
    BOOL shuffling = [options respondsToSelector:@selector(shufflingContext)] && options.shufflingContext;
    NSDictionary *metadata = [state.track.metadata isKindOfClass:NSDictionary.class] ? state.track.metadata : nil;
    NSString *canvas = [metadata[@"canvas.url"] isKindOfClass:NSString.class] ? metadata[@"canvas.url"] : @"";
    NSString *kind = [metadata[@"canvas.type"] isKindOfClass:NSString.class] ? metadata[@"canvas.type"] : @"";
    NSArray *future = [state respondsToSelector:@selector(future)] && [state.future isKindOfClass:NSArray.class] ? state.future : nil;
    SPTPlayerTrack *next = [future.firstObject isKindOfClass:NSClassFromString(@"SPTPlayerTrack")] ? future.firstObject : nil;
    return [NSString stringWithFormat:@"%@|%@|%d%d%d%d|%@|%@|%@|%@|%@", SGURIString(state.track.URI), SGURIString(state.contextURI),
            state.isPaused, state.isPlaying, [state respondsToSelector:@selector(isLoading)] && state.isLoading, shuffling,
            canvas, kind, transitionKey(state.track), SGURIString(next.URI), transitionKey(next)];
}

static void publish(SPTPlayerState *state) {
    sg_playerState = state;
    NSString *key = keyOf(state);
    if ([key isEqualToString:sg_stateKey]) return;
    sg_stateKey = key;
    for (id<SGPlayerStateObserver> observer in sg_stateObservers.allObjects) [observer playerStateDidChange:state];
}

static void report(id player, id state, BOOL platform) {
    if (![state isKindOfClass:objc_getClass("SPTPlayerState")]) return;
    dispatch_block_t apply = ^{
        if (platform) sg_platformReported = YES;
        else if (sg_platformReported) return;
        sg_playbackPlayer = player;
        publish(state);
    };
    if (NSThread.isMainThread) apply();
    else dispatch_async(dispatch_get_main_queue(), apply);
}

@interface SGPlayerObserver : NSObject
@end

@implementation SGPlayerObserver
- (void)player:(id)player stateDidChange:(id)state {
    report(player, state, NO);
}
@end

static SGPlayerObserver *sg_ownObserver;

%hook _TtC23NowPlaying_PlatformImpl28StatefulPlayerImplementation
- (void)player:(id)player stateDidChange:(id)state {
    %orig;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SGLog(@"player state: from %@, a %@, on the main thread %d", [player class], [state class], NSThread.isMainThread);
    });
    report(player, state, YES);
}
%end

%hook SPTEsperantoPlayer
- (void)addPlayerObserver:(id)observer {
    %orig;
    id player = self;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            sg_ownObserver = [SGPlayerObserver new];
            [(id<SPTPlayer>)player addPlayerObserver:sg_ownObserver];
            id state = [player respondsToSelector:@selector(state)] ? [(id<SPTPlayer>)player state] : nil;
            if (state) report(player, state, NO);
        });
    });
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"_TtC23NowPlaying_PlatformImpl28StatefulPlayerImplementation", @"SPTEsperantoPlayer", @"SPTPlayerState"]);
}
