// Listens-together without Spotify's server. The host iPhone advertises over the
// local network with MultipeerConnectivity (LocalJam.x); guests follow the host's
// transport, request songs and share one queue. This file has no transport code:
// it is the session protocol, so the Mac fixture can exercise it end to end with
// a scripted transport. The protocol and sync constants translate the approach of
// the Spicetify Jam extension, rebuilt here against this mod's own player access.
#import "LocalJam.h"
#import "WebJamRules.h"
#import "Core/SGPrefs.h"
#import "Core/SGLog.h"
#import "Shared/Player/PlayerState.h"
#import "Headers/SPTPlayer.h"
#import <objc/message.h>

NSNotificationName SGLocalJamDidChangeNotification = @"spotifyglass.jam.local.statusChanged";

static SGLocalJamHub *sg_hub;

BOOL SGLocalJamEnabled(void) {
    return SGHidden(SGKeyLocalJam);
}

SGLocalJamHub *SGLocalJamHubShared(void) {   // lazy: the page may read before the runtime starts
    if (!sg_hub) sg_hub = [[SGLocalJamHub alloc] init];
    return sg_hub;
}

// How two phones agree on "now": the host's reported position advances by the
// fraction of the round trip the message spent travelling. From the approach
// that follows here: a position tick every ~2.4 s, drifts under 160 ms ignored,
// mid drifts corrected after two confirmations, large ones immediately.
#define kBeatSeconds 0.4
#define kTickBeats 6
#define kPingBeats 5
#define kSmallDrift 160.0
#define kLargeDrift 650.0
#define kIgnoreAfterRemoteOp 2500.0
#define kIgnoreAfterAppliedSync 2000.0
#define kSeekDetectJump 1200.0
#define kGuestSilence 10000.0
#define kCommandThrottle 500.0
#define kSameTrackDrift 400.0
#define kQueueLimit 100
#define kMemberLimit 40
#define kNameLimit 32
#define kPollLimit 50
static double nowMillis(void) {
    return [NSDate.date timeIntervalSince1970] * 1000.0;
}

// Display names walk to other phones; they are capped to keep messages bounded.
static NSString *cappedName(NSString *name) {
    if (![name isKindOfClass:NSString.class]) return @"iPhone";
    NSString *trimmed = [name stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return @"iPhone";
    return trimmed.length > kNameLimit ? [trimmed substringToIndex:kNameLimit] : trimmed;
}

static id get(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return object && [object respondsToSelector:selector] ?
        ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

#pragma mark Spotify access (verify every selector before use, like the rest of the mod)

static SPTPlayerState *state(void) {
    return SGPlayerState();
}

static NSString *stateURI(void) {
    return SGURIString(get(get(state(), @"track"), @"URI"));
}

static NSString *stateTitle(void) {
    NSString *title = get(get(state(), @"track"), @"trackTitle");
    return [title isKindOfClass:NSString.class] && title.length ? title : @"";
}

static NSString *stateArtist(void) {
    NSString *artist = get(get(state(), @"track"), @"artistName");
    return [artist isKindOfClass:NSString.class] && artist.length ? artist : @"";
}

// The live-position rule this mod uses everywhere.
static double statePosition(void) {
    SPTPlayerState *at = state();
    if (!at) return -1;
    return at.isPaused ? at.positionAsOfTimestamp : at.position;
}

static BOOL statePlaying(void) {
    SPTPlayerState *at = state();
    return at.isPlaying && !at.isPaused;
}

static void pausePlayback(void) {
    id at = SGPlaybackPlayer();
    SEL pause = NSSelectorFromString(@"pause:");
    if (at && [at respondsToSelector:pause]) ((id (*)(id, SEL, id))objc_msgSend)(at, pause, @{});
}

static void resumePlayback(void) {
    id at = SGPlaybackPlayer();
    SEL resume = NSSelectorFromString(@"resume:");
    if (at && [at respondsToSelector:resume]) ((id (*)(id, SEL, id))objc_msgSend)(at, resume, @{});
}

static void seekSeconds(double seconds) {
    id at = SGPlaybackPlayer();
    SEL seek = NSSelectorFromString(@"seekTo:");
    if (at && [at respondsToSelector:seek]) ((id (*)(id, SEL, double))objc_msgSend)(at, seek, seconds);
}

static void skipToNextNative(void) {
    id at = SGPlaybackPlayer();
    SEL skip = NSSelectorFromString(@"skipToNextTrackWithOptions:");
    if (at && [at respondsToSelector:skip]) ((id (*)(id, SEL, id))objc_msgSend)(at, skip, @{});
}

static void skipToPreviousNative(void) {
    id at = SGPlaybackPlayer();
    SEL skip = NSSelectorFromString(@"skipToPreviousTrackWithOptions:");
    if (at && [at respondsToSelector:skip]) ((id (*)(id, SEL, id))objc_msgSend)(at, skip, @{});
}

// Skips ahead to a track from this device's own future list, when it is there.
static BOOL skipToFutureTrack(NSString *uri) {
    id at = SGPlaybackPlayer();
    SPTPlayerState *atState = state();
    SEL skip = NSSelectorFromString(@"skipToNextTrackWithOptions:track:");
    if (!at || !uri || !atState || ![at respondsToSelector:skip]) return NO;
    id trackClass = NSClassFromString(@"SPTPlayerTrack");   // Spotify's own; no link-time symbol
    for (SPTPlayerTrack *track in atState.future) {
        if (![track isKindOfClass:trackClass]) continue;
        if ([SGURIString(track.URI) isEqualToString:uri]) {
            ((id (*)(id, SEL, id, id))objc_msgSend)(at, skip, @{}, track);
            return YES;
        }
    }
    return NO;
}

// Appends a track to Spotify's native in-app playback queue so Web Jam and
// Local Jam track requests show up immediately in Spotify's own Queue view.
static BOOL enqueueTrackInSpotify(NSString *uri) {
    if (![uri isKindOfClass:NSString.class] || ![uri hasPrefix:@"spotify:track:"]) return NO;
    id at = SGPlaybackPlayer();
    Class trackClass = NSClassFromString(@"SPTPlayerTrack");
    SEL makeSel = NSSelectorFromString(@"trackWithURI:");
    SEL addSel = NSSelectorFromString(@"addToQueue:");
    if (!at || !trackClass || ![trackClass respondsToSelector:makeSel] || ![at respondsToSelector:addSel]) return NO;
    NSURL *url = [NSURL URLWithString:uri];
    if (!url) return NO;
    @try {
        id track = ((id (*)(id, SEL, id))objc_msgSend)(trackClass, makeSel, url);
        if (!track) return NO;
        ((id (*)(id, SEL, id))objc_msgSend)(at, addSel, track);
        return YES;
    } @catch (NSException *exception) {
        SGLog(@"local jam: Spotify refused addToQueue for %@: %@", uri, exception.reason);
        return NO;
    }
}

// Spotify keeps its own player rules; a fresh ESPContext for one song is within
// the shapes this mod already copies in its AutoMix hooks. Guard and catch turn
// a refusal into status text rather than a crash, so follow mode degrades to
// manual once and recovers on a later tick.
static BOOL startProvidedContext(NSString *uri) {
    id at = SGPlaybackPlayer();
    Class contextClass = NSClassFromString(@"ESPContext");
    if (!at || !contextClass || !uri) return NO;
    SEL share = NSSelectorFromString(@"playContext:options:loggingParams:origin:");
    SEL setUri = NSSelectorFromString(@"setUri:");
    if (![at respondsToSelector:share]) return NO;
    NSObject *context = [[contextClass alloc] init];
    if (!context || ![context respondsToSelector:setUri]) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(context, setUri, uri);
    @try {
        ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(at, share, context, nil, nil, nil);
        return YES;
    } @catch (NSException *exception) {
        SGLog(@"local jam: Spotify refused the context start: %@", exception.reason);
        return NO;
    }
}

// Reaches a song one way or another: one of this device's own future tracks
// skips natively, anything else opens as a fresh context. NO means Spotify's
// rules stopped it; the guest shows the song to start itself and follow mode
// recovers on a later tick.
static BOOL playTrackOnDevice(NSString *uri) {
    if (![uri isKindOfClass:NSString.class] || !uri.length) return NO;
    if (!SGPlaybackPlayer()) return NO;
    NSString *atURI = stateURI();
    if (atURI && [atURI isEqualToString:uri]) {
        resumePlayback();
        return YES;
    }
    if (skipToFutureTrack(uri)) {
        resumePlayback();
        return YES;
    }
    return startProvidedContext(uri);
}
#pragma mark Shared queue entries

@implementation SGLocalJamEntry

- (NSString *)description {
    return [NSString stringWithFormat:@"%@ — %@", self.title, self.artist];
}

- (NSDictionary *)dictionary {
    return @{@"u": self.uri ?: @"", @"ti": self.title ?: @"", @"ar": self.artist ?: @"",
             @"by": self.addedBy ?: @""};
}

+ (instancetype)entryWithURI:(NSString *)uri title:(NSString *)title artist:(NSString *)artist {
    if (![uri isKindOfClass:NSString.class] || !uri.length) return nil;
    SGLocalJamEntry *entry = [self new];
    entry.uri = uri;
    entry.title = [title isKindOfClass:NSString.class] && title.length ? cappedName(title) : @"Unknown";
    entry.artist = [artist isKindOfClass:NSString.class] && artist.length ? cappedName(artist) : @"";
    return entry;
}

+ (instancetype)fromDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:NSDictionary.class]) return nil;
    SGLocalJamEntry *entry = [self entryWithURI:dictionary[@"u"]
        title:dictionary[@"ti"] artist:dictionary[@"ar"]];
    if (!entry) return nil;
    if (![dictionary[@"by"] isKindOfClass:NSString.class]) return nil;
    entry.addedBy = cappedName(dictionary[@"by"]);
    return entry;
}

@end

#pragma mark The hub

@interface SGLocalJamHub ()
@property (nonatomic, assign) BOOL hosting, connected, following, loadingTrack;
@property (nonatomic, copy) NSString *status, *hostName, *nowPlayingTitle;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *members;   // n / h / you
@property (nonatomic, strong) NSMutableArray<SGLocalJamEntry *> *queue;
@property (nonatomic, strong) NSMutableArray<SGLocalJamEntry *> *webHistory;
@property (nonatomic, strong) SGLocalJamEntry *activeWebEntry, *pendingWebEntry;
@property (nonatomic) double pendingWebAt;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *peerNames;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *commandAt;
@property (nonatomic, copy) NSString *thisName;
@property (nonatomic, copy) NSString *hostPeer;
@property (nonatomic, assign) double lastHostWord, lastSyncRequest, pingMillis;
@property (nonatomic, assign) double driftEMA, remoteOpAt, appliedAt;
@property (nonatomic, assign) double localProgress, progressAt;
@property (nonatomic, assign) NSInteger driftConfirmed, pingCount, tickCount;
@property (nonatomic, strong) SGLocalJamEntry *loadEntry;
@property (nonatomic, assign) int loadPolls;
@property (nonatomic, assign) BOOL pendingHostPaused;
@property (nonatomic, assign) double pendingHostPosition, lastAdvance;
@property (nonatomic, copy) NSString *ownURI;
@property (nonatomic, copy) NSString *webAdvancedFromURI;   // Web Jam's once-per-track guard
@end

@implementation SGLocalJamHub

@synthesize guestControl = _guestControl;
// The header's readonly `queue` is used for display; the underscore ivar keeps
// the in-place mutation sites typed, arriving from one thread per session.
@synthesize queue = _queue;

// These three are read the real fields; their public readonly declarations have
// no backing ivar of their own.
- (BOOL)joined { return self.hosting || self.connected; }
- (NSInteger)ping { return (NSInteger)self.pingMillis; }
- (NSArray<NSString *> *)memberNames {
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:self.members.count];
    for (NSDictionary *at in self.members) {
        id name = at[@"n"];
        if ([name isKindOfClass:NSString.class]) [names addObject:name];
    }
    return names;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _members = [NSMutableArray array];
    _queue = [NSMutableArray array];
    _peerNames = [NSMutableDictionary dictionary];
    _commandAt = [NSMutableDictionary dictionary];
    _status = @"";
    _hostName = @"";
    _nowPlayingTitle = @"";
    _pingMillis = -1;
    _thisName = cappedName(UIDevice.currentDevice.name);
    return self;
}

- (void)post {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:SGLocalJamDidChangeNotification object:nil];
    if (self.changed) self.changed();
}

- (void)setStatusLine:(NSString *)line {
    line = line ?: @"";
    if ([line isEqualToString:self.status]) return;
    self.status = line;
    SGLog(@"local jam: %@", line);
    [self post];
}

- (void)setGuestControl:(BOOL)on {
    _guestControl = on;
    SGSetEnabled(SGKeyLocalJamAux, on);   // the page's switch shows this again after a restart
    if (self.hosting) {
        [self tellEveryone:@{@"t": @"GC", @"g": [NSNumber numberWithBool:on]}];
        [self post];
    }
}

- (void)tellEveryone:(NSDictionary *)message {
    if (self.send) self.send(nil, message);
}

- (void)tellPeer:(NSString *)peer message:(NSDictionary *)message {
    if (self.send && peer.length) self.send(peer, message);
}

// Reads the player so status shows something true, without starting anything.
- (void)refreshOwnTrack {
    SPTPlayerState *at = state();
    self.nowPlayingTitle = at ?
        [NSString stringWithFormat:@"%@ — %@", stateTitle(), stateArtist()] : @"";
}

- (NSDictionary *)member:(NSString *)name host:(BOOL)host you:(BOOL)you {
    return @{@"n": cappedName(name) ?: @"Listener", @"h": [NSNumber numberWithBool:host],
             @"you": [NSNumber numberWithBool:you]};
}
- (NSDictionary *)membersPayload {
    NSMutableArray *list = [NSMutableArray arrayWithCapacity:self.members.count];
    for (NSDictionary *at in self.members) [list addObject:at];
    return @{@"t": @"MEMBERS", @"m": list};
}

- (NSDictionary *)queuePayload {
    NSMutableArray *list = [NSMutableArray arrayWithCapacity:self.queue.count];
    for (SGLocalJamEntry *entry in self.queue) [list addObject:entry.dictionary];
    return @{@"t": @"Q", @"q": list};
}

// The one transport state shot: which song, where in it, playing or paused. The
// broadcast and the reply to a joining guest use exactly this shape.
- (NSDictionary *)playPayload {
    return @{@"t": @"PLAY",
             @"u": stateURI() ?: @"",
             @"n": self.nowPlayingTitle ?: @"",
             @"p": [NSNumber numberWithDouble:MAX(0, statePosition()) * 1000.0],
             @"ts": [NSNumber numberWithDouble:nowMillis()],
             @"pa": [NSNumber numberWithBool:!statePlaying()]};
}

- (void)publishQueue {
    [self tellEveryone:self.queuePayload];
    [self post];
}

#pragma mark Joining and leaving

- (void)startHost {
    self.webHistory = [NSMutableArray array];
    self.activeWebEntry = self.pendingWebEntry = nil;
    self.hosting = YES;
    self.hostPeer = @"host";
    self.connected = YES;
    self.webAdvancedFromURI = nil;
    self.members = [NSMutableArray
        arrayWithObject:[self member:self.thisName host:YES you:YES]];
    _guestControl = SGHidden(SGKeyLocalJamAux);   // the pass-the-aux switch survives restarts
    [self refreshOwnTrack];
    [self setStatusLine:@"Hosting · advertising on this network"];
    [self tellEveryone:[self membersPayload]];
    [self post];
}

- (void)join:(NSString *)peer name:(NSString *)name {
    self.hosting = NO;
    self.hostPeer = [peer isKindOfClass:NSString.class] && peer.length ? peer : @"host";
    self.hostName = cappedName(name);
    self.connected = YES;
    self.following = NO;
    self.pingMillis = -1;
    [self setStatusLine:[NSString stringWithFormat:@"Joined %@ over the local network", self.hostName]];
    [self tellPeer:self.hostPeer message:@{@"t": @"JOIN", @"n": self.thisName}];
    [self post];
}

- (void)leave {
    BOOL wasHosting = self.hosting;
    self.hosting = NO;
    self.connected = NO;
    self.following = NO;
    self.loadingTrack = NO;
    self.loadEntry = nil;
    self.lastHostWord = self.lastSyncRequest = self.remoteOpAt = self.appliedAt = 0;
    self.progressAt = self.lastAdvance = self.driftEMA = 0;
    self.driftConfirmed = self.pingCount = self.tickCount = 0;
    [self.commandAt removeAllObjects];
    self.webAdvancedFromURI = nil;
    self.activeWebEntry = self.pendingWebEntry = nil;
    self.webHistory = [NSMutableArray array];
    self.members = [NSMutableArray array];
    self.queue = [NSMutableArray array];
    self.peerNames = [NSMutableDictionary dictionary];
    self.hostPeer = nil;
    self.hostName = @"";
    self.nowPlayingTitle = @"";
    [self setStatusLine:[NSString stringWithFormat:@"Not in a Jam · %@",
        wasHosting ? @"left the Jam you were hosting" : @"left the host"]];
    [self post];
}

#pragma mark Transport callbacks

- (void)peerConnected:(NSString *)peer name:(NSString *)name {
    if (![peer isKindOfClass:NSString.class] || !peer.length) return;
    self.peerNames[peer] = cappedName(name);
    if (!self.hosting) return;
    [self setStatusLine:
        [NSString stringWithFormat:@"Hosting · %@ is connected", self.peerNames[peer]]];
}

- (void)peerDisconnected:(NSString *)peer {
    if (![peer isKindOfClass:NSString.class]) return;
    NSString *name = self.peerNames[peer];
    [self.peerNames removeObjectForKey:peer];
    if (self.hosting && name) {
        NSMutableArray *members = [NSMutableArray array];
        for (NSDictionary *at in self.members) {
            if ([at[@"n"] isKindOfClass:NSString.class] && [at[@"n"] isEqualToString:name] &&
                ![at[@"you"] boolValue]) continue;
            [members addObject:at];
        }
        if (members.count != self.members.count) {
            self.members = members;
            [self tellEveryone:[self membersPayload]];
        }
        [self setStatusLine:@"Hosting · a listener left"];
        return;
    }
    if (!self.hosting && self.hostPeer && [peer isEqualToString:self.hostPeer]) [self leave];
}
#pragma mark Message validation

// A phone is the trust boundary; every field is type-checked, every string
// capped, every index bounded, and unknown shapes are dropped without acting.
static BOOL text(NSDictionary *message, NSString *key, NSString **out) {
    id at = message[key];
    if (![at isKindOfClass:NSString.class]) return NO;
    *out = at;
    return YES;
}

static double number(NSDictionary *message, NSString *key, double fallback) {
    id at = message[key];
    double value = [at isKindOfClass:NSNumber.class] ? [(NSNumber *)at doubleValue] : fallback;
    return isfinite(value) ? value : fallback;
}

static BOOL gated(NSDictionary *message, NSString *key) {
    id at = message[key];
    return [at respondsToSelector:NSSelectorFromString(@"boolValue")] ? [at boolValue] : NO;
}

- (void)receive:(NSDictionary *)message from:(NSString *)peer {
    if (![message isKindOfClass:NSDictionary.class] || ![peer isKindOfClass:NSString.class]) return;
    NSString *kind;
    if (!text(message, @"t", &kind)) return;
    if (!self.joined) return;
    if (self.hosting) {
        if (!self.peerNames[peer]) return;   // only phones this session knows
    } else if (![peer isEqualToString:self.hostPeer]) {
        return;                              // guests only listen to their own host
    } else {
        self.lastHostWord = nowMillis();
    }
    if ([kind isEqual:@"JOIN"]) {
        [self receiveJoin:message peer:peer];
    } else if ([kind isEqual:@"INIT"]) {
        if (!self.hosting) [self receiveIntroduction:message];
    } else if ([kind isEqual:@"MEMBERS"]) {
        if (!self.hosting) [self receiveMembers:message];
    } else if ([kind isEqual:@"Q"]) {
        if (!self.hosting) [self receiveQueue:message];
    } else if ([kind isEqual:@"GC"]) {
        if (!self.hosting) {
            _guestControl = gated(message, @"g");
            [self setStatusLine:self.guestControl ?
                @"Pass the aux is on" : @"Pass the aux is off"];
        }
    } else if ([kind isEqual:@"PLAY"]) {
        if (!self.hosting) [self receivePlay:message];
    } else if ([kind isEqual:@"PAUSE"]) {
        if (!self.hosting) {
            self.pendingHostPaused = YES;
            pausePlayback();
            self.remoteOpAt = nowMillis();
            [self setStatusLine:@"Following · paused"];
        }
    } else if ([kind isEqual:@"SEEK"]) {
        if (!self.hosting) [self receiveSeek:message];
    } else if ([kind isEqual:@"TICK"]) {
        if (!self.hosting) [self receiveTick:message];
    } else if ([kind isEqual:@"SYNC"]) {
        [self tellPeer:peer message:self.playPayload];
    } else if ([kind isEqual:@"CMD"]) {
        [self receiveCommand:message peer:peer];
    } else if ([kind isEqual:@"ADD"]) {
        [self receiveAdd:message peer:peer];
    } else if ([kind isEqual:@"PING"]) {
        id stamp = [message[@"ts"] isKindOfClass:NSNumber.class] ? message[@"ts"] : nil;
        [self tellPeer:peer message:stamp ?
            @{@"t": @"PONG", @"ts": stamp} : @{@"t": @"PONG", @"ts": @(0)}];
    } else if ([kind isEqual:@"PONG"]) {
        if (!self.hosting) {
            double roundTrip = nowMillis() - number(message, @"ts", 0);
            self.pingMillis = !isnan(roundTrip) && roundTrip < 60000 && roundTrip > 0 ? roundTrip : -1;
        }
    }
}
#pragma mark Host receives

- (NSString *)memberNameForPeer:(NSString *)peer {
    return cappedName(self.peerNames[peer]) ?: @"Listener";
}

- (void)receiveJoin:(NSDictionary *)message peer:(NSString *)peer {
    if (!self.hosting) return;
    NSString *wantsControl;
    if (!text(message, @"n", &wantsControl)) return;
    wantsControl = cappedName(wantsControl);
    if (wantsControl.length >= kMemberLimit) return;
    BOOL known = NO;
    for (NSDictionary *at in self.members)
        if ([at[@"n"] isKindOfClass:NSString.class] && [at[@"n"] isEqualToString:wantsControl])
            known = YES;
    if (!known && self.members.count < kMemberLimit)
        [self.members addObject:[self member:wantsControl host:NO you:NO]];
    [self tellPeer:peer message:@{@"t": @"INIT", @"h": self.thisName,
        @"m": self.members, @"g": [NSNumber numberWithBool:self.guestControl]}];
    [self tellPeer:peer message:self.playPayload];
    [self tellPeer:peer message:self.queuePayload];
    [self tellEveryone:[self membersPayload]];
    [self setStatusLine:[NSString stringWithFormat:@"Hosting · %@ joined", wantsControl]];
    [self post];
}

// Guests control the host only when the host has passed the aux, at most one
// command of a kind per peer every 500 ms so a stuck guest cannot spam it.
- (BOOL)commandAllowedFrom:(NSString *)peer verb:(NSString *)verb {
    double at = nowMillis();
    NSString *slot = [NSString stringWithFormat:@"%@:%@", peer, verb ?: @""];
    double last = self.commandAt[slot].doubleValue;
    if (at - last < kCommandThrottle) return NO;
    self.commandAt[slot] = @(at);
    return self.guestControl;
}

- (void)receiveCommand:(NSDictionary *)message peer:(NSString *)peer {
    if (!self.hosting) return;
    NSString *verb;
    if (!text(message, @"a", &verb)) return;
    if (!verb.length || verb.length > 8) return;
    if (![self commandAllowedFrom:peer verb:verb]) return;
    self.remoteOpAt = nowMillis();
    if ([verb isEqual:@"play"]) {
        resumePlayback();
        [self tellEveryone:self.playPayload];
    } else if ([verb isEqual:@"pause"]) {
        pausePlayback();
        [self tellEveryone:@{@"t": @"PAUSE"}];
    } else if ([verb isEqual:@"next"]) {
        [self playQueuedHead];
    } else if ([verb isEqual:@"back"]) {
        skipToPreviousNative();
    } else if ([verb isEqual:@"seek"]) {
        double at = number(message, @"p", -1);
        if (at >= 0) {
            seekSeconds(at / 1000.0);
            [self tellEveryone:@{@"t": @"SEEK", @"p": @(at), @"ts": @(nowMillis())}];
        }
    }
}

- (void)receiveAdd:(NSDictionary *)message peer:(NSString *)peer {
    if (!self.hosting || self.queue.count >= kQueueLimit) return;
    SGLocalJamEntry *entry = [SGLocalJamEntry fromDictionary:message];
    if (!entry) return;
    for (SGLocalJamEntry *at in self.queue) if ([at.uri isEqualToString:entry.uri]) return;
    entry.addedBy = [self memberNameForPeer:peer];
    [_queue addObject:entry];
    enqueueTrackInSpotify(entry.uri);
    [self publishQueue];
    [self setStatusLine:
        [NSString stringWithFormat:@"Hosting · %@ added a song", entry.addedBy]];
}
#pragma mark Guest receives

- (void)replaceMembers:(id)list {
    NSMutableArray *fresh = [NSMutableArray array];
    if (![list isKindOfClass:NSArray.class]) list = nil;
    if (list) for (NSDictionary *at in [(NSArray *)list subarrayWithRange:NSMakeRange(0, MIN((int)[(NSArray *)list count], kMemberLimit))]) {
        if (![at isKindOfClass:NSDictionary.class]) continue;
        NSString *name = at[@"n"];
        if (![name isKindOfClass:NSString.class]) continue;
        [fresh addObject:[self member:name host:gated(at, @"h") you:NO]];
    }
    self.members = fresh;
    [self post];
}

- (void)receiveIntroduction:(NSDictionary *)message {
    NSString *host;
    if (text(message, @"h", &host)) self.hostName = cappedName(host);
    _guestControl = gated(message, @"g");
    [self receiveMembers:message];
    [self setStatusLine:[NSString stringWithFormat:@"Guest of %@ · syncing", self.hostName]];
    [self post];
}

- (void)receiveMembers:(NSDictionary *)message {
    [self replaceMembers:message[@"m"]];
}

- (void)receiveQueue:(NSDictionary *)message {
    NSMutableArray *fresh = [NSMutableArray array];
    id list = message[@"q"];
    if (![list isKindOfClass:NSArray.class]) return;
    for (NSDictionary *at in [(NSArray *)list subarrayWithRange:NSMakeRange(0, MIN((int)[(NSArray *)list count], kQueueLimit))]) {
        SGLocalJamEntry *entry = [SGLocalJamEntry fromDictionary:at];
        if (entry) [fresh addObject:entry];
    }
    self.queue = fresh;
    [self post];
}

// Where follow mode moves a guest's own player: reach the song, then land on the
// host's position. Failure degrades to "start it here and we keep following".
- (void)receivePlay:(NSDictionary *)message {
    NSString *uri, *nowTitle;
    text(message, @"u", &uri);
    text(message, @"n", &nowTitle);
    self.nowPlayingTitle = nowTitle ?: @"";
    double hostPosition = number(message, @"p", 0);
    BOOL hostPaused = gated(message, @"pa");
    self.pendingHostPaused = hostPaused;
    if (self.loadEntry && [self.loadEntry.uri isEqualToString:uri]) {
        self.pendingHostPosition = MAX(0, hostPosition);
        return;
    }
    NSString *atURI = stateURI();
    BOOL sameSong = atURI && uri.length && [atURI isEqualToString:uri];
    if (sameSong && hostPaused) {
        pausePlayback();
        [self setStatusLine:@"Following · paused"];
        return;
    }
    self.remoteOpAt = nowMillis();
    if (sameSong) {
        resumePlayback();
        [self setStatusLine:@"Following"];
        return;
    }
    if (!uri.length) return;
    if (!SGPlaybackPlayer()) {
        [self setStatusLine:
            [NSString stringWithFormat:@"Spotify is not ready to start %@", self.nowPlayingTitle]];
        return;
    }
    if ([self beginFollowOf:uri at:hostPosition]) [self setStatusLine:@"Following · reaching the song"];
    else [self setStatusLine:[NSString stringWithFormat:
        @"Can't start %@ here · open it on this iPhone and following resumes",
        self.nowPlayingTitle ?: @"the host's song"]];
}

// Seeks once the guest's player has reached the song, or admits the miss.
- (BOOL)beginFollowOf:(NSString *)uri at:(double)hostPosition {
    self.loadEntry = [SGLocalJamEntry entryWithURI:uri title:self.nowPlayingTitle artist:nil];
    self.loadPolls = 0;
    self.loadingTrack = NO;
    if (!playTrackOnDevice(uri)) {
        self.loadEntry = nil;
        self.following = NO;
        return NO;
    }
    self.loadingTrack = YES;
    self.pendingHostPosition = MAX(0, hostPosition);
    return YES;
}

// One landing, bounded retries: runs from the beat and from the observer's
// callback, whichever reaches the song first.
- (void)pollFollowLoad {
    if (!self.loadEntry) return;
    SPTPlayerState *fresh = state();
    NSString *atURI = SGURIString(fresh.track.URI) ?: @"";
    if (atURI.length && [atURI isEqualToString:self.loadEntry.uri]) {
        SGLocalJamEntry *spent = self.loadEntry;
        self.loadEntry = nil;
        self.loadingTrack = NO;
        self.appliedAt = nowMillis();
        double latency = self.pingMillis > 0 ? self.pingMillis / 2.0 : 0;
        seekSeconds(MAX(0, self.pendingHostPosition + latency) / 1000.0);
        if (self.pendingHostPaused) pausePlayback();
        else resumePlayback();
        self.following = YES;
        [self setStatusLine:
            [NSString stringWithFormat:@"Following · %@", spent.title ?: @"the host's song"]];
        return;
    }
    if (++self.loadPolls > kPollLimit) {   // beats of 400 ms; the venue moved on
        SGLocalJamEntry *missed = self.loadEntry;
        self.loadEntry = nil;
        self.loadingTrack = NO;
        self.following = NO;
        [self setStatusLine:
            [NSString stringWithFormat:@"Spotify did not reach %@ here · open it and following resumes",
                missed.title ?: @"the song"]];
        return;
    }

}

- (void)receiveSeek:(NSDictionary *)message {
    double hostPosition = number(message, @"p", -1);
    if (hostPosition < 0) return;
    if (self.loadEntry) {   // don't fight the landing
        self.pendingHostPosition = hostPosition;
        return;
    }
    self.appliedAt = nowMillis();
    double latency = self.pingMillis > 0 ? self.pingMillis / 2.0 : 0;
    seekSeconds(MAX(0, hostPosition + latency) / 1000.0);
    [self setStatusLine:@"Following · rewound"];
}

// Steady drift correction with the zones set above; reads the established
// position rule. Skips its corrections while a recent remote op settles in.
- (void)receiveTick:(NSDictionary *)message {
    if (self.loadEntry) {
        self.pendingHostPosition = number(message, @"p", self.pendingHostPosition);
        return;
    }
    SPTPlayerState *at = state();
    if (!at || at.isPaused) return;
    double hostPosition = number(message, @"p", -1);
    if (hostPosition < 0) return;
    double stamp = nowMillis();
    if (stamp - self.appliedAt < kIgnoreAfterAppliedSync) return;
    if (stamp - self.remoteOpAt < kIgnoreAfterRemoteOp) return;
    if (!at.isPlaying) return;
    double latency = self.pingMillis > 0 ? self.pingMillis / 2.0 : 0;
    double expected = hostPosition + latency;
    double localNow = (at.isPaused ? at.positionAsOfTimestamp : at.position) * 1000.0;
    double noise = fabs(localNow - expected);
    self.driftEMA = self.driftEMA <= 0 ? noise : 0.7 * self.driftEMA + 0.3 * noise;
    if (self.driftEMA < kSmallDrift) {
        self.driftConfirmed = 0;
        return;
    }
    if (self.driftEMA < kLargeDrift && ++self.driftConfirmed < 2) return;
    self.driftConfirmed = 0;
    self.appliedAt = stamp;
    resumePlayback();
    seekSeconds(expected / 1000.0);
    [self setStatusLine:@"Following · nudged"];
}

#pragma mark The beat (400 ms cadence)

- (void)beat:(double)stamp {
    if (!self.joined) return;
    if (self.hosting) {
        [self hostBeat:stamp];
    } else {
        [self guestBeat:stamp];
    }
}

- (void)beat {
    [self beat:nowMillis()];
}

- (void)hostBeat:(double)stamp {
    SPTPlayerState *at = state();
    if (at && at.isPlaying && !at.isPaused) {
        double now = MAX(0, at.position) * 1000.0;
        double expected = self.localProgress + (stamp - self.progressAt);
        if (self.progressAt > 0 && stamp - self.remoteOpAt > kCommandThrottle &&
            fabs(now - expected) > kSeekDetectJump) {
            // The host dragged Spotify's own scrubber; relay the jump.
            [self tellEveryone:@{@"t": @"SEEK", @"p": @(now), @"ts": @(stamp)}];
        }
        self.localProgress = now;
        self.progressAt = stamp;
        if (++self.tickCount >= kTickBeats) {
            self.tickCount = 0;
            [self tellEveryone:@{@"t": @"TICK", @"p": @(now), @"ts": @(stamp)}];
        }
    } else {
        self.progressAt = stamp;
    }
}

- (void)guestBeat:(double)stamp {
    [self pollFollowLoad];
    if (stamp - self.lastHostWord > kGuestSilence && self.lastHostWord > 0) {
        [self setStatusLine:@"Lost the host · reconnect over their Local Jam page"]; 
        self.lastHostWord = stamp;
        return;
    }
    if (self.loadEntry) return;
    if (++self.pingCount >= kPingBeats) {
        self.pingCount = 0;
        if (SGPlaybackPlayer()) {
            [self tellPeer:self.hostPeer message:@{@"t": @"PING", @"ts": @(stamp)}];
            if (stamp - self.lastSyncRequest > kIgnoreAfterRemoteOp &&
                self.lastSyncRequest == 0) {
                [self tellPeer:self.hostPeer message:@{@"t": @"SYNC"}];
                self.lastSyncRequest = stamp;
            }
        }
    }
}
#pragma mark What Spotify does here

// The host relays its own player to the room; a guest uses the callback to land
// its delayed start. Everything is state, never opinion.
- (void)playerStateChanged {
    if (!self.joined) return;
    SPTPlayerState *fresh = state();
    if (!fresh) return;
    NSString *atURI = SGURIString(fresh.track.URI) ?: @"";
    if (self.hosting) {
        BOOL changed = ![self.ownURI isEqualToString:atURI];
        NSString *context = SGURIString(fresh.contextURI);
        if (changed) {
            self.ownURI = atURI;
            self.webAdvancedFromURI = nil;
            [self refreshOwnTrack];
        }
        SGLocalJamEntry *active = self.activeWebEntry;
        BOOL activePlaylist = [active.uri hasPrefix:@"spotify:playlist:"];
        if (active && ((activePlaylist && ![active.uri isEqualToString:context]) || (!activePlaylist && changed))) {
            active.requestStatus = @"Played";
            self.activeWebEntry = nil;
        }
        SGLocalJamEntry *head = self.queue.firstObject;
        BOOL playlist = [head.uri hasPrefix:@"spotify:playlist:"];
        SGLocalJamEntry *confirmedEntry = nil;
        if (!fresh.isLoading && atURI.length) {
            if (playlist && self.pendingWebEntry == head && [head.uri isEqualToString:context]) {
                confirmedEntry = head;
            } else {
                for (SGLocalJamEntry *candidate in self.queue) {
                    if (![candidate.uri hasPrefix:@"spotify:playlist:"] && [candidate.uri isEqualToString:atURI]) {
                        confirmedEntry = candidate;
                        break;
                    }
                }
            }
        }
        if (confirmedEntry) {
            [_queue removeObject:confirmedEntry];
            if (confirmedEntry.requestID) {
                confirmedEntry.requestStatus = @"Playing";
                self.activeWebEntry = confirmedEntry;
            }
            if (self.pendingWebEntry == confirmedEntry) self.pendingWebEntry = nil;
            [self publishQueue];
        }
        [self tellEveryone:[self playPayload]];
        [self post];
        return;
    }
    if (self.loadEntry) [self pollFollowState];
}

- (void)pollFollowState {
    if (!self.loadEntry) return;
    NSString *atURI = stateURI();
    if (atURI.length && [atURI isEqualToString:self.loadEntry.uri]) {
        SGLocalJamEntry *spent = self.loadEntry;
        self.loadEntry = nil;
        self.loadingTrack = NO;
        self.appliedAt = nowMillis();
        double latency = self.pingMillis > 0 ? self.pingMillis / 2.0 : 0;
        seekSeconds(MAX(0, self.pendingHostPosition + latency) / 1000.0);
        if (self.pendingHostPaused) pausePlayback();
        else if (!statePlaying()) resumePlayback();
        self.following = YES;
        [self setStatusLine:
            [NSString stringWithFormat:@"Following · %@", spent.title ?: @"the host's song"]];
    }
}

#pragma mark Pages and actions

- (BOOL)addEntryFromOwnPlayer {
    NSString *atURI = stateURI();
    SPTPlayerState *at = state();
    if (self.queue.count >= kQueueLimit) return NO;
    if (!atURI.length || !at) {
        [self setStatusLine:@"No song is playing on this iPhone to share"];
        return NO;
    }
    SGLocalJamEntry *entry = [SGLocalJamEntry entryWithURI:atURI
        title:stateTitle() artist:stateArtist()];
    if (!entry) {
        [self setStatusLine:@"Spotify's player has no song to share right now"];
        return NO;
    }
    for (SGLocalJamEntry *atEntry in self.queue) {
        if ([atEntry.uri isEqualToString:atURI]) {
            [self setStatusLine:@"Already in the shared queue"];
            return NO;
        }
    }
    entry.addedBy = self.thisName;
    [_queue addObject:entry];
    if (self.hosting) enqueueTrackInSpotify(entry.uri);
    [self refreshOwnTrack];
    [self publishQueue];
    [self setStatusLine:[NSString stringWithFormat:
        @"%@ · in the shared queue", self.hosting ? @"Hosting · added" : @"Requested"]];
    return YES;
}

// The host moves its own player to the shared queue head, at most once per
// beat so a stuck entry cannot spam Spotify; guests just ask.
- (void)playQueuedHead {
    if (!self.joined) return;
    double stamp = nowMillis();
    if (!self.hosting) {
        if (stamp - self.lastSyncRequest < kCommandThrottle) return;
        self.lastSyncRequest = stamp;
        [self tellPeer:self.hostPeer message:@{@"t": @"CMD", @"a": @"next"}];
        return;
    }
    if (stamp - self.lastAdvance < kCommandThrottle) return;
    if (!self.queue.count) {
        skipToNextNative();
        return;
    }
    SGLocalJamEntry *head = self.queue.firstObject;
    if (playTrackOnDevice(head.uri)) {
        self.lastAdvance = stamp;
        return;   // the state callback reports the new song and pops the head
    }
    [self setStatusLine:[NSString stringWithFormat:
        @"Couldn't start %@ on this iPhone", head.title ?: @"the next song"]];
}

// Web Jam's requests are already resolved to a track URI; the queue still owns
// the cap and the duplicate rule, so two browser tabs cannot slip past either.
- (BOOL)addWebRequestURI:(NSString *)uri title:(NSString *)title artist:(NSString *)artist {
    return [self addWebRequestURI:uri title:title artist:artist by:@"Guest"];
}

- (BOOL)addWebRequestURI:(NSString *)uri title:(NSString *)title artist:(NSString *)artist by:(NSString *)name {
    if (!self.hosting || ![SGWebJamRequestURI(uri) isEqualToString:uri]) return NO;
    if (self.queue.count >= kQueueLimit) return NO;
    for (SGLocalJamEntry *at in self.queue) if ([at.uri isEqualToString:uri]) return NO;
    SGLocalJamEntry *entry = [SGLocalJamEntry entryWithURI:uri title:title artist:artist];
    if (!entry) return NO;
    entry.addedBy = SGWebJamDisplayName(name);
    entry.requestID = NSUUID.UUID.UUIDString;
    entry.requestStatus = @"Queued";
    if (!self.webHistory) self.webHistory = [NSMutableArray array];
    [_webHistory insertObject:entry atIndex:0];
    if (self.webHistory.count > 100) [_webHistory removeLastObject];
    [_queue addObject:entry];
    enqueueTrackInSpotify(uri);
    [self publishQueue];
    [self setStatusLine:@"Web Jam · a guest added a song"];
    return YES;
}

// The browser queue's one way into the player: only a host moves, only in the
// last 0.75 s, never in a track's first 3 s, and once per current track so a
// slow tick cannot ask Spotify for the same skip twice.
- (void)updateWebRequest:(SGLocalJamEntry *)entry title:(NSString *)title artist:(NSString *)artist {
    if (!self.hosting || !entry || (![self.queue containsObject:entry] && ![self.webHistory containsObject:entry])) return;
    SGLocalJamEntry *resolved = [SGLocalJamEntry entryWithURI:entry.uri title:title artist:artist];
    entry.title = resolved.title;
    entry.artist = resolved.artist;
    [self publishQueue];
}

- (BOOL)playWebRequestAtEnd {
    if (!self.hosting || !self.queue.count) return NO;
    if (self.pendingWebEntry) {
        if (nowMillis() - self.pendingWebAt < 12000) return NO;
        self.pendingWebEntry.requestStatus = @"Unavailable";
        [_queue removeObject:self.pendingWebEntry];
        self.pendingWebEntry = nil;
        self.webAdvancedFromURI = nil;
        [self publishQueue];
        return NO;
    }
    SPTPlayerState *at = state();
    if (!at || !at.isPlaying || at.isPaused) return NO;
    double position = at.position, duration = at.duration;
    if (!isfinite(position) || !isfinite(duration)) return NO;
    if (position < 3.0 || duration <= 0 || position < duration - 0.75) return NO;
    NSString *currentURI = stateURI();
    if (!currentURI.length || [self.webAdvancedFromURI isEqualToString:currentURI]) return NO;
    SGLocalJamEntry *head = self.queue.firstObject;
    if (!head.uri.length) return NO;
    self.webAdvancedFromURI = currentURI;
    self.pendingWebEntry = head; self.pendingWebAt = nowMillis();
    BOOL started = skipToFutureTrack(head.uri);
    if (started) resumePlayback();
    else started = playTrackOnDevice(head.uri);
    if (!started) {
        head.requestStatus = @"Unavailable";
        [_queue removeObject:head]; self.pendingWebEntry = nil;
        [self publishQueue];
        [self setStatusLine:[NSString stringWithFormat:
            @"Web Jam · Spotify could not start %@", head.title ?: @"the request"]];
        return NO;
    }
    [self setStatusLine:[NSString stringWithFormat:
        @"Web Jam · starting %@", head.title ?: @"a guest's request"]];
    return YES;
}

- (void)queueCurrentTrack {
    if (!self.joined) {
        [self setStatusLine:@"Start or join a Local Jam first"];
        return;
    }
    if (self.hosting) { [self addEntryFromOwnPlayer]; return; }
    double stamp = nowMillis();
    if (stamp - self.lastSyncRequest < kCommandThrottle) return;
    self.lastSyncRequest = stamp;
    NSString *atURI = stateURI();
    SPTPlayerState *at = state();
    if (!atURI.length || !at) {
        [self setStatusLine:@"No song is playing on this iPhone to suggest"];
        return;
    }
    [self tellPeer:self.hostPeer message:@{@"t": @"ADD", @"u": atURI,
        @"ti": stateTitle(), @"ar": stateArtist(), @"by": self.thisName}];
    [self setStatusLine:@"Suggested this song to the host"];
}

- (void)guestCommand:(NSString *)verb {
    if (self.hosting || !self.connected || !verb.length) return;
    if ([verb isEqual:@"seek"] || (![verb isEqual:@"play"] && ![verb isEqual:@"pause"] &&
        ![verb isEqual:@"next"] && ![verb isEqual:@"back"])) return;
    double stamp = nowMillis();
    if (stamp - self.lastSyncRequest < kCommandThrottle) return;
    self.lastSyncRequest = stamp;
    [self tellPeer:self.hostPeer message:@{@"t": @"CMD", @"a": verb}];
}

- (void)guestSeek:(double)seconds {
    if (self.hosting || !self.connected) return;
    double stamp = nowMillis();
    if (stamp - self.lastSyncRequest < kCommandThrottle) return;
    self.lastSyncRequest = stamp;
    [self tellPeer:self.hostPeer message:
        @{@"t": @"CMD", @"a": @"seek", @"p": [NSNumber numberWithDouble:seconds * 1000.0]}];
}

@end
