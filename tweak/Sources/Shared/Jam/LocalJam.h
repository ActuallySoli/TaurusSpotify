#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Settings/SGModPage.h"
#define SGKeyLocalJam @"spotifyglass.jam.local"
#define SGKeyLocalJamAux @"spotifyglass.jam.local.aux"

extern NSNotificationName SGLocalJamDidChangeNotification;

BOOL SGLocalJamEnabled(void);
UIViewController *SGLocalJamPage(void);
void SGLocalJamRuntimeStart(void);
void SGLocalJamRuntimeStopIfUnused(void);

// A song in the shared Jam queue: display fields plus the URI a device needs to reach it.
@interface SGLocalJamEntry : NSObject
@property (nonatomic, copy) NSString *uri;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *addedBy;
@property (nonatomic, copy) NSString *requestID;
@property (nonatomic, copy) NSString *requestStatus;
+ (instancetype)entryWithURI:(NSString *)uri title:(NSString *)title artist:(NSString *)artist;
- (NSDictionary *)dictionary;
@end

// The host/guest session logic, transport-free: the runtime in LocalJam.x bridges
// MultipeerConnectivity into send/received/peer callbacks, so this class and its
// messages are checked by the Mac fixture without any transport.
// All calls are main-thread; messages stay JSON dictionaries of strings and numbers.
@interface SGLocalJamHub : NSObject
@property (nonatomic, readonly, getter=isHosting) BOOL hosting;
@property (nonatomic, readonly) BOOL joined;        // hosting or connected to a host
@property (nonatomic, readonly) BOOL following;     // guest playing the host's current track
@property (nonatomic, readonly) BOOL loadingTrack;  // guest waiting for its player to reach the host's track
@property (nonatomic, readonly, copy) NSString *status;
@property (nonatomic, readonly, copy) NSString *hostName;
@property (nonatomic, readonly, copy) NSString *nowPlayingTitle;   // display only
@property (nonatomic, readonly) NSArray<NSString *> *memberNames;
@property (nonatomic, readonly) NSArray<SGLocalJamEntry *> *queue;
@property (nonatomic, readonly) NSArray<SGLocalJamEntry *> *webHistory;
@property (nonatomic, readonly) NSInteger ping;     // round-trip milliseconds, -1 unknown
@property (nonatomic) BOOL guestControl;            // the host's pass-the-aux gate
- (void)setStatusLine:(NSString *)line;             // the runtime's screens report here too
// Send one message: nil peer means to everyone (host side); the guest sends to @"host".
@property (nonatomic, copy) void (^send)(NSString *peer, NSDictionary *message);
@property (nonatomic, copy) void (^changed)(void);

- (void)peerConnected:(NSString *)peer name:(NSString *)name;
- (void)peerDisconnected:(NSString *)peer;
- (void)receive:(NSDictionary *)message from:(NSString *)peer;
- (void)beat:(double)nowMillis;      // the 400 ms cadence; tests pass time explicitly
- (void)beat;
- (void)playerStateChanged;          // the observed Spotify state moved

- (void)startHost;
- (void)join:(NSString *)peer name:(NSString *)name;
- (void)leave;
- (void)queueCurrentTrack;           // host: add this iPhone's song; guest: request it (aux)
- (void)playQueuedHead;              // host: move the shared queue on and play its first song
- (BOOL)addWebRequestURI:(NSString *)uri title:(NSString *)title artist:(NSString *)artist;
- (BOOL)addWebRequestURI:(NSString *)uri title:(NSString *)title artist:(NSString *)artist by:(NSString *)name;
- (void)updateWebRequest:(SGLocalJamEntry *)entry title:(NSString *)title artist:(NSString *)artist;
- (BOOL)playWebRequestAtEnd;         // host: play the queue's head at the current song's end
- (void)guestCommand:(NSString *)verb;
- (void)guestSeek:(double)seconds;
@end

SGLocalJamHub *SGLocalJamHubShared(void);
// The Join list: keys of nearby phones currently advertising a Jam. The key is
// both the row text and the handle for joining.
NSArray<NSString *> *SGLocalJamNearbyNames(void);
BOOL SGLocalJamJoinNamed(NSString *key);
