#import <Foundation/Foundation.h>
@interface SPTPlayerTrack : NSObject
@property id URI;
@end
@interface SPTPlayerState : NSObject
@property BOOL isPaused;
@property SPTPlayerTrack *track;
@end
@protocol SGPlayerStateObserver <NSObject>
- (void)playerStateDidChange:(SPTPlayerState *)state;
@end
void SGAddPlayerStateObserver(id<SGPlayerStateObserver> observer);
SPTPlayerState *SGPlayerState(void);
NSString *SGURIString(id uri);
