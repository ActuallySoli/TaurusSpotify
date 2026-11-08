#import "Core/SGCore.h"
#import "SGRKit.h"
#import "SGRAccent.h"
#import "Settings/SGPageStyle.h"

NSNotificationName const SGRAccentDidChangeNotification = @"SGRAccentDidChangeNotification";

static const uint32_t kGreens[] = {0x1ED760, 0x1DB954};

static NSInteger sg_accent = -1;     // 0xRRGGBB once chosen, read at launch
static NSInteger sg_autoAccent = -1; // 0xRRGGBB when Automatic accent colour reads a field or cover colour

// The redesign's own green until another is picked; Spotify's is a pick of its own, stored as -1.
static const NSInteger kDefaultAccent = 0x37F200;

static NSInteger chosen(void) {
    if (SGHidden(SGRKeyAccentAuto) && sg_autoAccent >= 0) return sg_autoAccent;
    NSInteger rgb = SGInt(SGRKeyAccent, kDefaultAccent);
    return rgb >= 0 && rgb <= 0xFFFFFF ? rgb : -1;
}

static void unpack(uint32_t rgb, CGFloat *r, CGFloat *g, CGFloat *b) {
    *r = ((rgb >> 16) & 0xFF) / 255.0;
    *g = ((rgb >> 8) & 0xFF) / 255.0;
    *b = (rgb & 0xFF) / 255.0;
}

static void saveRecentAccent(NSInteger rgb) {
    if (rgb < 0) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray<NSNumber *> *recent = [[defaults arrayForKey:SGRKeyAccentRecent] mutableCopy] ?: [NSMutableArray array];
    [recent removeObject:@(rgb)];
    [recent insertObject:@(rgb) atIndex:0];
    while (recent.count > 5) [recent removeLastObject];
    [defaults setObject:recent forKey:SGRKeyAccentRecent];
}

static void applyAutoColor(UIColor *source) {
    if (!SGHidden(SGRKeyAccentAuto) || !source) return;
    CGFloat h = 0, s = 0, v = 0, a = 1;
    if (![source getHue:&h saturation:&s brightness:&v alpha:&a] || s < 0.12) return;
    UIColor *bright = [UIColor colorWithHue:h saturation:MIN(0.85, MAX(0.48, s * 1.35)) brightness:MAX(0.88, v) alpha:1];
    CGFloat r = 0, g = 0, b = 0;
    [bright getRed:&r green:&g blue:&b alpha:&a];
    NSInteger rgb = ((NSInteger)lround(r * 255) << 16) | ((NSInteger)lround(g * 255) << 8) | (NSInteger)lround(b * 255);
    if (rgb == sg_autoAccent) return;
    sg_autoAccent = rgb;
    sg_accent = rgb;
    [NSNotificationCenter.defaultCenter postNotificationName:SGRAccentDidChangeNotification object:nil];
}

UIColor *SGRAccentColor(void) {
    NSInteger rgb = chosen();
    if (rgb < 0) return nil;
    CGFloat r, g, b;
    unpack((uint32_t)rgb, &r, &g, &b);
    return [UIColor colorWithRed:r green:g blue:b alpha:1];
}

NSString *SGRAccentLabel(void) {
    if (SGHidden(SGRKeyAccentAuto)) return @"Automatic";
    NSInteger rgb = chosen();
    return rgb < 0 ? @"Spotify green" : [NSString stringWithFormat:@"#%06lX", (long)rgb];
}

#pragma mark - picker

@interface SGRAccentPicker : NSObject <UIColorPickerViewControllerDelegate>
@end

@implementation SGRAccentPicker

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)picker {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [picker.selectedColor getRed:&r green:&g blue:&b alpha:&a];
    uint32_t rgb = ((uint32_t)lround(MIN(1, MAX(0, r)) * 255) << 16)
                 | ((uint32_t)lround(MIN(1, MAX(0, g)) * 255) << 8)
                 | (uint32_t)lround(MIN(1, MAX(0, b)) * 255);
    SGSetInt(SGRKeyAccent, rgb);
    saveRecentAccent((NSInteger)rgb);
    sg_accent = chosen();
    [NSNotificationCenter.defaultCenter postNotificationName:SGRAccentDidChangeNotification object:nil];
}

@end

void SGRPickAccent(void) {
    static SGRAccentPicker *delegate;
    if (!delegate) delegate = [SGRAccentPicker new];
    UIColorPickerViewController *picker = [UIColorPickerViewController new];
    picker.supportsAlpha = NO;
    picker.selectedColor = SGRAccentColor() ?: [UIColor colorWithRed:0x1E / 255.0 green:0xD7 / 255.0 blue:0x60 / 255.0 alpha:1];
    picker.delegate = delegate;
    [SGTopController() presentViewController:picker animated:YES completion:nil];
}

static BOOL swap(CGFloat *r, CGFloat *g, CGFloat *b) {
    for (size_t i = 0; i < sizeof(kGreens) / sizeof(kGreens[0]); i++) {
        CGFloat gr, gg, gb;
        unpack(kGreens[i], &gr, &gg, &gb);
        if (fabs(*r - gr) > 0.01 || fabs(*g - gg) > 0.01 || fabs(*b - gb) > 0.01) continue;
        CGFloat ar, ag, ab;
        unpack((uint32_t)sg_accent, &ar, &ag, &ab);
        CGFloat factor = MAX(gr, MAX(gg, gb)) / (0xD7 / 255.0);
        *r = MIN(1, ar * factor);
        *g = MIN(1, ag * factor);
        *b = MIN(1, ab * factor);
        return YES;
    }
    return NO;
}

%hook UIColor
- (UIColor *)initWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    swap(&r, &g, &b);
    return %orig(r, g, b, a);
}
+ (UIColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    swap(&r, &g, &b);
    return %orig(r, g, b, a);
}
%end

static CGColorRef swappedCopy(CGColorRef color) {
    if (!color || CFGetTypeID(color) != CGColorGetTypeID() || CGColorGetNumberOfComponents(color) != 4) return NULL;
    const CGFloat *c = CGColorGetComponents(color);
    CGFloat r = c[0], g = c[1], b = c[2];
    if (!swap(&r, &g, &b)) return NULL;
    CGFloat out[] = {r, g, b, c[3]};
    return CGColorCreate(CGColorGetColorSpace(color), out);
}

static id swappedValue(id value) {
    CGColorRef swapped = swappedCopy((__bridge CGColorRef)value);
    if (!swapped) return value;
    id boxed = (__bridge_transfer id)swapped;
    return boxed;
}

%hook CAShapeLayer
- (void)setFillColor:(CGColorRef)color {
    CGColorRef swapped = swappedCopy(color);
    CGColorRef used = swapped ?: color;
    %orig(used);
    if (swapped) CGColorRelease(swapped);
}
- (void)setStrokeColor:(CGColorRef)color {
    CGColorRef swapped = swappedCopy(color);
    CGColorRef used = swapped ?: color;
    %orig(used);
    if (swapped) CGColorRelease(swapped);
}
%end

%hook CALayer
- (void)setBackgroundColor:(CGColorRef)color {
    CGColorRef swapped = swappedCopy(color);
    CGColorRef used = swapped ?: color;
    %orig(used);
    if (swapped) CGColorRelease(swapped);
}
%end

%hook CABasicAnimation
- (void)setFromValue:(id)value {
    id used = swappedValue(value);
    %orig(used);
}
- (void)setToValue:(id)value {
    id used = swappedValue(value);
    %orig(used);
}
%end

%hook CAKeyframeAnimation
- (void)setValues:(NSArray *)values {
    NSMutableArray *mapped = nil;
    for (NSUInteger i = 0; i < values.count; i++) {
        id swapped = swappedValue(values[i]);
        if (swapped == values[i] && !mapped) continue;
        if (!mapped) mapped = [values mutableCopy];
        mapped[i] = swapped;
    }
    NSArray *used = mapped ?: values;
    %orig(used);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    sg_accent = chosen();
    if (SGHidden(SGRKeyAccentAuto)) {
        [NSNotificationCenter.defaultCenter addObserverForName:SGRFieldColorDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            UIColor *color = note.userInfo[@"color"];
            if (color) applyAutoColor(color);
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:SGRNowPlayingArtworkDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            UIImage *image = note.userInfo[@"image"];
            if (!image) return;
            SGRPaletteRequest req = {0};
            [SGRPalette paletteForImage:image request:req completion:^(SGRPalette *palette) {
                if (palette.fieldColor) applyAutoColor(palette.fieldColor);
            }];
        }];
    }
    if (sg_accent >= 0 || SGHidden(SGRKeyAccentAuto)) %init;
}
