#import "SGRLyricsShaderEffect.h"
#import <QuartzCore/QuartzCore.h>

static const NSUInteger kMaskLimit = 48, kPixelLimit = 512 * 1024;
static NSUInteger liveMasks, livePixels;

static UIColor *ink(CGFloat r, CGFloat g, CGFloat b) { return [UIColor colorWithRed:r green:g blue:b alpha:1]; }

static NSArray *palette(NSInteger style) {
    switch (style) {
        case 1: return @[ink(0.95, 0.1, 0.65), ink(0.5, 0.2, 1), ink(0.2, 0.95, 1), UIColor.whiteColor, ink(1, 0.18, 0.7), ink(0.5, 0.2, 1)];
        case 2: return @[ink(0.8, 0.08, 0.02), ink(1, 0.24, 0.03), ink(1, 0.9, 0.3), ink(1, 0.98, 0.8), ink(1, 0.3, 0.05), ink(0.9, 0.1, 0.01)];
        case 3: return @[ink(0.25, 0.8, 1), ink(0.9, 0.35, 1), ink(0.5, 1, 0.9), UIColor.whiteColor, ink(0.7, 0.5, 1), ink(0.25, 0.8, 1)];
        case 4: return @[ink(0.25, 0.34, 0.45), ink(0.72, 0.83, 0.94), UIColor.whiteColor, ink(0.3, 0.4, 0.55), ink(0.95, 0.98, 1), ink(0.4, 0.5, 0.6)];
        default: return @[ink(0.15, 0.5, 0.9), ink(0.4, 0.8, 1), ink(0.8, 0.97, 1), ink(0.2, 0.6, 1), ink(0.1, 0.4, 0.8), ink(0.15, 0.5, 0.9)];
    }
}

static CABasicAnimation *travel(NSString *path, CGFloat from, CGFloat to, double duration) {
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:path];
    animation.fromValue = @(from);
    animation.toValue = @(to);
    animation.duration = duration;
    animation.beginTime = 1;
    animation.repeatCount = HUGE_VALF;
    animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    animation.preferredFrameRateRange = CAFrameRateRangeMake(80, 120, 120);
    return animation;
}

static UIImage *glyphMask(UILabel *source, CGFloat scale) {
    UILabel *copy = [[UILabel alloc] initWithFrame:source.bounds];
    copy.font = source.font;
    copy.text = source.text;
    copy.textColor = UIColor.whiteColor;
    copy.textAlignment = source.textAlignment;
    copy.baselineAdjustment = source.baselineAdjustment;
    copy.numberOfLines = source.numberOfLines;
    copy.lineBreakMode = source.lineBreakMode;
    if (source.attributedText) {
        NSMutableAttributedString *text = [source.attributedText mutableCopy];
        [text addAttribute:NSForegroundColorAttributeName value:UIColor.whiteColor range:NSMakeRange(0, text.length)];
        copy.attributedText = text;
    }
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = scale;
    format.opaque = NO;
    format.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:source.bounds.size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) { [copy drawTextInRect:copy.bounds]; }];
}

@implementation SGRLyricsShaderEffect {
    NSArray<CALayer *> *_clocks;
    NSUInteger _maskCount, _pixels;
    CGFloat _speed;
    BOOL _running, _anchored;
}

+ (NSUInteger)activeMaskCount { return liveMasks; }
+ (NSUInteger)activeMaskPixels { return livePixels; }

- (instancetype)initWithLabels:(NSArray<UILabel *> *)labels root:(UIView *)root style:(NSInteger)style intensity:(CGFloat)intensity speed:(CGFloat)speed {
    if (!(self = [super init])) return nil;
    if (style < 1 || style > 5 || !labels.count || !isfinite(intensity) || intensity <= 0 || !isfinite(speed)) return nil;
    CGSize wordSize = root.bounds.size;
    if (!isfinite(wordSize.width) || !isfinite(wordSize.height) || wordSize.width <= 0 || wordSize.height <= 0 || wordSize.width > 1024 || wordSize.height > 128) return nil;
    _speed = MAX(0.35, MIN(2, speed));
    CGFloat scale = MIN(2, root.window.screen.scale ?: UIScreen.mainScreen.scale);
    NSUInteger pixels = 0;
    for (UILabel *label in labels) {
        CGSize size = label.bounds.size;
        if (!isfinite(size.width) || !isfinite(size.height) || size.width <= 0 || size.height <= 0 || size.width > 2048 || size.height > 256) return nil;
        pixels += (NSUInteger)ceil(size.width * scale) * (NSUInteger)ceil(size.height * scale);
        if (pixels > kPixelLimit) return nil;
    }
    if (labels.count > kMaskLimit - liveMasks || pixels > kPixelLimit - livePixels) return nil;
    NSMutableArray<CALayer *> *clocks = [NSMutableArray arrayWithCapacity:labels.count];
    CGFloat width = MAX(1, root.bounds.size.width), height = MAX(1, root.bounds.size.height);
    NSMutableArray *colors = [NSMutableArray array];
    for (UIColor *color in palette(style)) [colors addObject:(id)color.CGColor];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (UILabel *label in labels) {
        UIImage *mask = glyphMask(label, scale);
        if (!mask.CGImage) {
            for (CALayer *clock in clocks) [clock removeFromSuperlayer];
            [CATransaction commit];
            return nil;
        }
        CALayer *clock = [CALayer layer];
        clock.name = @"spoti.pw.lyrics.effect";
        clock.frame = label.bounds;
        clock.masksToBounds = YES;
        clock.opacity = MIN(1, intensity);
        clock.hidden = YES;
        clock.speed = 0;
        CALayer *shape = [CALayer layer];
        shape.frame = clock.bounds;
        shape.contents = (id)mask.CGImage;
        shape.contentsScale = scale;
        clock.mask = shape;
        CGFloat x = label == root ? 0 : label.center.x - label.bounds.size.width / 2;
        CGFloat y = label == root ? 0 : label.center.y - label.bounds.size.height / 2;
        CAGradientLayer *light = [CAGradientLayer layer];
        light.frame = CGRectMake(-x - width, -y - height, width * 3, height * 3);
        light.colors = colors;
        light.locations = style == 4 ? @[@0, @0.35, @0.43, @0.48, @0.52, @1] : @[@0, @0.2, @0.38, @0.5, @0.67, @1];
        light.startPoint = style == 2 ? CGPointMake(0.2, 1) : CGPointMake(0, 0.3);
        light.endPoint = style == 2 ? CGPointMake(0.8, 0) : CGPointMake(1, 0.7);
        [clock addSublayer:light];
        double duration = style == 2 ? 1.8 : style == 4 ? 2.8 : 3.6;
        CABasicAnimation *flow = travel(style == 2 ? @"transform.translation.y" : @"transform.translation.x", style == 2 ? height : -width, style == 2 ? -height : width, duration);
        flow.autoreverses = YES;
        [light addAnimation:flow forKey:@"flow"];
        if (style == 3 || style == 5) {
            CAShapeLayer *lines = [CAShapeLayer layer];
            lines.frame = CGRectMake(-x, -y - height, width, height * 3);
            lines.strokeColor = [UIColor colorWithWhite:1 alpha:style == 3 ? 0.45 : 0.8].CGColor;
            lines.fillColor = nil;
            lines.lineWidth = style == 3 ? 0.65 : 0.75;
            CGFloat step = style == 3 ? 4 : MAX(6, round(height / 5));
            UIBezierPath *grid = [UIBezierPath bezierPath];
            for (CGFloat row = 0; row <= height * 3; row += step) {
                [grid moveToPoint:CGPointMake(0, row)];
                [grid addLineToPoint:CGPointMake(width, row)];
            }
            if (style == 5) for (CGFloat col = 0; col <= width; col += step) {
                [grid moveToPoint:CGPointMake(col, 0)];
                [grid addLineToPoint:CGPointMake(col, height * 3)];
            }
            lines.path = grid.CGPath;
            [clock addSublayer:lines];
            [lines addAnimation:travel(@"transform.translation.y", 0, step, style == 3 ? 1.6 : 3.0) forKey:@"scan"];
        }
        [label.layer addSublayer:clock];
        [clocks addObject:clock];
    }
    [CATransaction commit];
    _clocks = clocks;
    _maskCount = labels.count;
    _pixels = pixels;
    liveMasks += _maskCount;
    livePixels += _pixels;
    return self;
}

- (void)showTime:(double)seconds running:(BOOL)running {
    if (!_clocks.count || !isfinite(seconds)) return;
    CFTimeInterval now = CACurrentMediaTime();
    CALayer *first = _clocks.firstObject;
    double local = 1 + MAX(0, seconds) * _speed;
    double shown = [first convertTime:now fromLayer:nil];
    if (_anchored && _running == running && (!running || fabs(shown - local) < 0.08)) return;
    _anchored = YES;
    _running = running;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *clock in _clocks) {
        CFTimeInterval parent = [clock.superlayer convertTime:now fromLayer:nil];
        clock.speed = running ? _speed : 0;
        clock.timeOffset = local;
        clock.beginTime = parent;
        clock.hidden = !running;
    }
    [CATransaction commit];
}

- (void)invalidate {
    for (CALayer *clock in _clocks) {
        [clock removeAllAnimations];
        for (CALayer *effect in clock.sublayers) [effect removeAllAnimations];
        [clock removeFromSuperlayer];
    }
    _clocks = nil;
    liveMasks -= _maskCount;
    livePixels -= _pixels;
    _maskCount = _pixels = 0;
}

- (void)dealloc { [self invalidate]; }
@end
