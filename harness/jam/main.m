// The Local Jam session protocol end to end on the Mac: a host hub and a guest
// hub whose MultipeerConnectivity is replaced by direct message delivery and a
// scripted player, run under AddressSanitizer. The runtime in LocalJam.x is
// device-only (MCSession cannot run headless here); this file feeds the hubs
// exactly what its callbacks would, and asserts the statuses pages show.
#import <Foundation/Foundation.h>
#import "Core/SGPrefs.h"
#import "Shared/Player/PlayerState.h"
#import "Headers/SPTPlayer.h"
#import "Shared/Jam/LocalJam.h"
#import "Shared/Jam/WebJamRules.h"

static void check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
    printf("ok: %s\n", message.UTF8String);
}

void SGLogMessage(NSString *message) { printf("    log: %s\n", message.UTF8String); }

NSString *SGURIString(id uri) {
    return [uri isKindOfClass:NSString.class] ? uri :
        [uri isKindOfClass:NSURL.class] ? [(NSURL *)uri absoluteString] : nil;
}

// Presence only, and the stubs' own declarations do all the synthesizing:
// @dynamic keeps these empty bases from fighting their readwrite redeclarations.
@implementation SPTPlayerState
@dynamic track, contextURI, options, isPaused, isPlaying, isLoading, sleepTimer,
    position, positionAsOfTimestamp, duration, playbackSpeed, future, reverse;
@end
@implementation SPTPlayerTrack
@dynamic URI, artistURI, artistName, trackTitle, provider, metadata;
@end

// Spotify's one-song-start class, guarded and caught by the hub; the class gate
// asks for setUri: on the CLASS itself, as the hooks verified on-device.
@interface ESPContext : NSObject
@property (nonatomic, copy) NSString *uri;
+ (void)setUri:(NSString *)value;
@end
@implementation ESPContext
+ (void)setUri:(NSString *)value { (void)value; }
@end

#pragma mark - a scripted player, per device

// A track whose own accessors answer the hub's reads; Spotify's class itself
// only exists for its type. The subtype keeps the property types intact.
@interface StubTrack : SPTPlayerTrack
- (void)putURI:(NSString *)uri title:(NSString *)title;
@end
@implementation SPTPlayerTrack (StubFactory)
+ (instancetype)trackWithURI:(NSURL *)uri {
    StubTrack *track = [[NSClassFromString(@"StubTrack") alloc] init];
    [track putURI:uri.absoluteString title:@""];
    return track;
}
@end
@implementation StubTrack {
    NSString *_uriValue, *_titleValue, *_artistValue;
}
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _uriValue = @"";
    _titleValue = @"";
    _artistValue = @"";
    return self;
}
- (void)putURI:(NSString *)uri title:(NSString *)title {
    _uriValue = uri ?: @"";
    _titleValue = title ?: @"";
}
- (id)URI { return _uriValue; }
- (NSString *)trackTitle { return _titleValue; }
- (NSString *)artistName { return _artistValue; }
@end

// The state reads the same fields the hub reads, written through put methods:
// the parent declares everything readonly, so the strobe owns the accessors.
@interface StubState : SPTPlayerState
@property (nonatomic, copy) NSString *stubContext;
- (void)putTrack:(StubTrack *)track;
- (void)putPaused:(BOOL)paused playing:(BOOL)playing;
- (void)putPosition:(double)pos asOf:(double)asOf;
- (void)seedDuration:(double)duration;
- (void)advance:(double)seconds;
- (void)skipAhead:(double)seconds;   // the fixture's clock lies by design
- (void)jumpTo:(double)seconds;
@end
@implementation StubState {
    StubTrack *_stubTrack;
    BOOL _flagPaused, _flagPlaying;
    double _position, _positionAsOf, _duration;
}
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _flagPaused = YES;   // an empty Spotify: no song, not playing
    return self;
}
- (void)putTrack:(StubTrack *)track { _stubTrack = track; }
- (void)putPaused:(BOOL)paused playing:(BOOL)playing {
    _flagPaused = paused; _flagPlaying = playing;
}
- (void)putPosition:(double)pos asOf:(double)asOf {
    _position = pos; _positionAsOf = asOf;
}
- (void)seedDuration:(double)duration { _duration = duration; }
- (void)advance:(double)seconds {
    if (_flagPlaying) { _position += seconds; _positionAsOf = _position; }
}
- (void)skipAhead:(double)seconds { _position += seconds; _positionAsOf = _position; }
- (void)jumpTo:(double)seconds { _position = seconds; _positionAsOf = seconds; }
- (id)contextURI { return self.stubContext; }
- (BOOL)isLoading { return NO; }
- (NSArray *)future { return nil; }   // Spotify's stock getter; the fixture queues nothing
- (SPTPlayerTrack *)track { return _stubTrack; }
- (BOOL)isPaused { return _flagPaused; }
- (BOOL)isPlaying { return _flagPlaying; }
- (double)position { return _position; }
- (double)positionAsOfTimestamp { return _positionAsOf; }
- (double)duration { return _duration; }
@end

@interface StubPlayer : NSObject
@property (nonatomic, copy) NSString *lastContextURI;
@property (nonatomic, strong) NSMutableArray<NSString *> *queuedTrackURIs;
@property (nonatomic, assign) NSInteger pauseCount, resumeCount, seekCount, skipCount;
@property (nonatomic, assign) double lastSeek;
- (void)attachState:(StubState *)state;   // Spotify's player mutates the state it reports
@end
@implementation StubPlayer {
    StubState *_bound;
}
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _queuedTrackURIs = [NSMutableArray array];
    return self;
}
- (void)attachState:(StubState *)state { _bound = state; }
- (id)addToQueue:(SPTPlayerTrack *)track {
    NSString *uri = SGURIString(track.URI);
    if (uri.length) [_queuedTrackURIs addObject:uri];
    return nil;
}
- (id)pause:(id)options { self.pauseCount++; [_bound putPaused:YES playing:NO]; return nil; }
- (id)resume:(id)options { self.resumeCount++; [_bound putPaused:NO playing:YES]; return nil; }
- (void)seekTo:(double)seconds {
    self.seekCount++; self.lastSeek = seconds;
    [_bound jumpTo:seconds];
}
- (id)skipToNextTrackWithOptions:(id)options { self.skipCount++; return nil; }
- (id)skipToNextTrackWithOptions:(id)options track:(SPTPlayerTrack *)track {
    (void)track; self.skipCount++; return nil;
}
- (id)playContext:(id)context options:(id)options loggingParams:(id)logging origin:(id)origin {
    (void)options; (void)logging; (void)origin;
    id uri = nil;
    @try { uri = [context valueForKey:@"uri"]; } @catch (NSException *at) { (void)at; }
    self.lastContextURI = [uri isKindOfClass:NSString.class] ? uri : nil;
    return nil;
}
@end

#pragma mark - two devices, one process

@class Device;
static Device *sg_active, *sg_host, *sg_guest;

@interface Device : NSObject
@property (nonatomic, strong) StubState *state;
@property (nonatomic, strong) StubPlayer *player;
@property (nonatomic, strong) SGLocalJamHub *hub;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) BOOL wireDown;   // none of this device's messages arrive
- (instancetype)initWithName:(NSString *)name;
- (void)playSong:(NSString *)uri title:(NSString *)title playing:(BOOL)playing at:(double)seconds;
- (void)advance:(double)seconds;
@end

@implementation Device
- (instancetype)initWithName:(NSString *)name {
    if (!(self = [super init])) return nil;
    StubState *state = [StubState new];
    [state putTrack:[[StubTrack alloc] init]];   // an empty Spotify: no song, not playing
    [state seedDuration:210.0];
    self.state = state;
    self.player = [StubPlayer new];
    [self.player attachState:state];
    self.name = name;
    Device *previous = sg_active;   // the hub takes this phone's name at init
    sg_active = self;
    self.hub = [[SGLocalJamHub alloc] init];
    sg_active = previous;
    return self;
}
- (void)playSong:(NSString *)uri title:(NSString *)title playing:(BOOL)playing at:(double)seconds {
    StubTrack *track = [[StubTrack alloc] init];
    [track putURI:uri title:title];
    [self.state putTrack:track];
    [self.state putPaused:!playing playing:playing];
    [self.state putPosition:seconds asOf:seconds];
}
- (void)advance:(double)seconds { [self.state advance:seconds]; }
@end

// The device whose Spotify a hub call is reading right now; delivery swaps it.
SPTPlayerState *SGPlayerState(void) { return sg_active.state; }
id<SPTPlayer> SGPlaybackPlayer(void) { return (id<SPTPlayer>)sg_active.player; }

// UIKit's device, so a hub created under a device's drive takes that device's name.
@implementation UIDevice
@dynamic name;
+ (instancetype)currentDevice { return [[UIDevice alloc] init]; }
- (NSString *)name { return sg_active ? sg_active.name : @"iPhone"; }
@end

static void drive(Device *device, void (^call)(void)) {
    Device *previous = sg_active;
    sg_active = device;
    @try { call(); } @finally { sg_active = previous; }
}

// The wire: the host's word goes to the guest and the guest's goes to the peer
// key the host registered it under. A device with wireDown set stays silent.
static void wire(Device *sender, NSDictionary *message) {
    Device *holder = sg_active;
    if (!sender.wireDown) {
        Device *receiver = sender == sg_host ? sg_guest : sg_host;
        sg_active = receiver;
        [receiver.hub receive:message from:sender == sg_host ? @"host" : @"guest"];
        sg_active = holder;
    }
}

// The 400 ms cadence with a real clock: the hub's sync gates compare nowMillis()
// against message stamps, so beats must be real sleeps, not a synthetic clock.
static void runBeats(NSInteger count) {
    double last = CFAbsoluteTimeGetCurrent();
    for (NSInteger i = 0; i < count; i++) {
        [NSThread sleepForTimeInterval:0.41];
        double now = CFAbsoluteTimeGetCurrent(), dt = now - last;
        last = now;
        drive(sg_host, ^{ [sg_host advance:dt]; [sg_host.hub beat]; });
        drive(sg_guest, ^{ [sg_guest advance:dt]; [sg_guest.hub beat]; });
    }
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;

    // Web Jam rules: what a guest can paste, and how its text leaves the host.
    NSString *trackID = @"4uLU6hMCjMI75M1A2tKUQC";
    check([SGWebJamTrackID(trackID) isEqualToString:trackID], @"a bare 22-character id is a track");
    check([SGWebJamTrackID([@"spotify:track:" stringByAppendingString:trackID]) isEqualToString:trackID],
          @"a spotify:track: URI is a track");
    check([SGWebJamTrackID([NSString stringWithFormat:
        @"  https://open.spotify.com/track/%@?si=abc  ", trackID]) isEqualToString:trackID],
          @"an open.spotify.com track link with a query is a track");
    check([SGWebJamTrackID([NSString stringWithFormat:@"https://open.spotify.com/intl-de/track/%@?si=test", trackID]) isEqual:trackID], @"localized Spotify links work");
    check(SGWebJamTrackID([NSString stringWithFormat:@"https://open.spotify.com/anything/track/%@", trackID]) == nil, @"unrecognized path prefix is rejected");
    NSString *cover = @"https://i.scdn.co/image/0123456789abcdef0123456789abcdef";
    check([SGWebJamCoverURL(@{@"image_url": cover}) isEqual:cover], @"public Spotify cover is allowed");
    check([SGWebJamCoverURL(@{@"image_url": @"spotify:image:0123456789abcdef0123456789abcdef"}) isEqual:cover], @"Spotify image URI becomes a public cover");
    for (NSString *bad in @[@"https://tracker.invalid/cover", [cover stringByAppendingString:@"?token=secret"], @"https://i.scdn.co/image/../../private", @"https://i.scdn.co.evil/image/0123456789abcdef0123456789abcdef"])
        check(SGWebJamCoverURL(@{@"image_url": bad}) == nil, @"nonpublic artwork is rejected");
    check(SGWebJamTrackID(@"4uLU6hMCjMI75M1A2tKUQ") == nil, @"a 21-character id is not a track");
    check(SGWebJamTrackID(@"4uLU6hMCjMI75M1A2tKUQCX") == nil, @"a 23-character id is not a track");
    check(SGWebJamTrackID(@"4uLU6hMCjMI75M1A2tKUQ-") == nil, @"a non-alphanumeric id is not a track");
    check(SGWebJamTrackID(@"https://open.spotify.com/album/4uLU6hMCjMI75M1A2tKUQC") == nil,
          @"an album link is not a track");
    check(SGWebJamTrackID(@"https://example.com/track/4uLU6hMCjMI75M1A2tKUQC") == nil,
          @"another host is not a track");
    check(SGWebJamTrackID(@"spotify:album:4uLU6hMCjMI75M1A2tKUQC") == nil, @"an album URI is not a track");
    check(SGWebJamTrackID(@"") == nil && SGWebJamTrackID(nil) == nil, @"empty and nil are not tracks");
    check([SGWebJamURIForTrackID(trackID) isEqualToString:
        [@"spotify:track:" stringByAppendingString:trackID]], @"a track id becomes a spotify:track: URI");
    check(SGWebJamURIForTrackID(@"short") == nil, @"an invalid id has no URI");
    NSString *jsonRaw = @"a\"b\\c\nd\te";
    check([SGWebJamJSONString(jsonRaw) isEqualToString:@"\"a\\\"b\\\\c\\nd\\te\""],
          @"JSON escapes quotes, backslashes and controls");
    check([SGWebJamJSONString(@"\x01") isEqualToString:@"\"\\u0001\""], @"JSON escapes control characters");
    NSString *hostile = @"<script>alert(\"x\") & 'y'</script>";
    NSString *escaped = SGWebJamHTMLEscape(hostile);
    check([escaped isEqualToString:@"&lt;script&gt;alert(&quot;x&quot;) &amp; &#39;y&#39;&lt;/script&gt;"],
          @"HTML escapes tags, quotes and ampersands");
    check([escaped rangeOfString:@"<script>"].location == NSNotFound, @"hostile HTML has no live tag");

    sg_host = [[Device alloc] initWithName:@"Diyar's iPhone"];
    sg_guest = [[Device alloc] initWithName:@"Salma's iPhone"];

    sg_host.hub.send = ^(NSString *to, NSDictionary *message) { (void)to; wire(sg_host, message); };
    sg_guest.hub.send = ^(NSString *to, NSDictionary *message) { (void)to; wire(sg_guest, message); };

    // The host is mid-song when it opens its Jam.
    [sg_host playSong:@"spotify:track:host1" title:@"Host Hit" playing:YES at:60.0];
    drive(sg_host, ^{ [sg_host.hub startHost]; });
    check(sg_host.hub.isHosting && sg_host.hub.joined, @"the host is hosting");
    check([sg_host.hub.status isEqualToString:@"Hosting · advertising on this network"],
          @"hosting status");
    check([sg_host.hub.memberNames.firstObject isEqualToString:@"Diyar's iPhone"],
          @"the host is the first member");

    // The runtime registers a connected guest with the session key it will use.
    drive(sg_host, ^{ [sg_host.hub peerConnected:@"guest" name:@"Salma's iPhone"]; });
    check([sg_host.hub.status isEqualToString:@"Hosting · Salma's iPhone is connected"],
          @"a connected guest shows its name");

    // The guest joins the advertised name.
    [sg_guest playSong:@"" title:@"" playing:NO at:0.0];
    drive(sg_guest, ^{ [sg_guest.hub join:@"host" name:@"Diyar's iPhone"]; });
    check(sg_guest.hub.joined && !sg_guest.hub.isHosting, @"the guest is joined without hosting");
    check([sg_guest.hub.hostName isEqualToString:@"Diyar's iPhone"] &&
          [sg_guest.hub.status isEqualToString:@"Following · reaching the song"],
          @"the join's handshakes came back as follow mode");
    check([sg_host.hub.status isEqualToString:@"Hosting · Salma's iPhone joined"],
          @"the host saw the join");
    check(sg_guest.hub.memberNames.count == 2 &&
          [sg_guest.hub.memberNames containsObject:@"Salma's iPhone"] &&
          [sg_guest.hub.memberNames containsObject:@"Diyar's iPhone"],
          @"both devices are members");

    // The host's PLAY reaches a guest playing nothing: it opens the host's song
    // as a fresh context, then its player reports in.
    check(sg_guest.hub.loadingTrack, @"the guest is waiting to reach the song");
    [sg_guest playSong:@"spotify:track:host1" title:@"Host Hit" playing:YES at:59.5];
    runBeats(2);
    check(sg_guest.hub.following, @"the guest landed on the host's song");
    check([sg_guest.hub.status hasPrefix:@"Following · Host Hit"], @"following status names the song");
    check([sg_guest.player.lastContextURI isEqualToString:@"spotify:track:host1"],
          @"the song was opened as a fresh context");
    check(sg_guest.player.seekCount == 1 &&
          sg_guest.player.lastSeek > 58.5 && sg_guest.player.lastSeek < 61.5,
          @"the landing seeked to the host's position");
    // Steady state first: the guest pings and gets its number within a few beats.
    runBeats(6);
    check(sg_guest.hub.ping >= 0, @"the guest has a round-trip number");

    // The guest's clock runs 1 s fast: the host's next tick pulls it back.
    [sg_guest.state skipAhead:1.0];
    BOOL nudged = NO;
    for (NSInteger i = 0; i < 15 && !nudged; i++) {
        runBeats(1);
        nudged = [sg_guest.hub.status isEqualToString:@"Following · nudged"];
    }
    check(nudged, @"drift was nudged back into step");
    check(sg_guest.player.seekCount == 2 &&
          fabs(sg_guest.player.lastSeek * 1000.0 - sg_host.state.position * 1000.0) < 2000.0,
          @"the nudge moved the guest to the host's position");

    // The host drags its own scrubber: the jump is relayed, the guest rewinds.
    NSInteger guestSeeks = sg_guest.player.seekCount;
    [sg_host.state jumpTo:200.0];
    runBeats(1);
    check([sg_guest.hub.status isEqualToString:@"Following · rewound"], @"the relay reach the guest");
    check(sg_guest.player.seekCount == guestSeeks + 1 &&
          fabs(sg_guest.player.lastSeek - 200.0) < 3.0,
          @"the guest rewound with the host");
    // Pass the aux: the host's switch announces itself, then songs cross over.
    drive(sg_host, ^{ sg_host.hub.guestControl = YES; });
    check(sg_host.hub.queue.count == 0, @"the queue starts empty");
    check([sg_guest.hub.status isEqualToString:@"Pass the aux is on"],
          @"the gate reached the guest");

    // The guest starts its own song and suggests it. No beats run in between,
    // so no tick fights the guest's own song while the suggestion travels.
    [sg_guest playSong:@"spotify:track:guest1" title:@"Guest Pick" playing:YES at:8.0];
    [NSThread sleepForTimeInterval:0.55];
    drive(sg_guest, ^{ [sg_guest.hub queueCurrentTrack]; });
    check([sg_guest.hub.status isEqualToString:@"Suggested this song to the host"],
          @"suggest status");
    check(sg_host.hub.queue.count == 1 &&
          [sg_host.hub.queue.firstObject.title isEqualToString:@"Guest Pick"] &&
          [sg_host.hub.queue.firstObject.addedBy isEqualToString:@"Salma's iPhone"],
          @"the host queued the suggestion under the guest's name");

    // The host plays the queued head: a fresh context again, then its state
    // change pops the head and broadcasts the new song, which reunites the room.
    drive(sg_host, ^{ [sg_host.hub playQueuedHead]; });
    check([sg_host.player.lastContextURI isEqualToString:@"spotify:track:guest1"],
          @"the host opened the queued song");
    [sg_host playSong:@"spotify:track:guest1" title:@"Guest Pick" playing:YES at:0.0];
    drive(sg_host, ^{ [sg_host.hub playerStateChanged]; });
    check(sg_host.hub.queue.count == 0, @"the played head left the queue");
    check([sg_guest.hub.status hasPrefix:@"Following"], @"the guest is on the new song");

    [NSThread sleepForTimeInterval:0.6];
    drive(sg_guest, ^{ [sg_guest.hub guestCommand:@"pause"]; });
    check(sg_host.player.pauseCount == 1 && sg_guest.player.pauseCount == 1 &&
          [sg_guest.hub.status isEqualToString:@"Following · paused"],
          @"the guest's pause reached both players");

    // A stuck guest: the same command twice inside the throttle window acts once.
    drive(sg_host, ^{ [sg_host.hub receive:@{@"t": @"CMD", @"a": @"pause"} from:@"guest"]; });
    check(sg_host.player.pauseCount == 1, @"the second pause inside 500 ms was dropped");

    [NSThread sleepForTimeInterval:0.6];
    drive(sg_guest, ^{ [sg_guest.hub guestCommand:@"play"]; });
    check(sg_host.player.resumeCount == 1, @"the host resumed for the guest");
    drive(sg_host, ^{ [sg_host.hub receive:@{@"t": @"CMD", @"a": @"evil"} from:@"guest"]; });
    check(sg_host.player.resumeCount == 1 && sg_host.player.pauseCount == 1 &&
          sg_host.player.skipCount == 0, @"an unknown verb does nothing");

    [NSThread sleepForTimeInterval:0.6];
    drive(sg_guest, ^{ [sg_guest.hub guestSeek:45.0]; });
    check(sg_host.player.seekCount == 1 && fabs(sg_host.player.lastSeek - 45.0) < 0.1,
          @"the guest's seek landed on the host's player");

    // Silence: the whole wire dies, and the guest says so at the ten second mark.
    sg_host.wireDown = YES; sg_guest.wireDown = YES;
    BOOL lost = NO;
    for (NSInteger i = 0; i < 40 && !lost; i++) {
        runBeats(1);
        lost = [sg_guest.hub.status hasPrefix:@"Lost the host"];
    }
    check(lost, @"silence was called out");
    sg_host.wireDown = NO; sg_guest.wireDown = NO;
    [sg_host playSong:@"spotify:track:guest1" title:@"Guest Pick" playing:YES at:10.0];
    drive(sg_host, ^{ [sg_host.hub playerStateChanged]; });
    runBeats(4);
    check([sg_guest.hub.status hasPrefix:@"Following"], @"the reunion was automatic");
    check(sg_guest.hub.ping >= 0, @"pings flow again");

    // Malformed traffic: every field wrong, no peer, no stamp. Nothing acts.
    NSInteger hostPauses = sg_host.player.pauseCount, hostResumes = sg_host.player.resumeCount,
              hostSeeks = sg_host.player.seekCount, hostSkips = sg_host.player.skipCount,
              guestSeeksBefore = sg_guest.player.seekCount;
    drive(sg_host, ^{
        [sg_host.hub receive:(id)@"garbage" from:@"guest"];
        [sg_host.hub receive:@{} from:@"guest"];
        [sg_host.hub receive:@{@"t": @"PING"} from:@"guest"];
        [sg_host.hub receive:@{@"t": @"ADD", @"u": @1} from:@"guest"];
        [sg_host.hub receive:@{@"t": @"ADD"} from:@"stranger"];
        [sg_host.hub receive:@{@"t": @"CMD", @"a": @[]} from:@"guest"];
    });
    drive(sg_guest, ^{
        [sg_guest.hub receive:@{@"t": @"Q", @"q": @"x"} from:@"host"];
        [sg_guest.hub receive:@{@"t": @"MEMBERS", @"m": @[@1, @"bad"]} from:@"host"];
        [sg_guest.hub receive:@{@"t": @"INIT", @"h": @9, @"m": @"x"} from:@"host"];
        [sg_guest.hub receive:@{@"t": @"PLAY", @"u": @1, @"p": @"s"} from:@"host"];
        [sg_guest.hub receive:@{@"t": @"PAUSE"} from:@"guest"];
        [sg_guest.hub receive:@{@"t": @"SEEK", @"p": @"x"} from:@"host"];
        [sg_guest.hub receive:@{@"t": @"PONG", @"ts": @"x"} from:@"host"];
        [sg_guest.hub receive:@{@"t": @"CMD"} from:@"host"];
        [sg_guest.hub receive:@{@"t": @"JOIN"} from:@"host"];
    });
    check(sg_host.player.pauseCount == hostPauses && sg_host.player.resumeCount == hostResumes &&
          sg_host.player.seekCount == hostSeeks && sg_host.player.skipCount == hostSkips &&
          sg_host.hub.queue.count == 0 && sg_host.hub.memberNames.count == 2,
          @"every malformed message changed nothing on the host");
    check(sg_guest.player.seekCount == guestSeeksBefore && sg_guest.hub.ping == -1 &&
          [sg_guest.hub.hostName isEqualToString:@"Diyar's iPhone"],
          @"every malformed message changed nothing on the guest");

    drive(sg_guest, ^{
        [sg_guest.hub receive:@{@"t": @"PLAY", @"u": @"spotify:track:paused",
            @"n": @"Paused song", @"p": @1000, @"pa": @YES} from:@"host"];
        [sg_guest playSong:@"spotify:track:paused" title:@"Paused song" playing:YES at:0];
        [sg_guest.hub playerStateChanged];
        check(sg_guest.state.isPaused, @"a paused host stays paused after a delayed song load");
        NSInteger seeks = sg_guest.player.seekCount;
        [sg_guest.hub receive:@{@"t": @"SEEK", @"p": @(INFINITY)} from:@"host"];
        check(sg_guest.player.seekCount == seeks, @"nonfinite seek positions are ignored");
    });

    // Leaving, both ways.
    drive(sg_guest, ^{ [sg_guest.hub leave]; });
    check(!sg_guest.hub.joined &&
          [sg_guest.hub.status isEqualToString:@"Not in a Jam · left the host"],
          @"the guest left cleanly");
    drive(sg_host, ^{ [sg_host.hub peerDisconnected:@"guest"]; });
    check(sg_host.hub.memberNames.count == 1 &&
          [sg_host.hub.status isEqualToString:@"Hosting · a listener left"],
          @"the host was alone again");

    // Web Jam: browser requests queue as Guest and only move the host at the end
    // of a song, once per current track.
    NSString *webOne = SGWebJamURIForTrackID(@"1111111111111111111111");
    NSString *webTwo = SGWebJamURIForTrackID(@"2222222222222222222222");
    drive(sg_host, ^{
        check([sg_host.hub addWebRequestURI:webOne title:@"Web One" artist:@"Guest"],
              @"a web request enters the queue");
        check([sg_host.player.queuedTrackURIs containsObject:webOne],
              @"a web track request is immediately added to Spotify's native queue");
        check([sg_host.hub.queue.firstObject.addedBy isEqualToString:@"Guest"],
              @"a web request is attributed to Guest");
        check(![sg_host.hub addWebRequestURI:webOne title:@"Web One" artist:@"Guest"],
              @"a duplicate web request is refused");
        check(![sg_host.hub addWebRequestURI:@"spotify:track:short" title:@"Bad" artist:@"Guest"],
              @"a malformed web URI is refused");
        check(![sg_host.hub playWebRequestAtEnd], @"a web request waits until the song ends");
    });
    [sg_host.state jumpTo:209.5];
    [sg_host.state putPaused:NO playing:YES];
    drive(sg_host, ^{
        check([sg_host.hub playWebRequestAtEnd], @"a web request plays in the last 0.75 s");
    });
    check([sg_host.player.lastContextURI isEqualToString:webOne], @"the host opened the web request");
    check(sg_host.hub.queue.count == 1, @"an unconfirmed playback request stays queued");

    drive(sg_host, ^{
        check([sg_host.hub addWebRequestURI:webTwo title:@"Web Two" artist:@"Guest"],
              @"a second web request queues");
        check(![sg_host.hub playWebRequestAtEnd], @"the same current track never advances twice");
        check(sg_host.hub.queue.count == 2, @"the refused advance left both requests queued");
    });

    [sg_host playSong:webOne title:@"Web One" playing:YES at:5.0];
    drive(sg_host, ^{
        [sg_host.hub playerStateChanged];
        check(![sg_host.hub playWebRequestAtEnd], @"a web request never starts in a song's first 3 s");
        [sg_host.state seedDuration:3.0];
        [sg_host.state jumpTo:2.5];
        check(![sg_host.hub playWebRequestAtEnd],
              @"the first 3 s guard also holds near a very short song's end");
        [sg_host.state seedDuration:210.0];
        [sg_host.state jumpTo:209.5];
        [sg_host.state putPaused:YES playing:NO];
        check(![sg_host.hub playWebRequestAtEnd], @"a paused host does not advance");
        [sg_host.state putPaused:NO playing:YES];
        check([sg_host.hub playWebRequestAtEnd], @"the next song's end plays the next request");
    });
    check([sg_host.player.lastContextURI isEqualToString:webTwo], @"the second web request played");
    check(sg_host.hub.queue.count == 1, @"the second request waits for player confirmation");
    [sg_host playSong:webTwo title:@"Web Two" playing:YES at:0];
    drive(sg_host, ^{ [sg_host.hub playerStateChanged]; });
    check(sg_host.hub.queue.count == 0, @"confirmed playback removes the request");

    __block SGLocalJamHub *capHub = nil;
    drive(sg_host, ^{
        capHub = [SGLocalJamHub new];
        check(![capHub addWebRequestURI:webOne title:@"Not hosting" artist:@"Guest"], @"web requests require an active host");
        [capHub startHost];
    });
    for (NSInteger i = 0; i < 100; i++) {
        NSString *id = [NSString stringWithFormat:@"%022ld", (long)i];
        [capHub addWebRequestURI:SGWebJamURIForTrackID(id) title:@"Filler" artist:@"Guest"];
    }
    check(capHub.queue.count == 100, @"the web queue stops at 100");
    check(![capHub addWebRequestURI:SGWebJamURIForTrackID(@"9999999999999999999999")
        title:@"Over" artist:@"Guest"], @"the 101st web request is refused");

    NSString *playlist = @"spotify:playlist:3333333333333333333333";
    check([SGWebJamRequestURI(@"https://open.spotify.com/intl-fr/playlist/3333333333333333333333?si=ok") isEqual:playlist], @"playlist links are canonicalized");
    check(SGWebJamTrackID(playlist) == nil, @"a playlist is not misreported as a track");
    check([SGWebJamDisplayName(@"  Alex\n  ") isEqual:@"Alex"], @"request names are trimmed");
    drive(sg_host, ^{
        check([sg_host.hub addWebRequestURI:playlist title:@"Party playlist" artist:@"Playlist" by:@"Alex"], @"a named playlist enters the request queue");
        SGLocalJamEntry *entry = sg_host.hub.queue.firstObject;
        check([entry.addedBy isEqual:@"Alex"] && [entry.requestStatus isEqual:@"Queued"], @"request attribution and status are retained");
        [sg_host.state jumpTo:209.5];
        check([sg_host.hub playWebRequestAtEnd], @"playlist starts at the song boundary");
        check([sg_host.player.lastContextURI isEqual:playlist], @"playlist uses Spotify's context playback");
        check(sg_host.hub.queue.count == 1, @"playlist waits for playback confirmation");
        sg_host.state.stubContext = playlist;
        [sg_host playSong:@"spotify:track:4444444444444444444444" title:@"First playlist track" playing:YES at:0];
        [sg_host.hub playerStateChanged];
        check(sg_host.hub.queue.count == 0 && [entry.requestStatus isEqual:@"Playing"], @"confirmed playlist leaves the queue and is marked playing");
        [sg_host playSong:@"spotify:track:5555555555555555555555" title:@"Second playlist track" playing:YES at:0];
        [sg_host.hub playerStateChanged];
        check([entry.requestStatus isEqual:@"Playing"], @"playlist stays active across its songs");
        sg_host.state.stubContext = @"spotify:album:6666666666666666666666";
        [sg_host.hub playerStateChanged];
        check([entry.requestStatus isEqual:@"Played"], @"request history records leaving the playlist");
        check([sg_host.hub addWebRequestURI:webOne title:@"Unavailable test" artist:@"Guest"], @"timeout request enters queue");
        [sg_host.state jumpTo:209.5];
        check([sg_host.hub playWebRequestAtEnd], @"timeout request tries to start");
        [sg_host.hub setValue:@0 forKey:@"pendingWebAt"];
        check(![sg_host.hub playWebRequestAtEnd], @"unconfirmed request times out");
        check(sg_host.hub.queue.count == 0 && [sg_host.hub.webHistory.firstObject.requestStatus isEqual:@"Unavailable"], @"unavailable requests cannot block the queue indefinitely");
    });
    printf("PASS: local jam protocol end to end\n");
    return 0;
}
