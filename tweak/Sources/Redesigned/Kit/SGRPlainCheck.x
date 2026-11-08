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

static UIImage *explicitBadgeImage(BOOL nineteenPlus) {
    static UIImage *eBadge;
    static UIImage *nineteenBadge;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGSize size = CGSizeMake(13, 13);
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
        fmt.opaque = NO;
        fmt.scale = 3.0;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
        eBadge = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            CGRect rect = CGRectMake(0.5, 0.5, 12.0, 12.0);
            UIBezierPath *pill = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:2.8];
            [[UIColor colorWithWhite:1.0 alpha:0.78] setFill];
            [pill fill];
            NSDictionary *attrs = @{
                NSFontAttributeName: [UIFont systemFontOfSize:9.2 weight:UIFontWeightHeavy],
                NSForegroundColorAttributeName: [UIColor colorWithWhite:0.05 alpha:0.98],
            };
            NSString *letter = @"E";
            CGSize textSize = [letter sizeWithAttributes:attrs];
            CGRect textRect = CGRectMake((size.width - textSize.width) / 2.0,
                                         (size.height - textSize.height) / 2.0,
                                         textSize.width, textSize.height);
            [letter drawInRect:textRect withAttributes:attrs];
        }];
        nineteenBadge = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            CGRect rect = CGRectMake(0.5, 0.5, 12.0, 12.0);
            UIBezierPath *pill = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:2.8];
            [[UIColor colorWithWhite:1.0 alpha:0.78] setFill];
            [pill fill];
            NSDictionary *attrs = @{
                NSFontAttributeName: [UIFont systemFontOfSize:7.2 weight:UIFontWeightHeavy],
                NSForegroundColorAttributeName: [UIColor colorWithWhite:0.05 alpha:0.98],
            };
            NSString *letter = @"19";
            CGSize textSize = [letter sizeWithAttributes:attrs];
            CGRect textRect = CGRectMake((size.width - textSize.width) / 2.0,
                                         (size.height - textSize.height) / 2.0,
                                         textSize.width, textSize.height);
            [letter drawInRect:textRect withAttributes:attrs];
        }];
    });
    return nineteenPlus ? nineteenBadge : eBadge;
}

static void styleExplicitView(UIView *view) {
    if (SGHidden(SGKeyHideExplicit)) {
        SGRSuppress(view);
        return;
    }
    static char kPrettyKey;
    UIImageView *badge = objc_getAssociatedObject(view, &kPrettyKey);
    if (!SGEnabled(SGRKeyPrettierIcons)) {
        if (badge) badge.alpha = 0;
        SGForEachView(view, ^(UIView *sub) {
            if (sub == view || sub == badge) return;
            sub.alpha = 1;
            if ([sub isKindOfClass:UILabel.class]) {
                UILabel *label = (UILabel *)sub;
                label.textColor = [UIColor colorWithWhite:0.06 alpha:0.96];
            }
        });
        return;
    }
    BOOL nineteen = [view.accessibilityIdentifier isEqualToString:@"Components.UI.19andOverIcon"];
    if (!badge) {
        badge = [[UIImageView alloc] initWithImage:explicitBadgeImage(nineteen)];
        badge.contentMode = UIViewContentModeCenter;
        badge.userInteractionEnabled = NO;
        objc_setAssociatedObject(view, &kPrettyKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        badge.image = explicitBadgeImage(nineteen);
    }
    if (view.backgroundColor && ![view.backgroundColor isEqual:UIColor.clearColor]) {
        view.backgroundColor = UIColor.clearColor;
    }
    for (UIView *sub in view.subviews) {
        if (sub != badge) sub.alpha = 0;
    }
    if (badge.superview != view) [view addSubview:badge];
    else if (view.subviews.lastObject != badge) [view bringSubviewToFront:badge];
    badge.alpha = 1;
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
    %init;
}
