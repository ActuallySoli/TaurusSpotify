#import <AudioToolbox/AudioToolbox.h>
#import <signal.h>
#import "Shared/Audio/SGAudioPipeline.h"
#import "../../tweak/Sources/Shared/Jam/WebJam.m"

static const SGAudioProcessor *audioProcessor;
static NSString *fakeURI, *fakeTitle, *fakeContext;
static BOOL fakePaused;
static double fakePosition = 42, fakeStarted;
static volatile sig_atomic_t quitting;
static void interrupted(int signal) { quitting = 1; }
void SGLogMessage(NSString *message) { fprintf(stderr, "%s\n", message.UTF8String); }
void SGLocalJamRuntimeStart(void) {}
void SGLocalJamRuntimeStopIfUnused(void) {}
void SGAddPlayerStateObserver(id<SGPlayerStateObserver> observer) {}
NSString *SGURIString(id value) { return [value isKindOfClass:NSString.class] ? value : [value isKindOfClass:NSURL.class] ? [value absoluteString] : nil; }
bool SGAudioPipelineRegister(SGAudioStage stage, const SGAudioProcessor *processor) { audioProcessor = processor; return true; }
OSStatus AudioUnitGetProperty(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element, void *data, UInt32 *size) {
    AudioStreamBasicDescription format = {48000, kAudioFormatLinearPCM,
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked, 4, 1, 4, 2, 32, 0};
    memcpy(data, &format, sizeof format); return noErr;
}
@implementation UIDevice
+ (instancetype)currentDevice { static UIDevice *device; if (!device) device = [UIDevice new]; return device; }
- (NSString *)name { return @"Test host"; }
@end
@implementation SPTPlayerTrack
- (id)URI { return fakeURI; }
- (NSString *)trackTitle { return fakeTitle; }
- (NSString *)artistName { return @"The listening room"; }
- (id)artistURI { return nil; }
- (NSString *)provider { return @"context"; }
- (NSDictionary *)metadata { return @{@"image_url": @"https://i.scdn.co/image/0123456789abcdef0123456789abcdef"}; }
@end
@implementation SPTPlayerState
- (SPTPlayerTrack *)track { static SPTPlayerTrack *track; if (!track) track = [SPTPlayerTrack new]; return track; }
- (id)contextURI { return fakeContext; }
- (SPTPlayerOptions *)options { return nil; }
- (SPTSleepTimer *)sleepTimer { return nil; }
- (BOOL)isPlaying { return !fakePaused; }
- (BOOL)isPaused { return fakePaused; }
- (BOOL)isLoading { return NO; }
- (double)position { return fakePosition + (fakePaused ? 0 : NSDate.timeIntervalSinceReferenceDate - fakeStarted); }
- (double)positionAsOfTimestamp { return fakePosition; }
- (double)duration { return 180; }
- (double)playbackSpeed { return 1; }
- (NSArray *)future { return @[]; }
- (NSArray *)reverse { return @[]; }
@end
SPTPlayerState *SGPlayerState(void) { static SPTPlayerState *state; if (!state) state = [SPTPlayerState new]; return state; }
@interface ESPContext : NSObject
@property (nonatomic, copy) NSString *uri;
@end
@implementation ESPContext
@end
@interface FixturePlayer : NSObject
@end
@implementation FixturePlayer
- (id)playContext:(ESPContext *)context options:(id)options loggingParams:(id)logging origin:(id)origin {
    if ([context.uri hasSuffix:@"9999999999999999999999"]) return nil;
    fakeContext = context.uri;
    BOOL playlist = [fakeContext hasPrefix:@"spotify:playlist:"];
    fakeURI = playlist ? @"spotify:track:7777777777777777777777" : context.uri;
    fakeTitle = playlist ? @"First song from the playlist" : @"Your requested song";
    fakePosition = 0; fakeStarted = NSDate.timeIntervalSinceReferenceDate; fakePaused = NO;
    [SGLocalJamHubShared() playerStateChanged];
    return nil;
}
- (id)resume:(id)options { fakePaused = NO; fakeStarted = NSDate.timeIntervalSinceReferenceDate; return nil; }
@end
id<SPTPlayer> SGPlaybackPlayer(void) { static id player; if (!player) player = [FixturePlayer new]; return player; }

int main(void) { @autoreleasepool {
    signal(SIGTERM, interrupted); signal(SIGINT, interrupted);
    SGWebJamSetEnabled(NO);
    fakeURI = @"spotify:track:0000000000000000000000"; fakeTitle = @"A little closer";
    fakeStarted = NSDate.timeIntervalSinceReferenceDate;
    audioProcessor->prepare((AudioUnit)1);
    SGWebJamSetEnabled(YES);
    for (NSString *uri in @[@"spotify:track:1111111111111111111111", @"spotify:track:2222222222222222222222", @"spotify:playlist:3333333333333333333333"])
        sharedServer().resolved[uri] = @{@"title": [uri hasPrefix:@"spotify:playlist:"] ? @"After-hours favorites" : @"<script>literal request</script>", @"artist": @"Fixture artist"};
    __block unsigned tick = 0; __block double phase = 0;
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:.02 repeats:YES block:^(NSTimer *timer) {
        if (++tick % 5 == 0) {
            NSString *control = @"harness/jam/build/control.json";
            NSData *data = [NSData dataWithContentsOfFile:control];
            if (data) {
                [[NSFileManager defaultManager] removeItemAtPath:control error:nil];
                NSDictionary *command = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (command[@"paused"]) { fakePosition = SGPlayerState().position; fakePaused = [command[@"paused"] boolValue]; fakeStarted = NSDate.timeIntervalSinceReferenceDate; }
                if (command[@"position"]) { fakePosition = [command[@"position"] doubleValue]; fakeStarted = NSDate.timeIntervalSinceReferenceDate; }
                if (command[@"title"]) fakeTitle = command[@"title"];
                [SGLocalJamHubShared() playerStateChanged];
            }
        }
        if (fakePaused) return;
        float left[960], right[960];
        for (unsigned i = 0; i < 960; i++) { left[i] = sin(phase) * .2; right[i] = cos(phase) * .2; phase += 2 * M_PI * 440 / 48000; }
        struct { AudioBufferList list; AudioBuffer extra; } buffers;
        buffers.list.mNumberBuffers = 2;
        buffers.list.mBuffers[0] = (AudioBuffer){1, sizeof left, left}; buffers.list.mBuffers[1] = (AudioBuffer){1, sizeof right, right};
        AudioUnitRenderActionFlags flags = kAudioUnitRenderAction_PostRender; AudioTimeStamp time = {0};
        audioProcessor->output(&buffers, &flags, &time, 0, 960, &buffers.list);
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!SGWebJamRunning() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
    NSString *url = SGWebJamJoinURL();
    if (!url) { SGWebJamSetEnabled(NO); return 1; }
    printf("%s\n", url.UTF8String); fflush(stdout);
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:240];
    while (!quitting && end.timeIntervalSinceNow > 0) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
    [timer invalidate]; SGWebJamSetEnabled(NO);
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyWebJam];
} return 0; }
