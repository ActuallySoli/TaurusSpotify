#import <UIKit/UIKit.h>

#define SGKeyWebPlayerMotion @"spotifyglass.webplayer.motion"
#define SGKeyWebPlayerControls @"spotifyglass.webplayer.controls"
extern NSNotificationName const SGWebPlayerDidChangeNotification;

// The listener starts off each launch. Each start makes a new bearer link; stop revokes it.
void SGWebPlayerStart(void);
void SGWebPlayerStop(void);
BOOL SGWebPlayerRunning(void);
NSString *SGWebPlayerLink(void);
NSString *SGWebPlayerStatus(void);
UIViewController *SGWebPlayerSettingsPage(void);
