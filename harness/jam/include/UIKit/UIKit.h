#import <Foundation/Foundation.h>

// The sole purpose of this shim: the mod's headers are iOS-only by their UIKit
// imports; the Mac fixture compiles them against Foundation.
@class UIColor, UIImage, UIView;
@interface UIViewController : NSObject
@end
@interface UITableViewController : UIViewController
@end
@interface UIDevice : NSObject
@property (nonatomic, readonly) NSString *name;
+ (instancetype)currentDevice;
@end
