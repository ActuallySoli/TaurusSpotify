#import <UIKit/UIKit.h>

#define SGKeyGestures @"spotifyglass.gestures"
#define SGKeyGestureSplit @"spotifyglass.gestures.split"
#define SGKeyGestureStep @"spotifyglass.gestures.step"
#define SGKeyGestureZones @"spotifyglass.gestures.zones"
#define SGKeyGestureHold @"spotifyglass.gestures.hold"
#define SGKeyGestureHoldSpeed @"spotifyglass.gestures.hold.speed"

typedef NS_ENUM(NSInteger, SGGestureAction) {
    SGGestureNothing = 0,
    SGGestureSeekBack,
    SGGestureSeekForward,
    SGGesturePlayPause,
    SGGestureNextTrack,
    SGGesturePreviousTrack,
    SGGestureShuffle,
    SGGestureRepeat,
    SGGestureLike,   // the current song into Liked Songs, through the now playing screen's model
};

void SGPerformGestureAction(SGGestureAction action);

NSArray<NSString *> *SGGestureActionNames(void);
NSArray<NSString *> *SGGestureSplitNames(void);
NSArray<NSNumber *> *SGGestureStepChoices(void);
NSArray<NSNumber *> *SGGestureHoldSpeedChoices(void);

// The split and the seek step as indices into the lists above, and what they mean.
NSInteger SGGestureSplit(void);
NSInteger SGGestureStepChoice(void);
NSInteger SGGestureHoldSpeedChoice(void);
// The split as a grid: 2x1, 3x1 or 3x3.
void SGGestureGrid(NSInteger *columns, NSInteger *rows);
double SGGestureStep(void);
double SGGestureHoldSpeed(void);
BOOL SGGestureHoldOn(void);

// The action of every cell of the current split, row-major, one entry per cell.
NSArray<NSNumber *> *SGGestureZones(void);
void SGSetGestureZone(NSInteger cell, SGGestureAction action);
void SGResetGestureZones(void);
// Which cell of the current split holds `point`, in a view of size `size`.
NSInteger SGGestureCellAt(CGPoint point, CGSize size);

UIViewController *SGGesturesSettingsPage(void);

void SGGestureSetObserver(void (^observer)(SGGestureAction action));

void SGGestureAttach(UIView *host);
