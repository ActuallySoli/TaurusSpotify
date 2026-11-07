#import "Core/SGCore.h"
#import "Shared/Gestures/Gestures.h"
#import "Shared/Haptics/Haptics.h"
#import "Shared/Player/SpeedPitch.h"
#import <objc/runtime.h>

static char kHoldKey;

@interface SGNCoverHold : UILongPressGestureRecognizer
@end

@implementation SGNCoverHold {
    double _before;
}

- (void)sgn_held {
    UIView *cover = self.view;
    if (self.state == UIGestureRecognizerStateBegan) {
        CGFloat x = [self locationInView:cover].x, third = cover.bounds.size.width / 3;
        if (!SGGestureHoldOn() || (x > third && x < 2 * third) || !SGPlayerSpeedAllowed()) {
            self.enabled = NO;
            self.enabled = YES;
            return;
        }
        double speed = SGGestureHoldSpeed();
        _before = SGPlayerSpeed();
        SGSetPlayerSpeed(speed);
        SGPlayFeedback(SGFeedbackGrab);
    } else if (self.state == UIGestureRecognizerStateEnded || self.state == UIGestureRecognizerStateCancelled
               || self.state == UIGestureRecognizerStateFailed) {
        if (_before > 0) SGSetPlayerSpeed(_before);
        _before = 0;
    }
}

@end

static void watchHold(UIView *tilt) {
    if (objc_getAssociatedObject(tilt, &kHoldKey)) return;
    SGNCoverHold *hold = [[SGNCoverHold alloc] initWithTarget:nil action:nil];
    [hold addTarget:hold action:@selector(sgn_held)];
    hold.minimumPressDuration = 0.35;
    [tilt addGestureRecognizer:hold];
    objc_setAssociatedObject(tilt, &kHoldKey, hold, OBJC_ASSOCIATION_ASSIGN);
}

%hook _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView
- (void)handleTap {
    if (SGFlag(SGKeyGestures, NO)) return;
    %orig;
}
- (void)layoutSubviews {
    %orig;
    UIView *tilt = (UIView *)self;
    if (tilt.bounds.size.width >= 200) watchHold(tilt);
}
%end

%hook _TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView
- (void)layoutSubviews {
    %orig;
    SGGestureAttach((UIView *)self);
}
%end

%ctor {
    if (!SGNativeUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView",
        @"_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView",
    ]);
}
