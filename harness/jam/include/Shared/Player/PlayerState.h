#import <Foundation/Foundation.h>
#import "Headers/SPTPlayer.h"

// The transport-free pieces of the player the Jam protocol reads; the device
// .x file's part is out of scope here and stubbed per device in main.m.
NSString *SGURIString(id uri);

@protocol SGPlayerStateObserver <NSObject>
- (void)playerStateDidChange:(SPTPlayerState *)state;
@end

void SGAddPlayerStateObserver(id<SGPlayerStateObserver> observer);
SPTPlayerState *SGPlayerState(void);
id<SPTPlayer> SGPlaybackPlayer(void);
