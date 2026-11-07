#import <Foundation/Foundation.h>
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"

NSData *SGWebPlayerFeedJSON(void);
void SGWebPlayerFeedStart(void);
void SGWebPlayerFeedStop(void);
NSString *SGWebPlayerPageHTML(void);
NSString *SGWebPlayerPreferredIPv4(NSArray<NSDictionary<NSString *, NSString *> *> *interfaces);

NSString *SGWebPlayerCoverURL(NSDictionary *metadata);
void SGWebPlayerMediaStart(void);
void SGWebPlayerMediaStop(void);
void SGWebPlayerMediaUpdate(SPTPlayerState *state, NSString *uri);
NSDictionary *SGWebPlayerMediaDescription(void);
NSData *SGWebPlayerMediaRead(NSString *identifier, NSString *range, NSInteger *status, NSString **contentRange);
