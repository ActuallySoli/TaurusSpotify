#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/Player/SpeedPitch.h"
#import "Player.h"

static char kGlassKey, kCloseKey, kMoreKey, kPillKey, kPillViewKey, kGrabberKey, kTopMoreKey;
static __weak UIControl *sg_closeButton;
static __weak UIControl *sg_moreButton;

BOOL SGRPlayerMusicTopOn(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ on = SGFlag(SGRKeyPlayerMusicTop, NO); });
    return on;
}

static BOOL headerGlassOn(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ on = SGEnabled(SGRKeyPlayerHeaderGlass); });
    return on;
}

void SGRPlayerTriggerMoreMenu(void) {
    UIControl *more = sg_moreButton;
    if ([more respondsToSelector:@selector(sendActionsForControlEvents:)]) {
        [more sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
}

@interface SGRPlayerGrabber : UIControl
@end

@implementation SGRPlayerGrabber {
    UIView *_bar;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.accessibilityLabel = @"Close";
    _bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 36, 5)];
    _bar.userInteractionEnabled = NO;
    _bar.backgroundColor = [UIColor colorWithWhite:1 alpha:0.38];
    _bar.layer.cornerRadius = 2.5;
    _bar.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:_bar];
    [self addTarget:self action:@selector(sgr_close) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _bar.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
}

- (void)sgr_close {
    UIControl *close = sg_closeButton;
    if ([close respondsToSelector:@selector(sendActionsForControlEvents:)]) {
        [close sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
}

@end

@interface SGRPlayerTopMore : UIControl
@end

@implementation SGRPlayerTopMore {
    UIImageView *_glyph;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.accessibilityLabel = @"More";
    self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    self.layer.cornerRadius = 14;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold];
    _glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis" withConfiguration:cfg]];
    _glyph.tintColor = UIColor.whiteColor;
    _glyph.contentMode = UIViewContentModeCenter;
    [self addSubview:_glyph];
    [self addTarget:self action:@selector(sgr_open) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _glyph.frame = self.bounds;
}

- (void)sgr_open {
    SGRPlayerTriggerMoreMenu();
}

@end

static void glassInside(UIViewController *unit, NSArray<NSString *> *identifiers, const void **findKeys) {
    UIView *host = unit.viewIfLoaded;
    if (!host) return;
    BOOL glass = headerGlassOn() && !SGRPlayerMusicTopOn();
    NSUInteger found = 0;
    for (NSUInteger i = 0; i < identifiers.count; i++) {
        UIView *button = SGRFindByIdentifier(host, identifiers[i], findKeys[i]);
        if (!button) {
            static NSMutableSet<NSString *> *missing;
            if (!missing) missing = [NSMutableSet set];
            if (![missing containsObject:identifiers[i]]) {
                [missing addObject:identifiers[i]];
                SGLog(@"redesign player: %@ not found in %@, left as Spotify's", identifiers[i], NSStringFromClass(host.class));
            }
            continue;
        }
        if ([identifiers[i] isEqualToString:@"now-playing-minimize-button"] && [button isKindOfClass:UIControl.class]) {
            sg_closeButton = (UIControl *)button;
        }
        if ([identifiers[i] isEqualToString:@"Context menu"]) {
            if ([button isKindOfClass:UIControl.class]) sg_moreButton = (UIControl *)button;
            SGPlayerMenuWatchMoreButton(button);
            SGRPlayerMenuWatchMoreButton(button);
        }
        if (glass) SGRGlassInside(button, &kGlassKey, SGRGlassCircleSize);
        found++;
    }

    if (SGRPlayerMusicTopOn()) {
        for (UIView *sub in host.subviews) {
            if ([sub isKindOfClass:SGRPlayerGrabber.class]) continue;
            SGRSuppress(sub);
        }
        SGRPlayerGrabber *grabber = objc_getAssociatedObject(host, &kGrabberKey);
        if (!grabber) {
            grabber = [[SGRPlayerGrabber alloc] initWithFrame:CGRectMake(0, 0, 64, 32)];
            objc_setAssociatedObject(host, &kGrabberKey, grabber, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (grabber.superview != host) [host addSubview:grabber];
        grabber.center = CGPointMake(CGRectGetMidX(host.bounds), CGRectGetMidY(host.bounds));
        return;
    }

    static NSMutableSet<NSString *> *logged;
    if (!logged) logged = [NSMutableSet set];
    NSString *unitName = NSStringFromClass(unit.class);
    if (![logged containsObject:unitName]) {
        [logged addObject:unitName];
        SGLog(@"redesign player: glass inside %lu of %lu buttons in %@", (unsigned long)found, (unsigned long)identifiers.count, unitName);
    }
}


// The header's context line ("Playing from ...") on a glass pill of its own, so it reads over any cover, the
// sharp artwork of the fill background included. The pill is a passthrough view under the label, sized to
// the text, so Spotify's label keeps its layout and its taps.
static const CGFloat kPillPadX = 16, kPillMinHeight = 34;

static UILabel *contextLabelIn(UIView *host) {
    __block UILabel *found = nil;
    SGForEachView(host, ^(UIView *view) {
        if (found || ![view isKindOfClass:UILabel.class]) return;
        UILabel *label = (UILabel *)view;
        if (label.hidden || label.alpha < 0.01 || !label.text.length || label.bounds.size.width < 60) return;
        found = label;
    });
    return found;
}

static void pillBehindContext(UIViewController *unit) {
    UIView *host = unit.viewIfLoaded;
    if (!host) return;
    UILabel *label = contextLabelIn(host);
    UIView *box = label ? objc_getAssociatedObject(label, &kPillViewKey) : nil;
    if (!label || !label.superview) {
        box.hidden = YES;
        return;
    }
    if (!box) {
        box = [UIView new];
        box.userInteractionEnabled = NO;
        box.accessibilityElementsHidden = YES;
        objc_setAssociatedObject(label, &kPillViewKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIView *parent = label.superview;
    if (box.superview != parent) [parent insertSubview:box belowSubview:label];
    else if ([parent.subviews indexOfObject:box] > [parent.subviews indexOfObject:label]) [parent insertSubview:box belowSubview:label];

    CGSize text = [label.text sizeWithAttributes:@{NSFontAttributeName: label.font ?: [UIFont systemFontOfSize:14]}];
    CGFloat width = MIN(ceil(text.width) + 2 * kPillPadX, MAX(parent.bounds.size.width - 8, 0));
    CGFloat height = MAX(kPillMinHeight, ceil(text.height) + 14);
    box.bounds = CGRectMake(0, 0, width, height);
    box.center = label.center;
    box.hidden = label.hidden;
    box.alpha = label.alpha;
    SGRGlassCapsuleInside(box, &kPillKey, box.bounds.size, NO);
}

%hook _TtC20NowPlaying_ModesImpl18HeaderElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    static const void *keys[] = {&kCloseKey, &kMoreKey};
    glassInside((UIViewController *)self, @[@"now-playing-minimize-button", @"Context menu"], keys);
    if (headerGlassOn() && !SGRPlayerMusicTopOn()) pillBehindContext((UIViewController *)self);
}
%end

%hook _TtC20NowPlaying_ModesImpl23InformationElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    if (!SGRPlayerMusicTopOn()) return;
    UIView *host = ((UIViewController *)self).viewIfLoaded;
    if (!host || host.bounds.size.width < 120) return;
    SGRPlayerTopMore *more = objc_getAssociatedObject(host, &kTopMoreKey);
    if (!more) {
        more = [[SGRPlayerTopMore alloc] initWithFrame:CGRectMake(0, 0, 28, 28)];
        objc_setAssociatedObject(host, &kTopMoreKey, more, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (more.superview != host) [host addSubview:more];
    CGFloat rightEdge = host.bounds.size.width - 24;
    more.frame = CGRectMake(rightEdge - 28, round((host.bounds.size.height - 28) / 2), 28, 28);
    SGForEachView(host, ^(UIView *view) {
        if (view == more || view.superview == more || ![view isKindOfClass:UIControl.class]) return;
        CGRect inHost = [view convertRect:view.bounds toView:host];
        if (CGRectGetMaxX(inHost) > rightEdge - 34 && view.bounds.size.width <= 56) {
            UIView *moved = view.superview && view.superview != host && view.superview.bounds.size.width <= 60 ? view.superview : view;
            CGAffineTransform shift = CGAffineTransformMakeTranslation(-36, 0);
            if (!CGAffineTransformEqualToTransform(moved.transform, shift)) moved.transform = shift;
        }
    });
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC20NowPlaying_ModesImpl18HeaderElementsUnit",
        @"_TtC20NowPlaying_ModesImpl23InformationElementsUnit",
    ]);
}
