#import <UIKit/UIKit.h>

#define SGKeyRecapAnnounce @"spotifyglass.recap.announce"
extern NSNotificationName const SGRecapDueDidChangeNotification;

void SGPolarPresentRecapForRange(NSString *title, NSString *subtitle, int64_t since, int64_t until);
UIViewController *SGAllRecapsPage(void);
