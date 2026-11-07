// Player redesign: the mixing pill. While the song is being carried into the next one — Spotify's own
// beat-matched plan or the mod's crossfade — a glass capsule under the header names the incoming song
// and runs a hairline across the fade's length, so a mix is seen happening, not only heard.
//
// The window comes from Shared/AutoMix (SGAutoMixMixWindow) and is the exact one playback applies.
// Position is Spotify's own, already interpolated while playing; the link only samples it, at 2 Hz
// when nothing mixes, 10 Hz while it does, and stops with the player closed. A link at the display's
// rate would hold the player's 120 Hz open and close transitions down, so while a transition runs
// the pill hides — the same rule PlayerVisualiser keeps for any view over the player.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/AutoMix/AutoMix.h"
#import "Shared/Player/PlayerState.h"
#import "Player.h"

static const CGFloat kPadX = 14, kRailHeight = 3, kPadTop = 5, kGap = 5, kPadBottom = 6, kMinWidth = 60;

static char kCapsuleKey;
static UIView *sg_pill, *sg_rail, *sg_fill;
static UILabel *sg_label;
static BOOL sg_shown;
static float sg_rate;
static CADisplayLink *sg_link;

static CGFloat pillHeight(void) {
    return ceil(sg_label.font.lineHeight) + kPadTop + kGap + kRailHeight + kPadBottom;
}

static void pillResize(CGFloat width) {
    CGFloat height = pillHeight(), line = ceil(sg_label.font.lineHeight);
    CGRect frame = sg_pill.frame;
    frame.size = CGSizeMake(width, height);
    sg_pill.frame = frame;
    sg_label.frame = CGRectMake(kPadX, kPadTop, MAX(0, width - 2 * kPadX), line);
    sg_rail.frame = CGRectMake(kPadX, kPadTop + line + kGap, MAX(0, width - 2 * kPadX), kRailHeight);
    CGRect filled = sg_fill.frame;
    filled.size.height = kRailHeight;
    filled.size.width = MIN(filled.size.width, sg_rail.bounds.size.width);
    sg_fill.frame = filled;
    SGRGlassCapsuleInside(sg_pill, &kCapsuleKey, frame.size, NO);   // material follows the size, as PlayerHeader.x keeps its pill
}

static void pillPlace(UIView *parent, CGFloat top) {
    CGFloat width = CGRectGetWidth(sg_pill.frame);
    sg_pill.frame = CGRectMake(round((parent.bounds.size.width - width) / 2), round(top),
                               width, CGRectGetHeight(sg_pill.frame));
}

static void pillShow(BOOL shown) {
    if (shown == sg_shown) return;
    sg_shown = shown;
    if (shown) sg_pill.hidden = NO;
    SGRAnimate(SGRMotionFade, ^{
        sg_pill.transform = shown ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.9, 0.9);
        sg_pill.alpha = shown ? 1 : 0;
    }, shown ? nil : ^(BOOL finished) {
        if (!sg_shown) sg_pill.hidden = YES;
    });
}

static void pillTearDown(void) {
    [sg_link invalidate];
    sg_link = nil;
    sg_rate = 0;
}

static void pillTick(CADisplayLink *link) {
    if (!sg_pill || sg_pill.superview == nil || sg_pill.window == nil) {
        pillTearDown();
        return;
    }
    SPTPlayerState *state = SGPlayerState();
    double at = -1;
    if (state) {
        double reported = state.isPaused ? state.positionAsOfTimestamp : state.position;
        if (isfinite(reported)) at = reported;
    }
    double start = 0, end = 0;
    NSString *next = nil;
    BOOL window = !SGRPlayerIsTransitioning() && SGAutoMixMixWindow(&start, &end, &next);
    double progress = window && end > start ? (at - start) / (end - start) : 0;
    BOOL mixing = window && at >= start - 0.4 && progress < 1.12;
    pillShow(mixing);
    float rate = SGRReduceMotion() ? 4 : (mixing ? 10 : 2);
    if (rate != sg_rate) {
        sg_rate = rate;
        sg_link.preferredFrameRateRange = CAFrameRateRangeMake(rate / 2, rate, rate);
    }
    if (!mixing) return;
    NSMutableString *text = [NSMutableString stringWithString:@"Mixing"];
    if (next.length) [text appendString:[@" into " stringByAppendingString:next]];
    CGFloat most = MAX(sg_pill.superview.bounds.size.width - 24, kMinWidth);
    CGFloat measured = MIN(ceil([text sizeWithAttributes:@{NSFontAttributeName: sg_label.font}].width) + 2 * kPadX, most);
    if (![sg_label.text isEqualToString:text] || fabs(CGRectGetWidth(sg_pill.frame) - measured) > 1) {
        CGFloat top = CGRectGetMinY(sg_pill.frame);
        sg_label.text = text;
        pillResize(MAX(measured, kMinWidth));
        pillPlace(sg_pill.superview, top);
    }
    CGFloat width = sg_rail.bounds.size.width * MAX(0, MIN(1, progress));
    if (fabs(sg_fill.frame.size.width - width) > 0.5) {
        CGRect filled = sg_fill.frame;
        filled.size.width = width;
        sg_fill.frame = filled;
    }
}

@interface SGRMixDriver : NSObject
@end
@implementation SGRMixDriver
- (void)tick:(CADisplayLink *)link { pillTick(link); }
@end
static SGRMixDriver *sg_driver;

// The context line sits under the top row; the pill rides under its capsule. Any wide label but the
// pill's own is the anchor, the way PlayerHeader.x finds the context line for its pill.
static UILabel *anchorIn(UIView *host) {
    __block UILabel *found = nil;
    SGForEachView(host, ^(UIView *view) {
        if (found || view == sg_label || ![view isKindOfClass:UILabel.class]) return;
        UILabel *label = (UILabel *)view;
        if (label.hidden || label.alpha < 0.01 || !label.text.length || label.bounds.size.width < 60) return;
        found = label;
    });
    return found;
}

static void pillMount(UIView *parent) {
    if (!parent) return;
    if (!sg_driver) sg_driver = [SGRMixDriver new];
    if (!sg_pill) {
        sg_pill = [UIView new];
        sg_pill.userInteractionEnabled = NO;
        sg_pill.accessibilityElementsHidden = YES;
        sg_pill.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        sg_pill.hidden = YES;   // nothing mixes until a window says so
        sg_pill.alpha = 0;
        sg_label = [UILabel new];
        sg_label.font = SGRFont(UIFontTextStyleFootnote, UIFontWeightMedium,
                                UIContentSizeCategoryAccessibilityExtraExtraExtraLarge);
        sg_label.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.94];
        sg_label.lineBreakMode = NSLineBreakByTruncatingTail;
        sg_label.text = @"Mixing";
        [sg_pill addSubview:sg_label];
        sg_rail = [UIView new];
        sg_rail.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.2];
        sg_rail.layer.cornerRadius = kRailHeight / 2;
        sg_fill = [UIView new];
        sg_fill.layer.cornerRadius = kRailHeight / 2;
        [sg_rail addSubview:sg_fill];
        [sg_pill addSubview:sg_rail];
        SGRGlassCapsuleInside(sg_pill, &kCapsuleKey, CGSizeMake(kMinWidth, pillHeight()), NO);
    }
    if (sg_pill.superview != parent) {
        [sg_pill removeFromSuperview];
        [parent addSubview:sg_pill];
    }
    sg_fill.backgroundColor = SGRAccent();
    UILabel *anchor = anchorIn(parent);
    CGFloat top = floor(parent.bounds.size.height * 0.24);
    if (anchor && anchor.superview) {
        CGPoint center = [parent convertPoint:anchor.center fromView:anchor.superview];
        // PlayerHeader.x wraps that line in a capsule at least 34 pt tall, centred on it.
        CGFloat capsule = MAX(34, ceil((anchor.font ?: sg_label.font).lineHeight) + 14);
        top = center.y + capsule / 2 + 6;
    }
    CGFloat most = MAX(parent.bounds.size.width - 24, kMinWidth);
    CGFloat measured = MIN(ceil([sg_label.text sizeWithAttributes:@{NSFontAttributeName: sg_label.font}].width) + 2 * kPadX, most);
    pillResize(MAX(measured, kMinWidth));
    pillPlace(parent, top);
    if (!sg_link) {
        sg_rate = SGRReduceMotion() ? 4 : 2;
        sg_link = [CADisplayLink displayLinkWithTarget:sg_driver selector:@selector(tick:)];
        [sg_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        sg_link.preferredFrameRateRange = CAFrameRateRangeMake(sg_rate / 2, sg_rate, sg_rate);
    }
}

void SGRPlayerMixPillRelayout(UIViewController *unit) {
    if (!unit) return;
    pillMount(unit.viewIfLoaded);
}

%hook _TtC20NowPlaying_ModesImpl18HeaderElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    SGRPlayerMixPillRelayout((UIViewController *)self);
}
- (void)viewDidDisappear:(BOOL)animated {
    pillTearDown();
    sg_shown = NO;
    if (sg_pill) {
        sg_pill.hidden = YES;
        sg_pill.alpha = 0;
    }
    %orig;
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC20NowPlaying_ModesImpl18HeaderElementsUnit"]);
}
