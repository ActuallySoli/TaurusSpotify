// SGLyricsClip.h says what this draws. The words are laid out once per clip and only the backdrop moves,
// so an animated clip costs a scaled image draw and an encode a frame.
#import <Accelerate/Accelerate.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreText/CoreText.h>
#import "SGLyricsClip.h"

// The lock screen fills the screen with a 3:4 clip, so a phone's taller screen cuts its sides off: the
// words keep to this middle share of the width. The center of the words sits this far down, clear of
// the clock above and the controls below.
// ponytail: guessed from the screen's shape, not measured on a lock screen; tune both on a device.
static const CGFloat kColumn = 0.56;
static const CGFloat kCentreY = 0.5;
// The words' size as a share of the width, made smaller down to kSmallest of it while they run taller
// than kTallest of the height.
static const CGFloat kFont = 0.05;
static const CGFloat kSmallest = 0.6;
static const CGFloat kTallest = 0.4;
static const CGFloat kNextAlpha = 0.4;
// A still is one frame held this long; an animated clip breathes once over kLoopSeconds, which is all it
// plays before the lock screen loops it.
static const int32_t kStillSeconds = 2;
static const int32_t kLoopSeconds = 4;
static const int32_t kFPS = 15;   // the breath is slow; at 24 a line took about 4 s to write on the CPU
static const CGFloat kBreath = 0.06;   // how much bigger the cover grows at the top of a breath
static const CGFloat kMotionDim = 0.25, kBandDim = 0.6, kBandReach = 0.3, kSoftWidth = 0.06;
static const CGFloat kShadowAlpha = 0.9, kShadowBlur = 0.15, kMotionNextAlpha = 0.55;
static const double kMotionFPS = 30;

CGSize SGLyricsClipSize(CGFloat pixels) {
    CGFloat width = MAX(floor(pixels / 16) * 16, 16);
    return CGSizeMake(width, round(width * 4 / 3 / 16) * 16);
}

static CGContextRef newContext(CGSize size, void *data, size_t bytesPerRow) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(data, (size_t)size.width, (size_t)size.height, 8, bytesPerRow, space,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    return context;
}

// The width the cover is blurred at, before it is drawn at the clip's size.
static const CGFloat kBackdropWidth = 128;

CGImageRef SGLyricsClipBackdrop(CGImageRef cover, CGSize size) {
    CGContextRef context = newContext(size, NULL, 0);
    CGRect bounds = {CGPointZero, size};
    CGContextSetRGBFillColor(context, 0.11, 0.11, 0.12, 1);
    CGContextFillRect(context, bounds);
    if (cover) {
        static CIContext *renderer;
        static dispatch_once_t once;
        // On the CPU: the lock screen asks while Spotify is in the background, where GPU work gets it killed.
        dispatch_once(&once, ^{ renderer = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}]; });
        // Blurred small and drawn large: a blur this wide looks the same either way, and on the CPU at full size it
        // took 12 to 20 s for a song's first line.
        CGSize small = CGSizeMake(kBackdropWidth, round(kBackdropWidth * size.height / size.width));
        // Filled the way the lock screen fills the screen, the square cover's sides overflowing.
        CIImage *image = [CIImage imageWithCGImage:cover];
        CGFloat scale = MAX(small.width / image.extent.size.width, small.height / image.extent.size.height);
        image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation((small.width - image.extent.size.width) / 2,
                                                                                 (small.height - image.extent.size.height) / 2)];
        // Clamped first, so the blur does not pull the dark in from past the edges.
        image = [[image imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:small.width * 0.05];
        CGImageRef blurred = [renderer createCGImage:image fromRect:(CGRect){CGPointZero, small}];
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        if (blurred) CGContextDrawImage(context, bounds, blurred);
        CGImageRelease(blurred);
        // Darkened, so white words read over a light cover.
        CGContextSetRGBFillColor(context, 0, 0, 0, 0.45);
        CGContextFillRect(context, bounds);
    }
    CGImageRef backdrop = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return backdrop;
}

static NSAttributedString *wordsAt(NSString *previous, NSString *line, NSString *next, CGFloat fontSize, CGFloat dimAlpha) {
    CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, fontSize, NULL);
    CGFloat spacing = fontSize * 0.6;
    CTParagraphStyleSetting settings[] = {
        {kCTParagraphStyleSpecifierParagraphSpacingBefore, sizeof(spacing), &spacing},
    };
    CTParagraphStyleRef paragraph = CTParagraphStyleCreate(settings, 1);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat white[] = {1, 1, 1, 1}, dim[] = {1, 1, 1, dimAlpha};
    CGColorRef lit = CGColorCreate(space, white), unlit = CGColorCreate(space, dim);
    NSMutableAttributedString *words = [NSMutableAttributedString new];
    NSDictionary *base = @{(id)kCTFontAttributeName: (__bridge id)font, (id)kCTParagraphStyleAttributeName: (__bridge id)paragraph};
    NSString *texts[] = {previous, line, next};
    for (int i = 0; i < 3; i++) {
        if (!texts[i].length) continue;
        NSMutableDictionary *attributes = [base mutableCopy];
        attributes[(id)kCTForegroundColorAttributeName] = (__bridge id)(i == 1 ? lit : unlit);
        NSString *text = words.length ? [@"\n" stringByAppendingString:texts[i]] : texts[i];
        [words appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
    }
    CFRelease(font);
    CFRelease(paragraph);
    CGColorRelease(lit);
    CGColorRelease(unlit);
    CGColorSpaceRelease(space);
    return words;
}

// The words alone on a clear image. Over moving artwork, only their box is returned and `drawn` gets its place.
static CGImageRef newWords(NSString *previous, NSString *line, NSString *next, CGSize size, CGRect *drawn) CF_RETURNS_RETAINED {
    if (!previous.length && !line.length && !next.length) return NULL;
    CGFloat width = round(size.width * kColumn);
    CGFloat fontSize = size.width * kFont;
    CTFramesetterRef setter = NULL;
    CGSize fits = CGSizeZero;
    // A long line is set smaller until the two lines fit; past the smallest size it runs taller.
    for (CGFloat scale = 1; scale >= kSmallest - 0.01; scale -= 0.1) {
        if (setter) CFRelease(setter);
        setter = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)
            wordsAt(previous, line, next, fontSize * scale, drawn ? kMotionNextAlpha : kNextAlpha));
        fits = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRangeMake(0, 0), NULL, CGSizeMake(width, CGFLOAT_MAX), NULL);
        if (fits.height <= size.height * kTallest) break;
    }
    CGFloat height = ceil(fits.height) + 1;
    // Core Graphics counts up from the bottom.
    CGRect box = CGRectMake(round((size.width - width) / 2), round(size.height * (1 - kCentreY) - height / 2), width, height);
    CGPathRef path = CGPathCreateWithRect(box, NULL);
    CTFrameRef frame = CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, NULL);
    CGContextRef context = newContext(size, NULL, 0);
    if (drawn) {
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGFloat shade[] = {0, 0, 0, kShadowAlpha};
        CGColorRef color = CGColorCreate(space, shade);
        CGContextSetShadowWithColor(context, CGSizeZero, fontSize * kShadowBlur, color);
        CGColorRelease(color);
        CGColorSpaceRelease(space);
    }
    CTFrameDraw(frame, context);
    CGImageRef words = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (drawn) {
        *drawn = CGRectIntersection(CGRectIntegral(CGRectInset(box, -fontSize, -fontSize)), (CGRect){CGPointZero, size});
        CGImageRef cut = CGImageCreateWithImageInRect(words, CGRectMake(drawn->origin.x, size.height - CGRectGetMaxY(*drawn),
                                                                        drawn->size.width, drawn->size.height));
        CGImageRelease(words);
        words = cut;
    }
    CFRelease(frame);
    CGPathRelease(path);
    CFRelease(setter);
    return words;
}

// A frame `phase` of the way through the loop, 0 to 1, into `context`.
static void drawFrame(CGContextRef context, CGImageRef backdrop, CGImageRef words, CGSize size, double phase) {
    CGFloat grow = kBreath * (1 - cos(2 * M_PI * phase)) / 2;
    CGRect bounds = {CGPointZero, size};
    CGContextDrawImage(context, CGRectInset(bounds, -size.width * grow / 2, -size.height * grow / 2), backdrop);
    if (words) CGContextDrawImage(context, bounds, words);
}

CGImageRef SGLyricsClipFrame(CGImageRef backdrop, NSString *line, NSString *next, CGSize size) {
    return SGLyricsClipFrameIn(backdrop, NULL, line, next, size, SGLyricsClipStill, SGLyricsClipWords);
}

#pragma mark - the looks that keep the art in sight

NSArray<NSString *> *SGLyricsClipCompositionNames(void) {
    return @[@"Full screen", @"Poster", @"Vinyl", @"Messages", @"Polaroid", @"Stickers", @"Duotone"];
}

static CTFontRef lineFont(CGFloat size) CF_RETURNS_RETAINED {
    return CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, size, NULL);
}

// How tall the line draws, wrapped at `width`.
static CGSize lineSize(NSString *text, CGFloat fontSize, CGFloat width) {
    if (!text.length) return CGSizeZero;
    CTFontRef font = lineFont(fontSize);
    CTTextAlignment align = kCTTextAlignmentCenter;
    CTParagraphStyleSetting settings[] = {
        {kCTParagraphStyleSpecifierAlignment, sizeof(CTTextAlignment), &align},
    };
    CTParagraphStyleRef paragraph = CTParagraphStyleCreate(settings, 1);
    NSDictionary *attributes = @{
        (id)kCTFontAttributeName: (__bridge id)font,
        (id)kCTParagraphStyleAttributeName: (__bridge id)paragraph,
    };
    CTFramesetterRef setter = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)
        [[NSAttributedString alloc] initWithString:text attributes:attributes]);
    CGSize fits = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRangeMake(0, 0), NULL, CGSizeMake(width, CGFLOAT_MAX), NULL);
    CFRelease(setter);
    CFRelease(paragraph);
    CFRelease(font);
    return CGSizeMake(ceil(fits.width), ceil(fits.height) + 2);
}

static void setWordsShadow(CGContextRef context, CGFloat fontSize) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat shade[] = {0, 0, 0, kShadowAlpha};
    CGColorRef color = CGColorCreate(space, shade);
    CGContextSetShadowWithColor(context, CGSizeZero, fontSize * kShadowBlur, color);
    CGColorRelease(color);
    CGColorSpaceRelease(space);
}

// A wrapped line of the song, drawn into `box` at `alpha`, aligned `align`, in `rgb`.
static void drawTextIn(CGContextRef context, NSString *text, CGFloat fontSize, CGFloat alpha, CGRect box,
                       CTTextAlignment align, const CGFloat *rgb) {
    if (!text.length) return;
    CTFontRef font = lineFont(fontSize);
    CTParagraphStyleSetting settings[] = {
        {kCTParagraphStyleSpecifierAlignment, sizeof(CTTextAlignment), &align},
    };
    CTParagraphStyleRef paragraph = CTParagraphStyleCreate(settings, 1);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat rgba[] = {rgb[0], rgb[1], rgb[2], alpha};
    CGColorRef color = CGColorCreate(space, rgba);
    NSAttributedString *attributed = [[NSAttributedString alloc] initWithString:text attributes:@{
        (id)kCTFontAttributeName: (__bridge id)font,
        (id)kCTForegroundColorAttributeName: (__bridge id)color,
        (id)kCTParagraphStyleAttributeName: (__bridge id)paragraph,
    }];
    CTFramesetterRef setter = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);
    CGPathRef path = CGPathCreateWithRect(box, NULL);
    CTFrameRef frame = CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, NULL);
    CTFrameDraw(frame, context);
    CFRelease(frame);
    CGPathRelease(path);
    CFRelease(setter);
    CFRelease(font);
    CFRelease(paragraph);
    CGColorRelease(color);
    CGColorSpaceRelease(space);
}

// The cover clipped round, with a hairline to lift it off the backdrop.
static void drawRoundedCover(CGContextRef context, CGImageRef cover, CGRect box, CGFloat radius) {
    CGPathRef path = CGPathCreateWithRoundedRect(box, radius, radius, NULL);
    CGContextSaveGState(context);
    CGContextAddPath(context, path);
    CGContextClip(context);
    CGContextDrawImage(context, box, cover);
    CGContextRestoreGState(context);
    CGContextSaveGState(context);
    CGContextAddPath(context, path);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat rim[] = {1, 1, 1, 0.16};
    CGColorRef rimColor = CGColorCreate(space, rim);
    CGContextSetStrokeColorWithColor(context, rimColor);
    CGContextSetLineWidth(context, MAX(box.size.width * 0.006, 1));
    CGContextStrokePath(context);
    CGColorRelease(rimColor);
    CGColorSpaceRelease(space);
    CGContextRestoreGState(context);
    CGPathRelease(path);
}

static void strokeCircle(CGContextRef context, CGPoint centre, CGFloat radius, CGFloat width, CGFloat alpha) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat ink[] = {0, 0, 0, alpha};
    CGColorRef color = CGColorCreate(space, ink);
    CGContextSetStrokeColorWithColor(context, color);
    CGContextSetLineWidth(context, width);
    CGContextStrokeEllipseInRect(context, CGRectMake(centre.x - radius, centre.y - radius, radius * 2, radius * 2));
    CGColorRelease(color);
    CGColorSpaceRelease(space);
}

// Poster: the cover, sharp and rounded, over the backdrop, and the line under it.
static void drawPoster(CGContextRef context, CGImageRef cover, NSString *line, CGSize size) {
    CGFloat side = size.width * 0.52;
    CGFloat top = size.height * 0.20;
    BOOL art = cover && CGImageGetWidth(cover) > 1;
    if (art) drawRoundedCover(context, cover, CGRectMake(round((size.width - side) / 2), round(size.height - top - side), side, side), side * 0.09);
    CGFloat fontSize = size.width * 0.055;
    setWordsShadow(context, fontSize);
    CGSize drawn = lineSize(line, fontSize, size.width * 0.8);
    CGFloat fromTop = art ? top + side + size.height * 0.05 : top;
    static const CGFloat white[] = {1, 1, 1};
    drawTextIn(context, line, fontSize, 1, CGRectMake(0, round(size.height - fromTop - drawn.height), size.width, drawn.height), kCTTextAlignmentCenter, white);
    CGContextSetShadowWithColor(context, CGSizeZero, 0, NULL);
}

// Vinyl: the cover as a record on a turntable, grooves and spindle over it, the line under.
static void drawVinylText(CGContextRef context, NSString *line, CGSize size) {
    if (!line.length) return;
    CGFloat fontSize = size.width * 0.05;
    static const CGFloat white[] = {1, 1, 1};
    // The system crops a 3:4 asset to a tall screen and overlays controls below it.
    // Measure and draw at the same safe width, shrinking long lines before they reach the record.
    CGFloat width = floor(size.width * 0.50);
    CGFloat maxHeight = floor(size.height * 0.17);
    CGSize drawn = lineSize(line, fontSize, width);
    while ((drawn.height > maxHeight || drawn.width > width) && fontSize > 1) {
        fontSize *= 0.94;
        drawn = lineSize(line, fontSize, width);
    }
    setWordsShadow(context, fontSize);
    drawTextIn(context, line, fontSize, 1,
               CGRectMake(round((size.width - width) / 2), round(size.height * 0.335 - drawn.height / 2),
                          width, drawn.height), kCTTextAlignmentCenter, white);
    CGContextSetShadowWithColor(context, CGSizeZero, 0, NULL);
}

static CGImageRef newVinylBaseImage(CGImageRef backdrop, NSString *line, CGSize size) CF_RETURNS_RETAINED {
    CGContextRef context = newContext(size, NULL, 0);
    if (backdrop) CGContextDrawImage(context, (CGRect){CGPointZero, size}, backdrop);
    CGFloat radius = size.width * 0.26;
    CGPoint centre = CGPointMake(size.width / 2, size.height * 0.63);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat ink[] = {0, 0, 0, 0.55};
    CGColorRef vinyl = CGColorCreate(space, ink);
    CGContextSetFillColorWithColor(context, vinyl);
    CGContextFillEllipseInRect(context, CGRectMake(centre.x - radius, centre.y - radius, radius * 2, radius * 2));
    CGColorRelease(vinyl);
    CGColorSpaceRelease(space);
    drawVinylText(context, line, size);
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

static CGImageRef newVinylDiscImage(CGImageRef cover, CGSize size) CF_RETURNS_RETAINED {
    CGFloat radius = size.width * 0.26;
    CGFloat side = ceil(radius * 2) + 4;
    CGSize discSize = CGSizeMake(side, side);
    CGPoint centre = CGPointMake(side / 2, side / 2);
    CGContextRef context = newContext(discSize, NULL, 0);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (cover && CGImageGetWidth(cover) > 1) {
        CGPathRef record = CGPathCreateWithEllipseInRect(CGRectMake(centre.x - radius, centre.y - radius, radius * 2, radius * 2), NULL);
        CGContextSaveGState(context);
        CGContextAddPath(context, record);
        CGContextClip(context);
        CGContextDrawImage(context, CGRectMake(centre.x - radius, centre.y - radius, radius * 2, radius * 2), cover);
        CGContextRestoreGState(context);
        CGPathRelease(record);
    }
    for (int groove = 1; groove <= 4; groove++) {
        strokeCircle(context, centre, radius * (0.3 + 0.14 * groove), MAX(radius * 0.008, 1), 0.22);
    }
    strokeCircle(context, centre, radius * 0.985, MAX(radius * 0.03, 2), 0.45);
    // The spindle: a dark hole with a light ring.
    CGFloat holeR = radius * 0.05;
    CGFloat hole[] = {0.08, 0.08, 0.09, 1};
    CGColorRef holeColor = CGColorCreate(space, hole);
    CGContextSetFillColorWithColor(context, holeColor);
    CGContextFillEllipseInRect(context, CGRectMake(centre.x - holeR, centre.y - holeR, holeR * 2, holeR * 2));
    CGColorRelease(holeColor);
    CGFloat ring[] = {1, 1, 1, 0.3};
    CGColorRef ringColor = CGColorCreate(space, ring);
    CGContextSetStrokeColorWithColor(context, ringColor);
    CGContextSetLineWidth(context, MAX(holeR * 0.5, 1));
    CGContextStrokeEllipseInRect(context, CGRectMake(centre.x - holeR * 1.6, centre.y - holeR * 1.6, holeR * 3.2, holeR * 3.2));
    CGColorRelease(ringColor);
    CGColorSpaceRelease(space);
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

static void drawVinylCached(CGContextRef context, CGImageRef baseImage, CGImageRef discImage, CGSize size, double phase, BOOL spin) {
    if (baseImage) CGContextDrawImage(context, (CGRect){CGPointZero, size}, baseImage);
    if (!discImage) return;
    CGPoint centre = CGPointMake(size.width / 2, size.height * 0.63);
    CGFloat side = CGImageGetWidth(discImage);
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, centre.x, centre.y);
    CGContextRotateCTM(context, spin ? phase * 2 * M_PI : 0);
    CGContextTranslateCTM(context, -centre.x, -centre.y);
    CGContextDrawImage(context, CGRectMake(centre.x - side / 2, centre.y - side / 2, side, side), discImage);
    CGContextRestoreGState(context);
}

static void drawVinyl(CGContextRef context, CGImageRef backdrop, CGImageRef cover, NSString *line, CGSize size, double phase, BOOL spin) {
    CGImageRef baseImage = newVinylBaseImage(backdrop, line, size);
    CGImageRef discImage = newVinylDiscImage(cover, size);
    drawVinylCached(context, baseImage, discImage, size, phase, spin);
    CGImageRelease(discImage);
    CGImageRelease(baseImage);
}

// Messages: the line in a chat bubble beside a round avatar of the cover.
static void drawMessages(CGContextRef context, CGImageRef cover, NSString *line, CGSize size) {
    CGFloat pad = size.width * 0.035;
    CGFloat fontSize = size.width * 0.042;
    CGFloat textWidth = size.width * 0.62 - pad * 2;
    CGSize drawn = lineSize(line, fontSize, textWidth);
    CGFloat bubbleHeight = MAX(drawn.height + pad * 2, fontSize * 2.2);
    CGFloat avatarSide = size.width * 0.15;
    CGFloat bottom = size.height * 0.26;   // the feet of both, clear of the controls
    CGPoint avatarCentre = CGPointMake(size.width * 0.155, bottom + avatarSide / 2);
    if (cover && CGImageGetWidth(cover) > 1) {
        drawRoundedCover(context, cover, CGRectMake(avatarCentre.x - avatarSide / 2, avatarCentre.y - avatarSide / 2, avatarSide, avatarSide), avatarSide / 2);
    }
    CGRect bubble = CGRectMake(avatarCentre.x + avatarSide / 2 + pad, bottom, textWidth + pad * 2, bubbleHeight);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat blue[] = {14 / 255.0, 122 / 255.0, 254 / 255.0, 1};
    CGColorRef bubbleColor = CGColorCreate(space, blue);
    CGContextSetFillColorWithColor(context, bubbleColor);
    CGFloat radius = MIN(bubbleHeight / 2, size.width * 0.06);
    CGPathRef path = CGPathCreateWithRoundedRect(bubble, radius, radius, NULL);
    CGContextAddPath(context, path);
    CGContextFillPath(context);
    // The tail, a small wedge off the bubble's lower left.
    CGMutablePathRef tail = CGPathCreateMutable();
    CGPathMoveToPoint(tail, NULL, bubble.origin.x + radius * 0.2, bubble.origin.y + radius * 0.4);
    CGPathAddLineToPoint(tail, NULL, bubble.origin.x - radius * 0.55, bubble.origin.y + radius * 0.1);
    CGPathAddLineToPoint(tail, NULL, bubble.origin.x + radius * 0.2, bubble.origin.y + radius * 1.6);
    CGPathCloseSubpath(tail);
    CGContextAddPath(context, tail);
    CGContextFillPath(context);
    CGPathRelease(tail);
    CGPathRelease(path);
    CGColorRelease(bubbleColor);
    CGColorSpaceRelease(space);
    CGFloat white[] = {1, 1, 1};
    drawTextIn(context, line, fontSize, 1, CGRectMake(CGRectGetMinX(bubble) + pad, bubble.origin.y + pad, textWidth, drawn.height), kCTTextAlignmentLeft, white);
}

// A five-point star in `box`, tip up.
static CGPathRef newStar(CGRect box) {
    CGMutablePathRef path = CGPathCreateMutable();
    CGPoint centre = CGPointMake(CGRectGetMidX(box), CGRectGetMidY(box));
    CGFloat radius = MIN(box.size.width, box.size.height) / 2;
    for (int i = 0; i < 10; i++) {
        double angle = M_PI / 2 + i * M_PI / 5;
        CGFloat reach = i % 2 ? radius * 0.45 : radius;
        CGPoint point = CGPointMake(centre.x + reach * cos(angle), centre.y + reach * sin(angle));
        if (i) CGPathAddLineToPoint(path, NULL, point.x, point.y);
        else CGPathMoveToPoint(path, NULL, point.x, point.y);
    }
    CGPathCloseSubpath(path);
    return path;
}

// Polaroid: the cover as a tilted instant print, the line written on the wide chin.
static void drawPolaroid(CGContextRef context, CGImageRef cover, NSString *line, CGSize size) {
    CGFloat side = size.width * 0.52, pad = side * 0.09;
    BOOL art = cover && CGImageGetWidth(cover) > 1;
    // The chin sits under the photo and grows to hold the caption; the font shrinks first.
    CGFloat fontSize = size.width * 0.034;
    CGSize caption = lineSize(line, fontSize, side);
    while (caption.height > side * 0.26 && fontSize > size.width * 0.024) {
        fontSize *= 0.85;
        caption = lineSize(line, fontSize, side);
    }
    CGFloat chin = MAX(side * 0.16, caption.height + pad * 1.2);
    CGSize frameSize = CGSizeMake(side + pad * 2, chin + side + pad);
    // The photo, where the eye looks, sits a little above the middle.
    CGFloat photoCentre = size.height * 0.58;
    CGRect frame = CGRectMake(round((size.width - frameSize.width) / 2), round(photoCentre - side / 2 - chin),
                              frameSize.width, frameSize.height);
    CGContextSaveGState(context);
    // The print hangs a hair off square.
    CGContextTranslateCTM(context, frame.origin.x + frameSize.width / 2, frame.origin.y + frameSize.height / 2);
    CGContextRotateCTM(context, -3 * M_PI / 180);
    CGContextTranslateCTM(context, -frame.origin.x - frameSize.width / 2, -frame.origin.y - frameSize.height / 2);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat shade[] = {0, 0, 0, 0.4};
    CGColorRef shadow = CGColorCreate(space, shade);
    CGContextSetShadowWithColor(context, CGSizeZero, size.width * 0.05, shadow);
    CGColorRelease(shadow);
    CGFloat paper[] = {0.97, 0.97, 0.96, 1};
    CGColorRef paperColor = CGColorCreate(space, paper);
    CGContextSetFillColorWithColor(context, paperColor);
    CGContextFillRect(context, frame);
    CGColorRelease(paperColor);
    CGContextSetShadowWithColor(context, CGSizeZero, 0, NULL);
    CGRect photo = CGRectMake(frame.origin.x + pad, frame.origin.y + chin, side, side);
    if (art) {
        CGPathRef window = CGPathCreateWithRoundedRect(photo, side * 0.02, side * 0.02, NULL);
        CGContextSaveGState(context);
        CGContextAddPath(context, window);
        CGContextClip(context);
        CGContextDrawImage(context, photo, cover);
        CGContextRestoreGState(context);
        CGPathRelease(window);
    } else {
        CGFloat mat[] = {0.85, 0.84, 0.82, 1};
        CGColorRef matColor = CGColorCreate(space, mat);
        CGContextSetFillColorWithColor(context, matColor);
        CGContextFillRect(context, photo);
        CGColorRelease(matColor);
    }
    CGFloat ink[] = {0.18, 0.17, 0.16, 1};
    drawTextIn(context, line, fontSize, 1, CGRectMake(frame.origin.x + pad, frame.origin.y + pad * 0.5, side,
                                                      caption.height), kCTTextAlignmentCenter, ink);
    CGColorSpaceRelease(space);
    CGContextRestoreGState(context);
}

// Stickers: the cover cut out as a die-cut sticker with a star beside it, the line on a label sticker.
static void drawStickers(CGContextRef context, CGImageRef cover, NSString *line, CGSize size) {
    CGFloat fontSize = size.width * 0.038;
    CGFloat textWidth = size.width * 0.62;
    CGSize caption = lineSize(line, fontSize, textWidth);
    CGRect label = CGRectMake(round(size.width * 0.15), round(size.height * 0.38 - caption.height - size.width * 0.06),
                              round(size.width * 0.70), round(caption.height + size.width * 0.06));
    CGFloat coverSide = size.width * 0.40;
    CGFloat border = MAX(size.width * 0.006, 1);
    BOOL art = cover && CGImageGetWidth(cover) > 1;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat shade[] = {0, 0, 0, 0.35};
    CGColorRef shadowColor = CGColorCreate(space, shade);
    CGFloat paper[] = {1, 1, 1, 1};
    CGColorRef paperColor = CGColorCreate(space, paper);
    CGFloat gray[] = {0.2, 0.2, 0.22, 0.5};
    CGColorRef outlineColor = CGColorCreate(space, gray);
    CGFloat radius = MIN(label.size.height / 2, size.width * 0.07);
    // The label with the line on it, stood a touch off square.
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, CGRectGetMidX(label), CGRectGetMidY(label));
    CGContextRotateCTM(context, 2 * M_PI / 180);
    CGContextTranslateCTM(context, -CGRectGetMidX(label), -CGRectGetMidY(label));
    CGContextSetShadowWithColor(context, CGSizeZero, size.width * 0.03, shadowColor);
    CGPathRef sheet = CGPathCreateWithRoundedRect(label, radius, radius, NULL);
    CGContextAddPath(context, sheet);
    CGContextSetFillColorWithColor(context, paperColor);
    CGContextFillPath(context);
    CGContextSetShadowWithColor(context, CGSizeZero, 0, NULL);
    CGContextAddPath(context, sheet);
    CGContextSetStrokeColorWithColor(context, outlineColor);
    CGContextSetLineWidth(context, border);
    CGContextStrokePath(context);
    CGPathRelease(sheet);
    CGFloat ink[] = {0.15, 0.14, 0.13, 1};
    drawTextIn(context, line, fontSize, 1, CGRectMake(CGRectGetMinX(label) + size.width * 0.04,
                                                      CGRectGetMinY(label) + size.width * 0.03, textWidth, caption.height),
               kCTTextAlignmentCenter, ink);
    CGContextRestoreGState(context);
    // The cover sticker, tilted the other way.
    CGPoint coverCentre = CGPointMake(size.width * 0.40, size.height * 0.60);
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, coverCentre.x, coverCentre.y);
    CGContextRotateCTM(context, -6 * M_PI / 180);
    CGContextTranslateCTM(context, -coverCentre.x, -coverCentre.y);
    CGRect cut = CGRectMake(coverCentre.x - coverSide / 2, coverCentre.y - coverSide / 2, coverSide, coverSide);
    CGContextSetShadowWithColor(context, CGSizeZero, size.width * 0.03, shadowColor);
    CGPathRef die = CGPathCreateWithRoundedRect(cut, coverSide * 0.16, coverSide * 0.16, NULL);
    CGContextAddPath(context, die);
    CGContextSetFillColorWithColor(context, paperColor);
    CGContextFillPath(context);
    CGContextSetShadowWithColor(context, CGSizeZero, 0, NULL);
    CGContextAddPath(context, die);
    CGContextSetStrokeColorWithColor(context, outlineColor);
    CGContextSetLineWidth(context, border);
    CGContextStrokePath(context);
    CGPathRef print = CGPathCreateWithRoundedRect(CGRectInset(cut, coverSide * 0.08, coverSide * 0.08),
                                                  coverSide * 0.12, coverSide * 0.12, NULL);
    if (art) {
        CGContextSaveGState(context);
        CGContextAddPath(context, print);
        CGContextClip(context);
        CGContextDrawImage(context, cut, cover);
        CGContextRestoreGState(context);
    } else {
        CGFloat mat[] = {0.85, 0.84, 0.82, 1};
        CGColorRef matColor = CGColorCreate(space, mat);
        CGContextSetFillColorWithColor(context, matColor);
        CGContextAddPath(context, print);
        CGContextFillPath(context);
        CGColorRelease(matColor);
    }
    CGPathRelease(print);
    CGPathRelease(die);
    CGContextRestoreGState(context);
    // A small star sticker pasted beside the cover's corner.
    CGPoint starCentre = CGPointMake(size.width * 0.80, size.height * 0.76);
    CGFloat starSide = size.width * 0.14;
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, starCentre.x, starCentre.y);
    CGContextRotateCTM(context, -12 * M_PI / 180);
    CGContextTranslateCTM(context, -starCentre.x, -starCentre.y);
    CGContextSetShadowWithColor(context, CGSizeZero, size.width * 0.02, shadowColor);
    CGContextSetFillColorWithColor(context, paperColor);
    CGPathRef backing = newStar(CGRectMake(starCentre.x - starSide * 0.65, starCentre.y - starSide * 0.65,
                                           starSide * 1.3, starSide * 1.3));
    CGContextAddPath(context, backing);
    CGContextFillPath(context);
    CGContextSetShadowWithColor(context, CGSizeZero, 0, NULL);
    CGContextAddPath(context, backing);
    CGContextSetStrokeColorWithColor(context, outlineColor);
    CGContextSetLineWidth(context, border);
    CGContextStrokePath(context);
    CGPathRelease(backing);
    CGFloat amber[] = {0.99, 0.78, 0.12, 1};
    CGColorRef amberColor = CGColorCreate(space, amber);
    CGContextSetFillColorWithColor(context, amberColor);
    CGPathRef star = newStar(CGRectMake(starCentre.x - starSide / 2, starCentre.y - starSide / 2, starSide, starSide));
    CGContextAddPath(context, star);
    CGContextFillPath(context);
    CGPathRelease(star);
    CGColorRelease(amberColor);
    CGContextRestoreGState(context);
    CGColorRelease(shadowColor);
    CGColorRelease(paperColor);
    CGColorRelease(outlineColor);
    CGColorSpaceRelease(space);
}

// Duotone: the tinted cover across the whole screen, the line on it. Two blend fills make the ramp, so no
// filter runs: the light tone holds the highlights, the cover's gray carries the detail and the dark tone
// lifts the shadows.
static void drawDuotone(CGContextRef context, CGImageRef cover, NSString *line, CGSize size) {
    CGRect bounds = (CGRect){CGPointZero, size};
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat dark[] = {0.10, 0.09, 0.24};
    CGFloat light[] = {0.95, 0.75, 0.55};
    if (cover && CGImageGetWidth(cover) > 1) {
        CGFloat scale = MAX(size.width / CGImageGetWidth(cover), size.height / CGImageGetHeight(cover));
        CGRect fill = CGRectMake((size.width - CGImageGetWidth(cover) * scale) / 2,
                                 (size.height - CGImageGetHeight(cover) * scale) / 2,
                                 CGImageGetWidth(cover) * scale, CGImageGetHeight(cover) * scale);
        CGContextSaveGState(context);
        CGContextClipToRect(context, bounds);
        CGContextSetRGBFillColor(context, light[0], light[1], light[2], 1);
        CGContextFillRect(context, bounds);
        CGContextSetBlendMode(context, kCGBlendModeMultiply);
        CGContextDrawImage(context, fill, cover);
        CGContextSetBlendMode(context, kCGBlendModePlusLighter);
        CGContextSetRGBFillColor(context, dark[0], dark[1], dark[2], 1);
        CGContextFillRect(context, bounds);
        CGContextRestoreGState(context);
    } else {
        CGGradientRef gradient = CGGradientCreateWithColorComponents(space,
            (CGFloat[]){dark[0], dark[1], dark[2], 1, light[0], light[1], light[2], 1}, (CGFloat[]){0, 1}, 2);
        CGContextDrawLinearGradient(context, gradient, CGPointZero, CGPointMake(0, size.height), 0);
        CGGradientRelease(gradient);
    }
    // Eased off a little, so the white line reads over the light tone.
    CGContextSetRGBFillColor(context, 0, 0, 0, 0.32);
    CGContextFillRect(context, bounds);
    CGFloat fontSize = size.width * 0.05;
    static const CGFloat white[] = {1, 1, 1};
    setWordsShadow(context, fontSize);
    CGSize drawn = lineSize(line, fontSize, size.width * 0.8);
    drawTextIn(context, line, fontSize, 1, CGRectMake(0, round(size.height * (1 - kCentreY) - drawn.height / 2),
                                                      size.width, drawn.height), kCTTextAlignmentCenter, white);
    CGContextSetShadowWithColor(context, CGSizeZero, 0, NULL);
    CGColorSpaceRelease(space);
}

// One frame of a composition: the backdrop, then the words and the art over it. Vinyl spins only when
// the clip animates; the others are one frame either way.
static void drawComposition(CGContextRef context, CGImageRef backdrop, CGImageRef cover, NSString *line, CGSize size,
                            double phase, SGLyricsClipComposition composition, BOOL animated) {
    if (composition == SGLyricsClipVinyl) {
        drawVinyl(context, backdrop, cover, line, size, phase, animated);
        return;
    }
    CGContextDrawImage(context, (CGRect){CGPointZero, size}, backdrop);
    switch (composition) {
        case SGLyricsClipPoster:
            drawPoster(context, cover, line, size);
            break;
        case SGLyricsClipMessages:
            drawMessages(context, cover, line, size);
            break;
        case SGLyricsClipPolaroid:
            drawPolaroid(context, cover, line, size);
            break;
        case SGLyricsClipStickers:
            drawStickers(context, cover, line, size);
            break;
        case SGLyricsClipDuotone:
            drawDuotone(context, cover, line, size);
            break;
        default:
            break;
    }
}

CGImageRef SGLyricsClipFrameIn(CGImageRef backdrop, CGImageRef cover, NSString *line, NSString *next, CGSize size,
                               SGLyricsClipStyle style, SGLyricsClipComposition composition) {
    return SGLyricsClipFrameInAtTime(backdrop, cover, line, next, size, style, composition, 0);
}

CGImageRef SGLyricsClipFrameInAtTime(CGImageRef backdrop, CGImageRef cover, NSString *line, NSString *next, CGSize size,
                                    SGLyricsClipStyle style, SGLyricsClipComposition composition, double from) {
    if (composition == SGLyricsClipWords) {
        CGImageRef words = newWords(NULL, line, next, size, NULL);
        CGContextRef context = newContext(size, NULL, 0);
        drawFrame(context, backdrop, words, size, 0);
        CGImageRef frame = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
        CGImageRelease(words);
        return frame;
    }
    CGContextRef context = newContext(size, NULL, 0);
    drawComposition(context, backdrop, cover, line, size, isfinite(from) ? from / kLoopSeconds : 0,
                    composition, style == SGLyricsClipAnimated);
    CGImageRef frame = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return frame;
}

BOOL SGLyricsClipWriteIn(NSURL *file, CGImageRef backdrop, CGImageRef cover, NSString *line, NSString *next, CGSize size,
                         SGLyricsClipStyle style, SGLyricsClipComposition composition) {
    return SGLyricsClipWriteInAtTime(file, backdrop, cover, line, next, size, style, composition, 0);
}

BOOL SGLyricsClipWriteInAtTime(NSURL *file, CGImageRef backdrop, CGImageRef cover, NSString *line, NSString *next, CGSize size,
                              SGLyricsClipStyle style, SGLyricsClipComposition composition, double from) {
    if (composition == SGLyricsClipWords) return SGLyricsClipWrite(file, backdrop, line, next, size, style);
    // Written beside the file and moved over it once whole, so a clip cut off halfway is never found.
    NSURL *partial = [file URLByAppendingPathExtension:@"partial"];
    [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:partial fileType:AVFileTypeMPEG4 error:nil];
    if (!writer) return NO;
    BOOL spinning = style == SGLyricsClipAnimated && composition == SGLyricsClipVinyl;
    int32_t frames = spinning ? kLoopSeconds * kFPS : 1;
    CMTime length = CMTimeMake(spinning ? kLoopSeconds : kStillSeconds, 1);
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(size.width),
        AVVideoHeightKey: @(size.height),
        AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(2000000), AVVideoMaxKeyFrameIntervalKey: @(kFPS)},
    }];
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
        sourcePixelBufferAttributes:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(size.width),
            (id)kCVPixelBufferHeightKey: @(size.height),
        }];
    if (![writer canAddInput:input]) return NO;
    [writer addInput:input];
    if (![writer startWriting]) return NO;
    [writer startSessionAtSourceTime:kCMTimeZero];
    CGImageRef vinylBase = composition == SGLyricsClipVinyl ? newVinylBaseImage(backdrop, line, size) : NULL;
    CGImageRef vinylDisc = composition == SGLyricsClipVinyl ? newVinylDiscImage(cover, size) : NULL;
    BOOL ok = YES;
    for (int32_t i = 0; i < frames && ok; i++) {
        while (!input.readyForMoreMediaData && writer.status == AVAssetWriterStatusWriting) [NSThread sleepForTimeInterval:0.002];
        CVPixelBufferRef buffer = NULL;
        ok = writer.status == AVAssetWriterStatusWriting && adaptor.pixelBufferPool
            && CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer) == kCVReturnSuccess;
        if (!ok) break;
        CVPixelBufferLockBaseAddress(buffer, 0);
        CGContextRef context = newContext(size, CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetBytesPerRow(buffer));
        double phase = (isfinite(from) ? from / kLoopSeconds : 0) + (double)i / frames;
        if (composition == SGLyricsClipVinyl) {
            drawVinylCached(context, vinylBase, vinylDisc, size, phase, style == SGLyricsClipAnimated);
        } else {
            drawComposition(context, backdrop, cover, line, size, phase, composition, style == SGLyricsClipAnimated);
        }
        CGContextRelease(context);
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        ok = [adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(i, kFPS)];
        CVPixelBufferRelease(buffer);
    }
    CGImageRelease(vinylDisc);
    CGImageRelease(vinylBase);
    if (!ok) {
        [writer cancelWriting];
        return NO;
    }
    [input markAsFinished];
    [writer endSessionAtSourceTime:length];
    dispatch_semaphore_t written = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(written); }];
    dispatch_semaphore_wait(written, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) return NO;
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    return [NSFileManager.defaultManager moveItemAtURL:partial toURL:file error:nil];
}

NSString *SGLyricsClipLook(NSURL *motion, SGLyricsClipStyle style, SGLyricsClipComposition composition) {
    if (!motion) return [NSString stringWithFormat:@"%ld-%ld", (long)composition, (long)style];
    NSString *name = motion.lastPathComponent.stringByDeletingPathExtension;
    return [NSString stringWithFormat:@"m%@s%ld-%ld", name.length > 16 ? [name substringToIndex:16] : name, (long)style, (long)composition];
}

BOOL SGLyricsClipWrite(NSURL *file, CGImageRef backdrop, NSString *line, NSString *next, CGSize size, SGLyricsClipStyle style) {
    // Written beside the file and moved over it once whole, so a clip cut off halfway is never found.
    NSURL *partial = [file URLByAppendingPathExtension:@"partial"];
    [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:partial fileType:AVFileTypeMPEG4 error:nil];
    if (!writer) return NO;
    int32_t frames = style == SGLyricsClipAnimated ? kLoopSeconds * kFPS : 1;
    CMTime length = CMTimeMake(style == SGLyricsClipAnimated ? kLoopSeconds : kStillSeconds, 1);
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(size.width),
        AVVideoHeightKey: @(size.height),
        AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(2000000), AVVideoMaxKeyFrameIntervalKey: @(kFPS)},
    }];
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
        sourcePixelBufferAttributes:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(size.width),
            (id)kCVPixelBufferHeightKey: @(size.height),
        }];
    if (![writer canAddInput:input]) return NO;
    [writer addInput:input];
    if (![writer startWriting]) return NO;
    [writer startSessionAtSourceTime:kCMTimeZero];
    CGImageRef words = newWords(nil, line, next, size, NULL);
    BOOL ok = YES;
    for (int32_t i = 0; i < frames && ok; i++) {
        while (!input.readyForMoreMediaData && writer.status == AVAssetWriterStatusWriting) [NSThread sleepForTimeInterval:0.002];
        CVPixelBufferRef buffer = NULL;
        ok = writer.status == AVAssetWriterStatusWriting && adaptor.pixelBufferPool
            && CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer) == kCVReturnSuccess;
        if (!ok) break;
        CVPixelBufferLockBaseAddress(buffer, 0);
        CGContextRef context = newContext(size, CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetBytesPerRow(buffer));
        drawFrame(context, backdrop, words, size, (double)i / frames);
        CGContextRelease(context);
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        ok = [adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(i, kFPS)];
        CVPixelBufferRelease(buffer);
    }
    CGImageRelease(words);
    if (!ok) {
        [writer cancelWriting];
        return NO;
    }
    [input markAsFinished];
    // The last frame, or a still's only one, is held to the end of the loop.
    [writer endSessionAtSourceTime:length];
    dispatch_semaphore_t written = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(written); }];
    dispatch_semaphore_wait(written, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) return NO;
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    return [NSFileManager.defaultManager moveItemAtURL:partial toURL:file error:nil];
}

typedef struct {
    CGSize stored, cut;
    double length;
} Motion;

static AVAssetTrack *motionTrack(AVURLAsset *asset, Motion *motion) {
    __block AVAssetTrack *track = nil;
    dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
    [asset loadTracksWithMediaType:AVMediaTypeVideo completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *error) {
        track = tracks.firstObject;
        dispatch_semaphore_signal(loaded);
    }];
    dispatch_semaphore_wait(loaded, DISPATCH_TIME_FOREVER);
    if (!track || !CGAffineTransformIsIdentity(track.preferredTransform)) return nil;
    CGSize stored = CGSizeMake(round(track.naturalSize.width), round(track.naturalSize.height));
    double length = CMTimeGetSeconds(track.timeRange.duration);
    if (stored.width < 16 || stored.height < 16 || !(length > 0)) return nil;
    CGSize cut = stored.width / stored.height > 0.75 ? CGSizeMake(stored.height * 0.75, stored.height)
                                                     : CGSizeMake(stored.width, stored.width / 0.75);
    *motion = (Motion){stored, CGSizeMake(floor(cut.width / 2) * 2, floor(cut.height / 2) * 2), length};
    return track;
}

static CGRect cutIn(Motion motion) {
    return CGRectMake(round((motion.stored.width - motion.cut.width) / 2), round((motion.stored.height - motion.cut.height) / 2),
                      motion.cut.width, motion.cut.height);
}

typedef struct {
    CGImageRef words;
    CGRect drawn;
    uint16_t *keep;
    CGRect soft;
    uint8_t *blurred;
    uint16_t *feather;
} Over;

static CGFloat dimAt(size_t y, size_t height) {
    CGFloat reach = height * kBandReach, t = (y - (height * kCentreY - reach)) / (2 * reach);
    if (t <= 0 || t >= 1) return kMotionDim;
    CGFloat edge = MIN(MIN(t, 1 - t) / 0.3, 1);
    return kMotionDim + (kBandDim - kMotionDim) * edge;
}

static Over makeOver(Motion motion, NSString *previous, NSString *line, NSString *next) {
    Over over = {0};
    over.words = newWords(previous, line, next, motion.cut, &over.drawn);
    size_t rows = (size_t)motion.cut.height;
    over.keep = malloc(rows * sizeof(uint16_t));
    for (size_t y = 0; y < rows; y++) over.keep[y] = (uint16_t)round(256 * (1 - dimAt(y, rows)));
    if (!over.words) return over;
    CGRect cut = cutIn(motion);
    over.soft = CGRectMake(cut.origin.x, cut.origin.y + over.drawn.origin.y, cut.size.width, over.drawn.size.height);
    size_t width = (size_t)over.soft.size.width, height = (size_t)over.soft.size.height;
    size_t fade = MAX(MIN((size_t)(motion.cut.width * kFont), height / 2), 1);
    over.blurred = malloc(width * height * 4);
    over.feather = malloc(height * sizeof(uint16_t));
    for (size_t y = 0; y < height; y++) over.feather[y] = (uint16_t)(256 * MIN(1.0, MIN(y, height - 1 - y) / (double)fade));
    return over;
}

static void freeOver(Over over) {
    CGImageRelease(over.words);
    free(over.keep);
    free(over.blurred);
    free(over.feather);
}

static BOOL drawOver(CVPixelBufferRef buffer, Motion motion, Over over) {
    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(buffer);
    CGRect cut = cutIn(motion);
    size_t frameWidth = CVPixelBufferGetWidth(buffer), frameHeight = CVPixelBufferGetHeight(buffer);
    CGRect frame = CGRectMake(0, 0, frameWidth, frameHeight);
    if (!base || CVPixelBufferIsPlanar(buffer) || CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_32BGRA
        || frameWidth != (size_t)motion.stored.width || frameHeight != (size_t)motion.stored.height || bytesPerRow < frameWidth * 4
        || !CGRectContainsRect(frame, cut) || (over.blurred && !CGRectContainsRect(frame, over.soft))) {
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        return NO;
    }
    if (over.blurred) {
        size_t top = (size_t)(motion.stored.height - CGRectGetMaxY(over.soft)), height = (size_t)over.soft.size.height;
        size_t width = (size_t)over.soft.size.width, rowBytes = width * 4;
        uint8_t *rows = base + top * bytesPerRow + (size_t)over.soft.origin.x * 4;
        vImage_Buffer from = {rows, height, width, bytesPerRow}, to = {over.blurred, height, width, rowBytes};
        uint32_t kernel = (uint32_t)(width * kSoftWidth) | 1;
        if (vImageTentConvolve_ARGB8888(&from, &to, NULL, 0, 0, kernel, kernel, NULL, kvImageEdgeExtend) == kvImageNoError) {
            for (size_t y = 0; y < height; y++) {
                uint8_t *sharp = rows + y * bytesPerRow;
                const uint8_t *soft = over.blurred + y * rowBytes;
                uint16_t share = over.feather[y];
                if (share == 256) memcpy(sharp, soft, rowBytes);
                else if (share) for (size_t i = 0; i < rowBytes; i++) sharp[i] += (uint8_t)(((soft[i] - sharp[i]) * share) >> 8);
            }
        }
    }
    size_t top = (size_t)cut.origin.y, width = (size_t)cut.size.width;
    for (size_t y = 0; y < (size_t)cut.size.height; y++) {
        uint32_t *pixel = (uint32_t *)(base + (top + y) * bytesPerRow) + (size_t)cut.origin.x, keep = over.keep[y];
        for (size_t x = 0; x < width; x++) {
            uint32_t v = pixel[x];
            pixel[x] = (((v & 0x00FF00FFu) * keep >> 8) & 0x00FF00FFu)
                     | (((v & 0x0000FF00u) * keep >> 8) & 0x0000FF00u) | (v & 0xFF000000u);
        }
    }
    if (over.words) {
        CGContextRef context = newContext(motion.stored, base, bytesPerRow);
        CGContextDrawImage(context, CGRectOffset(over.drawn, cut.origin.x, cut.origin.y), over.words);
        CGContextRelease(context);
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return YES;
}

static BOOL eachFrame(AVURLAsset *asset, AVAssetTrack *track, Motion motion, double from, double seconds,
                      BOOL (^each)(CMSampleBufferRef sample)) {
    int32_t scale = 600;
    double at = fmod(MAX(from, 0), motion.length), done = 0, due = 0;
    while (seconds - done > 0.01) {
        double take = MIN(motion.length - at, seconds - done);
        AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
        AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        }];
        output.alwaysCopiesSampleData = YES;
        if (!reader || ![reader canAddOutput:output]) return NO;
        [reader addOutput:output];
        reader.timeRange = CMTimeRangeMake(CMTimeMakeWithSeconds(at, scale), CMTimeMakeWithSeconds(take, scale));
        if (![reader startReading]) return NO;
        CMSampleBufferRef sample;
        while ((sample = [output copyNextSampleBuffer])) {
            CMTime time = CMTimeMakeWithSeconds(done + MAX(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) - at, 0), scale);
            CMSampleBufferRef timed = NULL;
            CMSampleTimingInfo timing = {kCMTimeInvalid, time, kCMTimeInvalid};
            BOOL keep = CMTimeGetSeconds(time) >= due - 0.002 && CMTimeGetSeconds(time) < done + take
                && CMSampleBufferGetImageBuffer(sample)
                && CMSampleBufferCreateCopyWithNewTiming(NULL, sample, 1, &timing, &timed) == noErr;
            CFRelease(sample);
            if (!keep) continue;
            due = due + 1.0 / kMotionFPS < CMTimeGetSeconds(time)
                ? CMTimeGetSeconds(time) + 0.5 / kMotionFPS : due + 1.0 / kMotionFPS;
            BOOL more = each(timed);
            CFRelease(timed);
            if (!more) {
                [reader cancelReading];
                return YES;
            }
        }
        if (reader.status != AVAssetReaderStatusCompleted) return NO;
        done += take;
        at = 0;
    }
    return YES;
}

CGImageRef SGLyricsClipMotionFrame(NSURL *motionFile, NSString *previous, NSString *line, NSString *next, double from) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:motionFile options:nil];
    Motion motion;
    AVAssetTrack *track = motionTrack(asset, &motion);
    if (!track) return NULL;
    Over over = makeOver(motion, previous, line, next);
    __block CGImageRef frame = NULL;
    eachFrame(asset, track, motion, from, motion.length, ^BOOL(CMSampleBufferRef sample) {
        CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sample);
        if (!drawOver(buffer, motion, over)) return NO;
        CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
        CGContextRef context = newContext(motion.stored, CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetBytesPerRow(buffer));
        CGImageRef whole = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
        CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
        frame = CGImageCreateWithImageInRect(whole, cutIn(motion));
        CGImageRelease(whole);
        return NO;
    });
    freeOver(over);
    return frame;
}

BOOL SGLyricsClipWriteOverMotion(NSURL *file, NSURL *motionFile, NSString *previous, NSString *line, NSString *next,
                                 double from, double seconds) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:motionFile options:nil];
    Motion motion;
    AVAssetTrack *track = motionTrack(asset, &motion);
    if (!track) return NO;
    seconds = MIN(seconds, motion.length);
    NSURL *partial = [file URLByAppendingPathExtension:@"partial"];
    [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:partial fileType:AVFileTypeMPEG4 error:nil];
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(motion.cut.width),
        AVVideoHeightKey: @(motion.cut.height),
        AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
        AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(motion.cut.width * motion.cut.height * 3)},
    }];
    if (!writer || ![writer canAddInput:input]) return NO;
    [writer addInput:input];
    if (![writer startWriting]) return NO;
    [writer startSessionAtSourceTime:kCMTimeZero];
    Over over = makeOver(motion, previous, line, next);
    __block BOOL ok = YES, any = NO;
    BOOL read = eachFrame(asset, track, motion, from, seconds, ^BOOL(CMSampleBufferRef sample) {
        if (!drawOver(CMSampleBufferGetImageBuffer(sample), motion, over)) {
            ok = NO;
            return NO;
        }
        while (!input.readyForMoreMediaData && writer.status == AVAssetWriterStatusWriting) [NSThread sleepForTimeInterval:0.002];
        ok = writer.status == AVAssetWriterStatusWriting && [input appendSampleBuffer:sample];
        any = YES;
        return ok;
    });
    freeOver(over);
    if (!read || !ok || !any) {
        [writer cancelWriting];
        return NO;
    }
    [input markAsFinished];
    [writer endSessionAtSourceTime:CMTimeMakeWithSeconds(seconds, 600)];
    dispatch_semaphore_t written = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(written); }];
    dispatch_semaphore_wait(written, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) return NO;
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    return [NSFileManager.defaultManager moveItemAtURL:partial toURL:file error:nil];
}
