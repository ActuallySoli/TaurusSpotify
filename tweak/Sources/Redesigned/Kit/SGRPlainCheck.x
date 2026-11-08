// Plain checkmark (Appearance): Spotify's circled tick on a saved song swapped for a plain checkmark in the accent.
//
// The Add button (id=Components.UI.AddToButton, a UIButton) draws its state with a Lottie animation in a
// StateMicroInteractionView<AddToButtonState> (trees: player 1434-1436, the rows' buttons the same): a plus when the
// song is not saved, an accent circle with a tick when it is. Spotify marks a saved song's button selected ("Added to
// playlist"), so the button's own selected state tells which. Saved, the animation goes transparent and a checkmark of
// the Kit's stands in its place; not saved, Spotify's plus shows as it is.
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "SGRKit.h"
#define SGRKeyPlainCheck @"spotifyglass.redesign.plaincheck"


static const CGFloat kCheckSize = 19;
static char kCheckKey, kAnimationKey;

BOOL SGRPlainCheckOn(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ on = SGHidden(SGRKeyPlainCheck); });
    return on;
}

static UIView *animationIn(UIButton *button) {
    UIView *found = objc_getAssociatedObject(button, &kAnimationKey);
    if (found.superview) return found;
    static Class lottie;
    if (!lottie) lottie = NSClassFromString(@"Lottie.LottieAnimationView");
    found = nil;
    for (UIView *child in button.subviews) {
        for (UIView *inner in child.subviews) {
            if (lottie && [inner isKindOfClass:lottie]) found = inner;
        }
    }
    objc_setAssociatedObject(button, &kAnimationKey, found, OBJC_ASSOCIATION_ASSIGN);
    return found;
}

static void showState(UIButton *button) {
    UIView *animation = animationIn(button);
    if (!animation) return;
    UIImageView *check = objc_getAssociatedObject(button, &kCheckKey);
    BOOL saved = button.isSelected;
    if (saved && !check) {
        UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:kCheckSize weight:UIImageSymbolWeightBold];
        check = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark" withConfiguration:configuration]];
        check.tintColor = SGRAccent();
        check.accessibilityIdentifier = SGRPlainCheckIdentifier;
        check.contentMode = UIViewContentModeCenter;
        check.userInteractionEnabled = NO;
        check.isAccessibilityElement = NO;
        objc_setAssociatedObject(button, &kCheckKey, check, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (check && check.superview != button) [button addSubview:check];
    check.frame = button.bounds;
    check.alpha = saved ? 1 : 0;
    // Alpha, not hidden: Lottie's own state keeps running under it.
    animation.alpha = saved ? 0 : 1;
}

%hook UIButton
- (void)layoutSubviews {
    %orig;
    if (SGRPlainCheckOn() && [self.accessibilityIdentifier isEqualToString:@"Components.UI.AddToButton"]) showState(self);
}

- (void)setSelected:(BOOL)selected {
    %orig;
    if (SGRPlainCheckOn() && [self.accessibilityIdentifier isEqualToString:@"Components.UI.AddToButton"]) showState(self);
}
%end

static BOOL isExplicitView(UIView *view) {
    NSString *identifier = view.accessibilityIdentifier;
    if ([identifier isEqualToString:@"Components.UI.ExplicitIcon"] ||
        [identifier isEqualToString:@"Podcast.Row.MarkAsPlayed.ExplicitIcon"] ||
        [identifier isEqualToString:@"Components.UI.19andOverIcon"]) return YES;
    return [NSStringFromClass(view.class) hasSuffix:@"ExplicitBadge"];
}

static void styleExplicitView(UIView *view) {
    if (SGHidden(SGKeyHideExplicit)) {
        SGRSuppress(view);
        return;
    }
    if (!SGEnabled(SGRKeyPrettierIcons)) return;
    static char kPrettyKey;
    UIImageView *badge = objc_getAssociatedObject(view, &kPrettyKey);
    if (!badge) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold];
        badge = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"e.square.fill" withConfiguration:cfg]];
        badge.tintColor = SGRTertiary();
        badge.contentMode = UIViewContentModeCenter;
        badge.userInteractionEnabled = NO;
        objc_setAssociatedObject(view, &kPrettyKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (UIView *sub in view.subviews) sub.alpha = 0;
        [view addSubview:badge];
    }
    badge.frame = view.bounds;
}

%hook UIView
- (void)layoutSubviews {
    %orig;
    if (isExplicitView(self)) styleExplicitView(self);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    if (!SGRPlainCheckOn() && !SGHidden(SGKeyHideExplicit) && !SGEnabled(SGRKeyPrettierIcons)) return;
    %init;
}
