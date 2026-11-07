#import "../../tweak/Sources/Shared/Ambient/AmbientEngine.m"

static SPTPlayerState *player;
static id<SGPlayerStateObserver> watcher;
static BOOL podcastPause = YES;
static int failures;
#define CHECK(ok, label) do { BOOL value = (ok); printf("%s %s\n", value ? "PASS" : "FAIL", label); if (!value) failures++; } while (0)
@implementation SPTPlayerTrack
@end
@implementation SPTPlayerState
@end
BOOL SGFlag(NSString *key, BOOL fallback) { return [key isEqual:SGKeyAmbientPodcastPause] ? podcastPause : fallback; }
NSString *SGURIString(id uri) { return [uri isKindOfClass:NSString.class] ? uri : nil; }
SPTPlayerState *SGPlayerState(void) { return player; }
void SGAddPlayerStateObserver(id<SGPlayerStateObserver> observer) { watcher = observer; }
@implementation AVAudioFormat
- (instancetype)initStandardFormatWithSampleRate:(double)rate channels:(UInt32)channels { return [super init]; }
@end
@implementation AVAudioSourceNode
- (instancetype)initWithFormat:(AVAudioFormat *)format renderBlock:(SGTestRender)block {
    if ((self = [super init])) _render = [block copy];
    return self;
}
@end
@implementation AVAudioEngine
- (id)mainMixerNode { return self; }
- (void)attachNode:(id)node {}
- (void)connect:(id)node to:(id)mixer format:(AVAudioFormat *)format {}
- (BOOL)startAndReturnError:(NSError **)error { self.isRunning = !AVAudioSession.sharedInstance.failEngine; return self.isRunning; }
- (void)stop { self.isRunning = NO; }
@end
@implementation AVAudioSession
+ (instancetype)sharedInstance {
    static AVAudioSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ session = [self new]; session.category = @"ambient"; });
    return session;
}
- (BOOL)setCategory:(NSString *)category withOptions:(NSUInteger)options error:(NSError **)error {
    if (self.failCategory) return NO;
    self.category = category;
    return YES;
}
- (BOOL)setActive:(BOOL)active error:(NSError **)error { return [self setActive:active withOptions:0 error:error]; }
- (BOOL)setActive:(BOOL)active withOptions:(NSUInteger)options error:(NSError **)error {
    // Same production policy used by both AVAudioSession hooks.
    if (SGAmbientDeferSessionDeactivation(active, options)) return YES;
    if (active && self.failActivation) return NO;
    self.active = active;
    if (!active) { self.deactivations++; self.lastOptions = options; [sg_audioEngine stop]; }
    return YES;
}
@end

static BOOL audible(void) {
    if (!sg_audioEngine.isRunning || !AVAudioSession.sharedInstance.active) return NO;
    float left[2048] = {0}, right[2048] = {0};
    struct { UInt32 count; AudioBuffer buffers[2]; } list = {2, {{1, sizeof(left), left}, {1, sizeof(right), right}}};
    BOOL silent = YES;
    sg_sourceNode.render(&silent, NULL, 2048, (AudioBufferList *)&list);
    double energy = 0;
    for (int i = 0; i < 2048; i++) energy += fabs(left[i]) + fabs(right[i]);
    return !silent && energy > 0.01;
}
static void drain(void) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:0.02];
    while ([until timeIntervalSinceNow] > 0) [[NSRunLoop mainRunLoop] runUntilDate:until];
}
static void interrupt(BOOL began, BOOL resume) {
    [NSNotificationCenter.defaultCenter postNotificationName:AVAudioSessionInterruptionNotification object:nil
        userInfo:@{AVAudioSessionInterruptionTypeKey: @(began ? 1 : 0), AVAudioSessionInterruptionOptionKey: @(resume ? 1 : 0)}];
    drain();
}
int main(void) {
    @autoreleasepool {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyAmbientState];
        player = [SPTPlayerState new]; player.track = [SPTPlayerTrack new]; player.track.URI = @"spotify:track:test"; player.isPaused = YES;
        drain();
        AVAudioSession *session = AVAudioSession.sharedInstance;
        SGAmbientSetPlaying(YES);
        CHECK(SGAmbientIsPlaying() && audible(), "Ambient starts audibly with Spotify paused");
        player.isPaused = NO; [watcher playerStateDidChange:player];
        CHECK(audible(), "Ambient continues while a song plays");
        player.isPaused = YES; [watcher playerStateDidChange:player];
        NSUInteger previous = session.deactivations;
        [session setActive:NO withOptions:7 error:nil];
        CHECK(session.deactivations == previous && audible() && SGAmbientIsPlaying(), "Spotify pause cannot deactivate Ambient's audio session");
        [sg_audioEngine stop];
        drain();
        CHECK(SGAmbientIsPlaying() && audible(), "delayed AudioUnit teardown after Spotify pause automatically restarts Ambient");
        SGAmbientSetPlaying(NO);
        CHECK(!SGAmbientIsPlaying() && !SGAmbientIsEnabled() && !sg_audioEngine.isRunning, "Stop actually stops the engine and clears UI state");
        CHECK(session.deactivations == previous + 1 && session.lastOptions == 7, "deferred deactivation is released with its original options");
        SGAmbientSetPlaying(YES); player.isPaused = NO; [watcher playerStateDidChange:player];
        SGAmbientSetPlaying(NO);
        CHECK(session.active, "stopping Ambient does not deactivate a playing Spotify song");
        player.isPaused = YES;
        SGAmbientSetPlaying(YES); SGAmbientSetPlaying(NO);
        CHECK(!session.active, "standalone Ambient releases its audio session on Stop");
        SGAmbientSetPlaying(YES); interrupt(YES, NO);
        CHECK(!SGAmbientIsPlaying() && SGAmbientIsEnabled() && [SGAmbientSummary() isEqual:@"Interrupted"], "system interruption reports suspended playback, retaining intent");
        CHECK(!SGAmbientDeferSessionDeactivation(NO, 0), "system interruptions are not held off");
        interrupt(NO, YES);
        CHECK(SGAmbientIsPlaying() && audible(), "Ambient resumes after a resumable interruption");
        interrupt(YES, NO); SGAmbientSetPlaying(NO); interrupt(NO, YES);
        CHECK(!SGAmbientIsEnabled() && !audible(), "Stop during an interruption prevents a later restart");
        SGAmbientSetPlaying(YES); interrupt(YES, NO); interrupt(NO, NO);
        CHECK(!SGAmbientIsEnabled() && !SGAmbientIsPlaying(), "non-resumable interruption does not restart audio");
        SGAmbientSetPlaying(YES); player.track.URI = @"spotify:episode:test"; player.isPaused = NO; [watcher playerStateDidChange:player];
        CHECK(!SGAmbientIsPlaying() && SGAmbientIsEnabled() && [SGAmbientSummary() isEqual:@"Paused for podcast"], "podcast pause has an honest UI status");
        player.isPaused = YES; [watcher playerStateDidChange:player];
        CHECK(SGAmbientIsPlaying() && audible(), "pausing the podcast restores Ambient");
        [sg_audioEngine stop];
        [NSNotificationCenter.defaultCenter postNotificationName:AVAudioEngineConfigurationChangeNotification object:sg_audioEngine]; drain();
        CHECK(SGAmbientIsPlaying() && audible(), "stopped engine restarts after route configuration changes");
        AVAudioEngine *old = sg_audioEngine;
        [NSNotificationCenter.defaultCenter postNotificationName:AVAudioSessionMediaServicesWereResetNotification object:nil]; drain();
        CHECK(old != sg_audioEngine && SGAmbientIsPlaying() && audible(), "media services reset rebuilds the engine");
        SGAmbientSetPlaying(NO); session.failActivation = YES; SGAmbientSetPlaying(YES);
        CHECK(!SGAmbientIsPlaying() && !SGAmbientIsEnabled() && [SGAmbientSummary() containsString:@"Unable"], "activation failure never leaves a false Playing state");
        session.failActivation = NO; session.failEngine = YES; SGAmbientSetPlaying(YES);
        CHECK(!SGAmbientIsPlaying() && !SGAmbientIsEnabled(), "engine startup failure clears intent and playback state");
        CHECK(!session.active, "engine startup failure releases its successfully activated session");
        session.failEngine = NO; session.category = AVAudioSessionCategoryPlayAndRecord; SGAmbientSetPlaying(YES);
        CHECK([session.category isEqual:AVAudioSessionCategoryPlayAndRecord] && audible(), "existing recording-capable session category is preserved");
        SGAmbientStartSleepFade(0);
        CHECK(!SGAmbientIsEnabled() && !sg_audioEngine.isRunning, "explicit sleep stop still shuts Ambient down");
        dispatch_apply(1000, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
            if (i & 1) SGAmbientDeferSessionDeactivation(NO, i);
            else { keepSession(YES); keepSession(NO); }
        });
        keepSession(NO);
        CHECK(!SGAmbientDeferSessionDeactivation(NO, 9), "Stop wins over concurrent session-deactivation requests");
        atomic_store(&sg_sessionState, 0);
    }
    return failures ? 1 : 0;
}
