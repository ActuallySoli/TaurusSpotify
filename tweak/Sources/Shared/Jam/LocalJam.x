// The wiring between the session protocol and the phone: MultipeerConnectivity
// discovery over the local network, Spotify's player observations and the 400 ms
// beat that keeps the room in step. Everything is marshalled to the main thread;
// the protocol itself is in LocalJam.m, checked without a transport by the Mac
// fixture.
#import "Core/SGCore.h"
#import "Core/SGLog.h"
#import "Shared/Player/PlayerState.h"
#import "LocalJam.h"
#import "WebJam.h"
#import <MultipeerConnectivity/MultipeerConnectivity.h>

#define kBeatSeconds 0.4   // the hub's cadence unit, from its .m

@interface SGLocalJamRuntime : NSObject <MCSessionDelegate,
    MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate, SGPlayerStateObserver>
@end

static SGLocalJamRuntime *sg_runtime;

// The service both ends advertise and browse; declared in plist/liquid-glass.plist.
NSString *const SGLocalJamServiceType = @"taurusjam";

@implementation SGLocalJamRuntime {
    MCSession *_session;
    MCNearbyServiceAdvertiser *_advertiser;
    MCNearbyServiceBrowser *_browser;
    SGLocalJamHub *_hub;
    NSMutableDictionary<NSString *, MCPeerID *> *_peers;   // minted key -> peer
    NSMutableSet<NSString *> *_hostKeys;                   // peers currently hosts
    NSString *_pendingJoin;                                // the invitation we sent
    MCPeerID *_selfPeer;
    BOOL _hostFlag;                                        // what _advertiser advertises
    BOOL _wasJoined;                                       // the joined edge, for transport teardown
    id _changeObserver;
    NSTimer *_beat;
}

#pragma mark Peer keys

// MCPeerID has no exposed identifier: displayName is its only name. Keys widen
// when a second phone shares the first's name, and stay put for each object.
- (NSString *)keyForPeerID:(MCPeerID *)peerID {
    if (!peerID) return nil;
    for (NSString *key in _peers)
        if ([_peers[key] isEqual:peerID]) return key;
    NSString *name = [peerID.displayName stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length) name = @"iPhone";
    NSString *key = name;
    NSInteger bump = 1;
    while (_peers[key]) key = [NSString stringWithFormat:@"%@ %ld", name, (long)(++bump)];
    _peers[key] = peerID;
    return key;
}

- (void)dropPeerID:(MCPeerID *)peerID {
    for (NSString *key in _peers.allKeys) {
        if (![_peers[key] isEqual:peerID]) continue;
        [_peers removeObjectForKey:key];
        [_hostKeys removeObject:key];
    }
}

- (void)postChange {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:SGLocalJamDidChangeNotification object:nil];
}

// A leave clears the hub, but the transport has to let go too: otherwise guests stay attached to a
// dead room and a rejoin never gets a fresh handshake.
- (void)resetTransport {
    [_session disconnect];
    _session = [[MCSession alloc] initWithPeer:_selfPeer
        securityIdentity:nil encryptionPreference:MCEncryptionRequired];
    _session.delegate = self;
    [_peers removeAllObjects];
    [_hostKeys removeAllObjects];
    _pendingJoin = nil;
}

// The Join list only offers phones wearing the host mark, which keeps a guest
// from being invited into itself. The plain advertiser's discovery info is fixed
// at init, so a hosting flip rebuilds it; sessions already made stay connected.
- (void)syncAdvertising {
    if (!_selfPeer || _hostFlag == _hub.hosting) return;
    _hostFlag = _hub.hosting;
    [_advertiser stopAdvertisingPeer];
    _advertiser = [[MCNearbyServiceAdvertiser alloc] initWithPeer:_selfPeer
        discoveryInfo:_hostFlag ? @{@"v": @"1", @"h": @"1"} : @{@"v": @"1"}
        serviceType:SGLocalJamServiceType];
    _advertiser.delegate = self;
    [_advertiser startAdvertisingPeer];
}

- (void)start {
    if (!NSClassFromString(@"MCSession")) {
        SGLog(@"local jam: no MultipeerConnectivity on this build");
        return;
    }
    __weak SGLocalJamRuntime *me = self;
    _hub = SGLocalJamHubShared();
    _peers = [NSMutableDictionary dictionary];
    _hostKeys = [NSMutableSet set];
    NSString *name = [UIDevice.currentDevice.name stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (name.length > 40 || !name.length) name = @"iPhone";
    MCPeerID *peer = _selfPeer = [[MCPeerID alloc] initWithDisplayName:name];
    _session = [[MCSession alloc] initWithPeer:peer
        securityIdentity:nil encryptionPreference:MCEncryptionRequired];
    _session.delegate = self;
    _advertiser = [[MCNearbyServiceAdvertiser alloc] initWithPeer:peer
        discoveryInfo:@{@"v": @"1"} serviceType:SGLocalJamServiceType];
    _advertiser.delegate = self;
    [_advertiser startAdvertisingPeer];
    _browser = [[MCNearbyServiceBrowser alloc] initWithPeer:peer
        serviceType:SGLocalJamServiceType];
    _browser.delegate = self;
    [_browser startBrowsingForPeers];
    _hub.send = ^(NSString *to, NSDictionary *message) {
        [me deliver:message to:to];
    };
    _changeObserver = [NSNotificationCenter.defaultCenter addObserverForName:SGLocalJamDidChangeNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            SGLocalJamRuntime *strong = me;
            if (!strong) return;
            [strong syncAdvertising];   // the host mark goes on when hosting starts, off when it ends
            // Only a joined → left edge tears the transport down; while merely browsing, discovery
            // notifications must not clear the peers the Join list is built from.
            BOOL joined = strong->_hub.joined;
            if (strong->_wasJoined && !joined) [strong resetTransport];
            strong->_wasJoined = joined;
        }];
    SGAddPlayerStateObserver(self);
    _beat = [NSTimer timerWithTimeInterval:kBeatSeconds target:self
        selector:@selector(beatTick:) userInfo:nil repeats:YES];
    [NSRunLoop.currentRunLoop addTimer:_beat forMode:NSRunLoopCommonModes];
}

- (void)stop {
    [_beat invalidate];
    _beat = nil;
    if (_changeObserver) [NSNotificationCenter.defaultCenter removeObserver:_changeObserver];
    _changeObserver = nil;
    [_advertiser stopAdvertisingPeer];
    [_browser stopBrowsingForPeers];
    _advertiser.delegate = nil;
    _browser.delegate = nil;
    _session.delegate = nil;
    [_session disconnect];
    _session = nil;
    _hub.send = nil;
}

- (void)deliver:(NSDictionary *)message to:(NSString *)key {
    NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    if (!data || data.length > 32768) return;
    MCPeerID *peer = key ? _peers[key] : nil;
    if (key && !peer) return;
    NSArray<MCPeerID *> *targets = peer ? @[peer] : _session.connectedPeers;
    if (targets.count)
        [_session sendData:data toPeers:targets withMode:MCSessionSendDataReliable error:nil];
}

- (void)beatTick:(NSTimer *)timer {
    (void)timer;
    [_hub beat];
}

#pragma mark Nearby

- (void)browser:(MCNearbyServiceBrowser *)browser foundPeer:(MCPeerID *)peerID
    withDiscoveryInfo:(NSDictionary<NSString *, NSString *> *)info {
    dispatch_async(dispatch_get_main_queue(), ^{
        (void)browser;
        NSString *key = [self keyForPeerID:peerID];
        if ([info[@"h"] isEqual:@"1"]) [self->_hostKeys addObject:key];
        else [self->_hostKeys removeObject:key];
        [self postChange];
    });
}

- (void)browser:(MCNearbyServiceBrowser *)browser lostPeer:(MCPeerID *)peerID {
    dispatch_async(dispatch_get_main_queue(), ^{
        (void)browser;
        NSString *key = [self keyForPeerID:peerID];
        [self->_hostKeys removeObject:key];
        if (![self->_session.connectedPeers containsObject:peerID]) [self dropPeerID:peerID];
        [self postChange];
    });
}

- (void)browser:(MCNearbyServiceBrowser *)browser didNotStartBrowsingForPeers:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        (void)browser;
        SGLog(@"local jam: browse failed: %@", error.localizedDescription);
        [self->_hub setStatusLine:@"Nearby discovery could not start · allow Local Network"];
    });
}

- (void)advertiser:(MCNearbyServiceAdvertiser *)advertiser didNotStartAdvertisingPeer:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        (void)advertiser;
        SGLog(@"local jam: advertise failed: %@", error.localizedDescription);
        [self->_hub setStatusLine:@"Advertising could not start · allow Local Network"];
    });
}

// Only a host accepts joiners; a guest declines or it would mime a second room.
- (void)advertiser:(MCNearbyServiceAdvertiser *)advertiser
    didReceiveInvitationFromPeer:(MCPeerID *)peerID withContext:(NSData *)context
    invitationHandler:(void (^)(BOOL, MCSession *))invitationHandler {
    (void)advertiser;
    (void)peerID;
    (void)context;
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL accept = self->_hub.hosting && self->_session;
        invitationHandler(accept, accept ? self->_session : nil);
    });
}

#pragma mark Session

- (void)session:(MCSession *)session peer:(MCPeerID *)peerID didChangeState:(MCSessionState)state {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (session != self->_session) return;
        NSString *key = [self keyForPeerID:peerID];
        if (state == MCSessionStateConnected) {
            [self->_hub peerConnected:key name:peerID.displayName];
            if ([self->_pendingJoin isEqualToString:key]) {
                self->_pendingJoin = nil;
                [self->_hub join:key name:peerID.displayName];
            }
        } else if (state == MCSessionStateNotConnected) {
            if ([self->_pendingJoin isEqualToString:key]) self->_pendingJoin = nil;
            [self dropPeerID:peerID];
            [self->_hub peerDisconnected:key];
            [self postChange];
        }
    });
}

- (void)session:(MCSession *)session didReceiveData:(NSData *)data fromPeer:(MCPeerID *)peerID {
    if (data.length > 32768) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (session != self->_session) return;
        NSDictionary *message = [NSJSONSerialization JSONObjectWithData:data
            options:NSJSONReadingAllowFragments | NSJSONReadingMutableContainers error:nil];
        if (!message) return;
        [self->_hub receive:message from:[self keyForPeerID:peerID]];
    });
}

// The room is JSON data only: a streamed or resource-bearing request is not a
// Jam message, so the stream closes and any finished download is deleted.
- (void)session:(MCSession *)session didReceiveStream:(NSInputStream *)stream
    withName:(NSString *)streamName fromPeer:(MCPeerID *)peerID {
    (void)session;
    (void)streamName;
    (void)peerID;
    [stream close];
}

- (void)session:(MCSession *)session didStartReceivingResourceWithName:(NSString *)name
    fromPeer:(MCPeerID *)peerID withProgress:(NSProgress *)progress {
    (void)session;
    (void)name;
    (void)peerID;
    (void)progress;
}

- (void)session:(MCSession *)session didFinishReceivingResourceWithName:(NSString *)name
    fromPeer:(MCPeerID *)peerID atURL:(NSURL *)atURL withError:(NSError *)error {
    (void)session;
    (void)name;
    (void)peerID;
    (void)error;
    if (atURL) [[NSFileManager defaultManager] removeItemAtURL:atURL error:nil];
}

// The observed player moved on this phone: the host tells the room, a guest
// settles a late track start through it.
- (void)playerStateDidChange:(SPTPlayerState *)state {
    (void)state;
    [_hub playerStateChanged];
}

#pragma mark Public handles

- (NSArray<NSString *> *)nearbyNames {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *key in _hostKeys)
        if (_peers[key]) [names addObject:key];
    return names;
}

- (BOOL)joinNamed:(NSString *)key {
    MCPeerID *at = key ? _peers[key] : nil;
    if (!at || ![_hostKeys containsObject:key]) return NO;
    _pendingJoin = key;
    [_browser invitePeer:at toSession:_session withContext:nil timeout:30.0];
    return YES;
}

@end

#pragma mark C surface for the settings page

void SGLocalJamRuntimeStart(void) {
    if (sg_runtime || (!SGHidden(SGKeyLocalJam) && !SGWebJamEnabled())) return;
    sg_runtime = [SGLocalJamRuntime new];
    [sg_runtime start];
}

void SGLocalJamRuntimeStopIfUnused(void) {
    if (SGLocalJamEnabled() || SGWebJamEnabled() || SGLocalJamHubShared().joined) return;
    [sg_runtime stop];
    sg_runtime = nil;
}

NSArray<NSString *> *SGLocalJamNearbyNames(void) {
    return sg_runtime ? [sg_runtime nearbyNames] : @[];
}

BOOL SGLocalJamJoinNamed(NSString *key) {
    return sg_runtime ? [sg_runtime joinNamed:key] : NO;
}

%ctor {
    SGLocalJamRuntimeStart();
}
