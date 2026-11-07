// The lyrics' look as stored, its presets and the preview's lines. The page is LyricsLookSettings.m.
#import "LyricsLook.h"
#import "Core/SGCore.h"
#import "Shared/Fonts/Fonts.h"

NSNotificationName const SGRLyricsLookDidChangeNotification = @"spotifyglass.redesign.lyricsLookDidChange";

// The sliders' ranges, which a stored look is held to as well.
static const SGRLyricsLook kLeast = {22, 12, 0, 0, 0}, kMost = {40, 40, 2, 2, 2};

static SGRLyricsLook presets[] = {
    {30, 24, 1, 1, 1},          // Apple Music: its 30 pt lines, 24 pt apart
    {36, 28, 1, 1, 1},          // Large
    {25, 16, 1, 1, 1},          // Compact
    {30, 24, 0, 0, 0},          // Calm: every line sharp, and nothing held glows or waves
    {32, 26, 1.4, 1.6, 1.8},    // Vivid
};

NSArray<NSString *> *SGRLyricsLookPresetNames(void) {
    return @[@"Apple Music", @"Large", @"Compact", @"Calm", @"Vivid"];
}

SGRLyricsLook SGRLyricsLookPreset(NSUInteger index) {
    return presets[MIN(index, sizeof(presets) / sizeof(*presets) - 1)];
}

static CGFloat held(CGFloat value, CGFloat least, CGFloat most) {
    return isfinite(value) ? MAX(least, MIN(most, value)) : least;
}

static CGFloat stored(NSDictionary *look, NSString *name, CGFloat fallback, CGFloat least, CGFloat most) {
    id value = look[name];
    return [value isKindOfClass:NSNumber.class] ? held([value doubleValue], least, most) : fallback;
}

SGRLyricsLook SGRLyricsLookNow(void) {
    SGRLyricsLook look = presets[0];
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:SGRKeyLyricsLook];
    if (!saved) return look;
    look.size = stored(saved, @"size", look.size, kLeast.size, kMost.size);
    look.spacing = stored(saved, @"spacing", look.spacing, kLeast.spacing, kMost.spacing);
    look.blur = stored(saved, @"blur", look.blur, kLeast.blur, kMost.blur);
    look.glow = stored(saved, @"glow", look.glow, kLeast.glow, kMost.glow);
    look.wave = stored(saved, @"wave", look.wave, kLeast.wave, kMost.wave);
    return look;
}

void SGRSetLyricsLook(SGRLyricsLook look, id changer) {
    [NSUserDefaults.standardUserDefaults setObject:@{
        @"size": @(held(look.size, kLeast.size, kMost.size)),
        @"spacing": @(held(look.spacing, kLeast.spacing, kMost.spacing)),
        @"blur": @(held(look.blur, kLeast.blur, kMost.blur)),
        @"glow": @(held(look.glow, kLeast.glow, kMost.glow)),
        @"wave": @(held(look.wave, kLeast.wave, kMost.wave)),
    } forKey:SGRKeyLyricsLook];
    [NSNotificationCenter.defaultCenter postNotificationName:SGRLyricsLookDidChangeNotification object:changer];
}

// Equal to the slider's step, so a look slid back onto a preset's values reads as that preset again.
static BOOL same(CGFloat a, CGFloat b) {
    return fabs(a - b) < 0.01;
}

NSInteger SGRLyricsLookPresetIndex(SGRLyricsLook look) {
    for (NSUInteger i = 0; i < sizeof(presets) / sizeof(*presets); i++) {
        SGRLyricsLook preset = presets[i];
        if (same(look.size, preset.size) && same(look.spacing, preset.spacing) && same(look.blur, preset.blur)
            && same(look.glow, preset.glow) && same(look.wave, preset.wave)) return (NSInteger)i;
    }
    return -1;
}

#pragma mark - the animation

NSArray<NSString *> *SGRLyricsAnimationNames(void) {
    return @[@"Wave", @"Glow", @"Bounce", @"Ripple", @"Float", @"Apple Music", @"Snappy"];
}

static const SGRLyricsAnimation animations[] = {
    // letters wordLift letterLift glow spread bounce feather dim  riseMs move damp stagger fade
    {YES, 0,  5,   8,  0.5,  NO,  22, 0.97, 700,  0.7, 0.86, 0.04, 0.35},   // Wave: letters rise and glow one after another
    {YES, 0,  1.5, 14, 0.7,  NO,  26, 0.97, 700,  0.7, 0.86, 0.04, 0.35},   // Glow: hardly rise, shine
    {YES, 0,  9,   6,  0.45, YES, 14, 0.94, 700,  0.8, 0.6,  0.05, 0.3},    // Bounce: letters spring up and overshoot
    {YES, 0,  7,   10, 0.9,  NO,  40, 0.96, 1100, 0.9, 0.9,  0.08, 0.5},    // Ripple: a slow, wide wave through the word
    {NO,  10, 0,   0,  0,    NO,  44, 0.97, 1600, 0.9, 0.9,  0.05, 0.6},    // Float: the whole word drifts up
    {NO,  2.5, 0,  0,  0,    NO,  22, 0.97, 700,  0.7, 0.86, 0.04, 0.35},   // Apple Music
    {NO,  1,  0,   0,  0,    NO,  10, 0.97, 500,  0.3, 1.0,  0,    0.12},   // Snappy: nearly at once
};

void SGRResetLyricsLook(id changer) {
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    [store removeObjectForKey:SGRKeyLyricsLook];
    [store removeObjectForKey:SGRKeyLyricsFont];
    [store removeObjectForKey:SGRKeyLyricsAnimation];
    [store removeObjectForKey:SGRKeyLyricsShader];
    [store removeObjectForKey:SGRKeyLyricsShaderOptions];
    [NSNotificationCenter.defaultCenter postNotificationName:SGRLyricsLookDidChangeNotification object:changer];
}

NSInteger SGRLyricsAnimationIndex(void) {
    NSInteger index = [NSUserDefaults.standardUserDefaults integerForKey:SGRKeyLyricsAnimation];
    return index >= 0 && index < (NSInteger)SGRLyricsAnimationNames().count ? index : 0;
}

void SGRSetLyricsAnimationIndex(NSInteger index, id changer) {
    [NSUserDefaults.standardUserDefaults setInteger:index forKey:SGRKeyLyricsAnimation];
    [NSNotificationCenter.defaultCenter postNotificationName:SGRLyricsLookDidChangeNotification object:changer];
}

SGRLyricsAnimation SGRLyricsAnimationNow(void) {
    return animations[SGRLyricsAnimationIndex()];
}

#pragma mark - the shader

NSArray<NSString *> *SGRLyricsShaderNames(void) {
    return @[@"Classic", @"Neon", @"Inferno", @"Hologram", @"Chrome", @"Blueprint"];
}

// The lit word, the dim word, the glow behind the letters, and the glow's scale; Classic is white.
typedef struct { CGFloat lit[3], dim[3], glow[3], scale; } SGRLyricsShaderStyle;

static const SGRLyricsShaderStyle shaders[] = {
    {{1, 1, 1},          {1, 1, 1},          {1, 1, 1},          1},     // Classic
    {{1.0, 0.31, 0.85},  {1.0, 0.31, 0.85},  {0.69, 0.29, 1.0},  1.8},   // Neon
    {{1.0, 0.71, 0.23},  {1.0, 0.35, 0.17},  {1.0, 0.30, 0.0},   2.0},   // Inferno
    {{0.62, 0.96, 1.0},  {0.37, 0.84, 1.0},  {0.30, 0.88, 1.0},  1.6},   // Hologram
    {{0.91, 0.94, 0.98}, {1, 1, 1},          {0.78, 0.85, 0.91}, 1.4},   // Chrome
    {{0.50, 0.83, 1.0},  {0.50, 0.83, 1.0},  {0.18, 0.48, 1.0},  1.5},   // Blueprint
};

NSInteger SGRLyricsShaderIndex(void) {
    NSInteger index = [NSUserDefaults.standardUserDefaults integerForKey:SGRKeyLyricsShader];
    return index >= 0 && index < (NSInteger)SGRLyricsShaderNames().count ? index : 0;
}

void SGRSetLyricsShaderIndex(NSInteger index, id changer) {
    NSInteger safe = index >= 0 && index < (NSInteger)SGRLyricsShaderNames().count ? index : 0;
    [NSUserDefaults.standardUserDefaults setInteger:safe forKey:SGRKeyLyricsShader];
    [NSNotificationCenter.defaultCenter postNotificationName:SGRLyricsLookDidChangeNotification object:changer];
}

SGRLyricsShaderOptions SGRLyricsShaderOptionsNow(void) {
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:SGRKeyLyricsShaderOptions];
    return (SGRLyricsShaderOptions){stored(saved, @"intensity", 0.85, 0, 1), stored(saved, @"speed", 1, 0.35, 2)};
}

void SGRSetLyricsShaderOptions(SGRLyricsShaderOptions options, id changer) {
    [NSUserDefaults.standardUserDefaults setObject:@{@"intensity": @(held(options.intensity, 0, 1)), @"speed": @(held(options.speed, 0.35, 2))} forKey:SGRKeyLyricsShaderOptions];
    [NSNotificationCenter.defaultCenter postNotificationName:SGRLyricsLookDidChangeNotification object:changer];
}

NSData *SGRLyricsShaderProfileData(NSError **error) {
    SGRLyricsShaderOptions options = SGRLyricsShaderOptionsNow();
    return [NSJSONSerialization dataWithJSONObject:@{@"format": @"spoti.pw.lyrics-effect", @"version": @1,
        @"effect": SGRLyricsShaderNames()[(NSUInteger)SGRLyricsShaderIndex()], @"intensity": @(options.intensity), @"speed": @(options.speed)}
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:error];
}

BOOL SGRImportLyricsShaderProfile(NSData *data, id changer, NSError **error) {
    id decoded = data.length <= 16 * 1024 && data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *profile = [decoded isKindOfClass:NSDictionary.class] ? decoded : nil;
    NSSet *keys = [NSSet setWithArray:profile.allKeys ?: @[]];
    NSSet *allowed = [NSSet setWithArray:@[@"format", @"version", @"effect", @"intensity", @"speed"]];
    NSNumber *version = profile[@"version"], *intensity = profile[@"intensity"], *speed = profile[@"speed"];
    NSInteger index = [profile[@"effect"] isKindOfClass:NSString.class] ? (NSInteger)[SGRLyricsShaderNames() indexOfObject:profile[@"effect"]] : -1;
    BOOL numbers = [version isKindOfClass:NSNumber.class] && [intensity isKindOfClass:NSNumber.class] && [speed isKindOfClass:NSNumber.class];
    if (numbers) numbers = CFGetTypeID((__bridge CFTypeRef)version) != CFBooleanGetTypeID()
        && CFGetTypeID((__bridge CFTypeRef)intensity) != CFBooleanGetTypeID() && CFGetTypeID((__bridge CFTypeRef)speed) != CFBooleanGetTypeID();
    BOOL valid = [keys isEqual:allowed] && [profile[@"format"] isEqual:@"spoti.pw.lyrics-effect"] && numbers
        && version.doubleValue == 1 && index >= 0 && index < (NSInteger)SGRLyricsShaderNames().count
        && isfinite(intensity.doubleValue) && intensity.doubleValue >= 0 && intensity.doubleValue <= 1
        && isfinite(speed.doubleValue) && speed.doubleValue >= 0.35 && speed.doubleValue <= 2;
    if (!valid) {
        if (error) *error = [NSError errorWithDomain:@"spoti.pw.lyrics-effect" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Choose a spoti.pw lyrics-effect JSON profile with an included effect, intensity from 0 to 1 and speed from 0.35 to 2. Your current style was kept."}];
        return NO;
    }
    [NSUserDefaults.standardUserDefaults setInteger:index forKey:SGRKeyLyricsShader];
    [NSUserDefaults.standardUserDefaults setObject:@{@"intensity": intensity, @"speed": speed} forKey:SGRKeyLyricsShaderOptions];
    [NSNotificationCenter.defaultCenter postNotificationName:SGRLyricsLookDidChangeNotification object:changer];
    return YES;
}

static UIColor *shade(const CGFloat rgb[3]) {
    return [UIColor colorWithRed:rgb[0] green:rgb[1] blue:rgb[2] alpha:1];
}

void SGRLyricsShaderColors(UIColor * __strong *lit, UIColor * __strong *dim, UIColor * __strong *glow, CGFloat *glowScale) {
    SGRLyricsShaderStyle style = shaders[SGRLyricsShaderIndex()];
    if (lit) *lit = shade(style.lit);
    if (dim) *dim = shade(style.dim);
    if (glow) *glow = shade(style.glow);
    if (glowScale) *glowScale = style.scale;
}

#pragma mark - the font

NSArray<NSString *> *SGRLyricsFontChoices(void) {
    NSMutableArray<NSString *> *choices = [@[@"System", @"Rounded", @"Serif", @"Mono"] mutableCopy];
    NSString *imported = [NSUserDefaults.standardUserDefaults stringForKey:SGKeyAppFontName];
    if (imported.length && SGRegisterCustomFont()) [choices addObject:imported];
    for (NSString *family in SGAppFontFamilies()) if (![choices containsObject:family]) [choices addObject:family];
    return choices;
}

NSString *SGRLyricsFontChoice(void) {
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:SGRKeyLyricsFont];
    return saved.length && [SGRLyricsFontChoices() containsObject:saved] ? saved : @"System";
}

void SGRSetLyricsFontChoice(NSString *choice, id changer) {
    [NSUserDefaults.standardUserDefaults setObject:choice forKey:SGRKeyLyricsFont];
    [NSNotificationCenter.defaultCenter postNotificationName:SGRLyricsLookDidChangeNotification object:changer];
}

UIFont *SGRLyricsFont(CGFloat size, UIFontWeight weight) {
    NSString *choice = SGRLyricsFontChoice();
    UIFontDescriptorSystemDesign design = nil;
    if ([choice isEqualToString:@"Rounded"]) design = UIFontDescriptorSystemDesignRounded;
    else if ([choice isEqualToString:@"Serif"]) design = UIFontDescriptorSystemDesignSerif;
    else if ([choice isEqualToString:@"Mono"]) design = UIFontDescriptorSystemDesignMonospaced;
    UIFont *system = [UIFont systemFontOfSize:size weight:weight];
    if (design) {
        UIFontDescriptor *descriptor = [system.fontDescriptor fontDescriptorWithDesign:design];
        return descriptor ? [UIFont fontWithDescriptor:descriptor size:size] : system;
    }
    if ([choice isEqualToString:@"System"]) return system;
    // A family: its upright face nearest the weight; the system's font where the family has none.
    UIFontDescriptor *descriptor = [UIFontDescriptor fontDescriptorWithFontAttributes:@{
        UIFontDescriptorFamilyAttribute: choice,
        UIFontDescriptorTraitsAttribute: @{UIFontWeightTrait: @(weight), UIFontSlantTrait: @0},
    }];
    UIFont *font = [UIFont fontWithDescriptor:descriptor size:size];
    return font ?: system;
}

#pragma mark - the preview's song

// Each word as [text, start, end] in ms; a line runs from its first word's start to its last word's end.
static SGKaraokeLine *sampleLine(NSArray<NSArray *> *timed) {
    NSMutableArray<SGKaraokeWord *> *words = [NSMutableArray array];
    for (NSArray *piece in timed) {
        SGKaraokeWord *word = [SGKaraokeWord new];
        word.text = piece[0];
        word.start = [piece[1] integerValue];
        word.end = [piece[2] integerValue];
        [words addObject:word];
    }
    SGKaraokeLine *line = [SGKaraokeLine new];
    line.words = words;
    line.start = words.firstObject.start;
    line.end = words.lastObject.end;
    line.timing = SGKaraokeTimingWords;
    return line;
}

// Words of the mod's own. The second line holds its last word for three seconds, so the glow and the wave
// show on every round.
NSArray<SGKaraokeLine *> *SGRLyricsSampleLines(void) {
    static NSArray<SGKaraokeLine *> *lines;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lines = @[
            sampleLine(@[@[@"Light", @600, @1000], @[@"comes", @1000, @1400], @[@"over", @1400, @1800], @[@"the", @1800, @2000], @[@"water", @2000, @2900]]),
            sampleLine(@[@[@"hold", @3100, @3500], @[@"on", @3500, @3800], @[@"to", @3800, @4000], @[@"the", @4000, @4200], @[@"night", @4200, @7200]]),
            sampleLine(@[@[@"we", @7500, @7800], @[@"sing", @7800, @8300], @[@"it", @8300, @8500], @[@"louder", @8500, @9500]]),
            sampleLine(@[@[@"all", @9800, @10100], @[@"the", @10100, @10300], @[@"way", @10300, @10700], @[@"home", @10700, @12000]]),
        ];
    });
    return lines;
}

NSInteger SGRLyricsSampleLength(void) {
    return 13500;   // a pause after the last line, then the first again
}
