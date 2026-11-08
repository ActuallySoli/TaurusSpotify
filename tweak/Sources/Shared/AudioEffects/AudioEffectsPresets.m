// The presets: built-in ones over a reset, and the user's own as a copy of every dsp key. Everything goes back
// in through AudioEffects.h's setters, so it is clamped and applied the way the page's own changes are.
#import "AudioEffects.h"
#import "AudioEffectsApply.h"
#import "AudioEffectsPresets.h"
#include <math.h>

static NSString *const kPrefix = @"spotifyglass.dsp.";

static NSUserDefaults *store(void) {
    return NSUserDefaults.standardUserDefaults;
}

// A value back through its setter: a switch (the key naming its own effect), a number, the gains as a
// list, or text. Anything else is left out, a preset from a later build naming a key this one lacks too.
static void setValue(NSString *key, id value) {
    if (![key hasPrefix:kPrefix]) return;
    if ([value isKindOfClass:NSArray.class]) SGDSPSetGains(key, value);
    else if ([value isKindOfClass:NSString.class]) SGDSPSetString(key, value);
    else if (![value isKindOfClass:NSNumber.class]) return;
    else if ([SGDSPEffectOf(key) isEqualToString:key]) SGDSPSetSwitch(key, [value boolValue]);
    else SGDSPSetNumber(key, [value doubleValue]);
}

// A pick is meant to be heard: the master switch, off until asked for, comes on with it.
static void turnOn(void) {
    if (!SGDSPSwitch(SGKeyDSP)) SGDSPSetSwitch(SGKeyDSP, YES);
}

static NSDictionary<NSString *, id> *currentValues(void) {
    NSDictionary<NSString *, id> *all = store().dictionaryRepresentation;
    NSMutableDictionary<NSString *, id> *values = [NSMutableDictionary dictionary];
    for (NSString *key in all) {
        if ([key hasPrefix:kPrefix]) values[key] = all[key];
    }
    return values;
}

#pragma mark - built in

typedef struct {
    NSString *__unsafe_unretained name, *__unsafe_unretained detail;
} SGDSPPresetName;

static const SGDSPPresetName kBuiltIn[] = {
    {@"Bass boost", @"Bass boost at 8 dB"},
    {@"Vocal clarity", @"Equalizer on voices, a light compander"},
    {@"Late night", @"Quiet and loud evened out, less bass"},
    {@"Concert hall", @"A large hall's reverb, a wider stage"},
    {@"Warm analog", @"Tube warmth, a warm equalizer"},
    {@"Headphone comfort", @"Crossfeed, a softer top"},
    {@"Wide stereo", @"Stereo widening"},
};

static NSArray<NSNumber *> *equalizer(NSString *preset) {
    return SGDSPEqualizerPreset((NSInteger)[SGDSPEqualizerPresetNames() indexOfObject:preset]);
}

static NSDictionary<NSString *, id> *builtInValues(NSInteger index) {
    switch (index) {
        case 0: return @{SGKeyDSPBass: @YES, SGKeyDSPBassGain: @8};
        case 1: return @{SGKeyDSPEqualizer: @YES, SGKeyDSPEqualizerGains: equalizer(@"Vocal"),
                         SGKeyDSPCompander: @YES, SGKeyDSPCompanderGains: @[@0, @0.2, @0.3, @0.3, @0.3, @0.2, @0]};
        // The compander over 0 lifts the quiet parts and holds the loud ones; the gain brings the level back.
        case 2: return @{SGKeyDSPCompander: @YES, SGKeyDSPCompanderGains: @[@0.6, @0.7, @0.8, @0.8, @0.8, @0.7, @0.6],
                         SGKeyDSPCompanderTime: @0.3, SGKeyDSPEqualizer: @YES,
                         SGKeyDSPEqualizerGains: @[@-6, @-5, @-4, @-2, @-1, @0, @0, @0, @0, @0, @0, @0, @-1, @-2, @-2],
                         SGKeyDSPPostGain: @3, SGKeyDSPLimiterThreshold: @-3};
        case 3: return @{SGKeyDSPReverb: @YES, SGKeyDSPReverbPreset: @7, SGKeyDSPReverbAmount: @40,
                         SGKeyDSPStereoWide: @YES, SGKeyDSPStereoWideLevel: @65};
        case 4: return @{SGKeyDSPTube: @YES, SGKeyDSPTubeDrive: @6, SGKeyDSPEqualizer: @YES, SGKeyDSPEqualizerGains: equalizer(@"Warm")};
        case 5: return @{SGKeyDSPCrossfeed: @YES, SGKeyDSPCrossfeedMode: @2, SGKeyDSPEqualizer: @YES,
                         SGKeyDSPEqualizerGains: @[@0, @0, @0, @0, @0, @0, @0, @0, @0, @0, @-1, @-2, @-2, @-3, @-3]};
        case 6: return @{SGKeyDSPStereoWide: @YES, SGKeyDSPStereoWideLevel: @75};
    }
    return nil;
}

NSArray<NSString *> *SGDSPBuiltInPresetNames(void) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (size_t i = 0; i < sizeof kBuiltIn / sizeof *kBuiltIn; i++) [names addObject:kBuiltIn[i].name];
    return names;
}

NSString *SGDSPBuiltInPresetDetail(NSInteger index) {
    return index >= 0 && index < (NSInteger)(sizeof kBuiltIn / sizeof *kBuiltIn) ? kBuiltIn[index].detail : nil;
}

void SGDSPLoadBuiltInPreset(NSInteger index) {
    NSDictionary<NSString *, id> *values = builtInValues(index);
    if (!values) return;
    NSMutableDictionary<NSString *, id> *kept = [NSMutableDictionary dictionary];
    NSDictionary<NSString *, id> *now = currentValues();
    for (NSString *key in now) {
        if ([SGDSPEffectOf(key) isEqualToString:SGKeyDSPGraphicEq]) kept[key] = now[key];
    }
    SGDSPResetAll();
    for (NSString *key in kept) setValue(key, kept[key]);
    for (NSString *key in values) setValue(key, values[key]);
    turnOn();
}

#pragma mark - the user's

static NSDictionary<NSString *, NSDictionary *> *userPresets(void) {
    id presets = [store() objectForKey:SGKeyDSPUserPresets];
    return [presets isKindOfClass:NSDictionary.class] ? presets : @{};
}

NSArray<NSString *> *SGDSPUserPresetNames(void) {
    return [userPresets().allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

void SGDSPSaveUserPreset(NSString *name) {
    if (!name.length) return;
    NSMutableDictionary *presets = [userPresets() mutableCopy];
    presets[name] = currentValues();
    [store() setObject:presets forKey:SGKeyDSPUserPresets];
}

BOOL SGDSPLoadUserPreset(NSString *name) {
    NSDictionary *values = userPresets()[name];
    if (![values isKindOfClass:NSDictionary.class]) return NO;
    SGDSPResetAll();
    for (NSString *key in values) setValue(key, values[key]);
    turnOn();
    return YES;
}

void SGDSPDeleteUserPreset(NSString *name) {
    NSMutableDictionary *presets = [userPresets() mutableCopy];
    [presets removeObjectForKey:name];
    [store() setObject:presets forKey:SGKeyDSPUserPresets];
}

NSString *SGDSPPresetUniqueName(NSString *name) {
    if (!name.length) return name;
    NSString *unique = name;
    for (int i = 2; i < 100; i++) {
        if (![userPresets()[unique] isKindOfClass:NSDictionary.class]) return unique;
        unique = [name stringByAppendingFormat:@" (%d)", i];
    }
    return [name stringByAppendingFormat:@" (%tu)", (unsigned long)[NSDate date].timeIntervalSince1970];
}

#pragma mark - sharing

// What each known dsp key may take: a switch or a number as an NSNumber, the gains or the Graphic EQ's own
// line as text of numbers, a library file's plain name, and the Graphic EQ both ways, its on switch as a
// number and what it plays under as text. A key that is none of these is another build's and is dropped.
typedef NS_ENUM(NSInteger, SGDSPPresetValueKind) {
    SGDSPPresetValueSwitch = 1,
    SGDSPPresetValueNumber,
    SGDSPPresetValueGain,        // SGKeyDSPCompanderGains, SGKeyDSPEqualizerGains
    SGDSPPresetValueNodes,       // SGKeyDSPGraphicEqNodes: the correction itself
    SGDSPPresetValueFile,        // SGKeyDSPConvolverFile, SGKeyDSPDDCFile, SGKeyDSPLiveprogFile
    SGDSPPresetValueBoth,        // SGKeyDSPGraphicEq: its switch, and which correction it plays
};

static SGDSPPresetValueKind keyKind(NSString *key) {
    static NSDictionary<NSString *, NSNumber *> *kinds;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary<NSString *, NSNumber *> *all = [NSMutableDictionary dictionary];
        for (NSString *k in @[SGKeyDSPCompander, SGKeyDSPBass, SGKeyDSPEqualizer, SGKeyDSPConvolver,
                              SGKeyDSPDDC, SGKeyDSPLiveprog, SGKeyDSPReverb, SGKeyDSPStereoWide,
                              SGKeyDSPCrossfeed, SGKeyDSPTube])
            all[k] = @(SGDSPPresetValueSwitch);
        for (NSString *k in @[SGKeyDSPPostGain, SGKeyDSPLimiterThreshold, SGKeyDSPLimiterRelease,
                              SGKeyDSPCompanderTime, SGKeyDSPBassGain, SGKeyDSPConvolverMode,
                              SGKeyDSPReverbPreset, SGKeyDSPReverbAmount, SGKeyDSPStereoWideLevel,
                              SGKeyDSPCrossfeedMode, SGKeyDSPTubeDrive])
            all[k] = @(SGDSPPresetValueNumber);
        for (NSString *k in @[SGKeyDSPCompanderGains, SGKeyDSPEqualizerGains]) all[k] = @(SGDSPPresetValueGain);
        all[SGKeyDSPGraphicEqNodes] = @(SGDSPPresetValueNodes);
        for (NSString *k in @[SGKeyDSPConvolverFile, SGKeyDSPDDCFile, SGKeyDSPLiveprogFile]) all[k] = @(SGDSPPresetValueFile);
        all[SGKeyDSPGraphicEq] = @(SGDSPPresetValueBoth);
        kinds = all;
    });
    return (SGDSPPresetValueKind)[kinds[key] integerValue];   // 0 = not a preset key
}

// The gains as the text SGDSPSetGains leaves them, padded and clamped the same way, so an imported preset's
// gains read back through SGDSPGains as they do through the page's own editing.
static NSString *gainText(NSArray<NSNumber *> *gains, NSUInteger count, double limit) {
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        double gain = i < gains.count ? gains[i].doubleValue : 0;
        [parts addObject:[NSString stringWithFormat:@"%.2f", MAX(-limit, MIN(limit, gain))]];
    }
    return [parts componentsJoinedByString:@";"];
}

// The gains' count and limit for their key: the compander's seven within its own limit, the equalizer's
// fifteen within its wider one — SGDSPGains reads them by the key.
static void gainSizing(NSString *key, NSUInteger *count, double *limit) {
    BOOL compander = [key isEqualToString:SGKeyDSPCompanderGains];
    *count = compander ? 7 : 15;
    *limit = compander ? SGDSPCompanderGainLimit : SGDSPEqualizerGainLimit;
}

// The value for a known key, or nil when it is the wrong kind or out of bounds for that key. A wrong kind for
// a known key turns the whole file away, not a silent drop: a follower deserves to know a shared preset does
// not check. Unknown keys never get here.
static id checkedValue(NSString *key, id value, SGDSPPresetValueKind kind) {
    BOOL number = value && [value isKindOfClass:NSNumber.class];
    if (number && !isfinite([value doubleValue])) return nil;
    switch (kind) {
        case SGDSPPresetValueSwitch:
            return number ? @([value boolValue]) : nil;
        case SGDSPPresetValueNumber: {
            if (!number) return nil;
            SGDSPRange range = SGDSPRangeFor(key);
            return @(MAX(range.min, MIN(range.max, [value doubleValue])));
        }
        case SGDSPPresetValueGain: {
            NSString *text = [value isKindOfClass:NSString.class] ? value : nil;
            if ([value isKindOfClass:NSArray.class]) {
                // A list of numbers, bounded before anything reads it.
                NSArray *list = value;
                if (list.count > 64) return nil;
                for (id gain in list) if (![gain isKindOfClass:NSNumber.class] || !isfinite([gain doubleValue])) return nil;
                text = [list componentsJoinedByString:@";"];
            }
            if (!text || text.length > 4096) return nil;
            NSArray<NSString *> *parts = [text componentsSeparatedByString:@";"];
            if (parts.count > 64) return nil;
            NSMutableArray<NSNumber *> *gains = [NSMutableArray array];
            for (NSString *part in parts) {
                NSScanner *read = [NSScanner scannerWithString:part];
                double gain;
                if (![read scanDouble:&gain] || !read.isAtEnd || !isfinite(gain)) return nil;
                [gains addObject:@(gain)];
            }
            NSUInteger count; double limit;
            gainSizing(key, &count, &limit);
            return gainText(gains, count, limit);
        }
        case SGDSPPresetValueNodes:
            // The same line the editors save, or nothing.
            return [value isKindOfClass:NSString.class] ? SGDSPGraphicEqLine(value) : nil;
        case SGDSPPresetValueFile: {
            // AudioEffectsFiles' own check for a library file's name: nothing that leaves its folder.
            if (![value isKindOfClass:NSString.class]) return nil;
            NSString *name = value;
            if (!name.length || name.length > 128 || ![name.lastPathComponent isEqualToString:name]
                || [name hasPrefix:@"."]) return nil;
            return name;
        }
        case SGDSPPresetValueBoth: {
            // SGKeyDSPGraphicEq: its switch as a number, and which correction it plays under as text, empty
            // allowed (None does).
            if (number) return @([value boolValue]);
            if (![value isKindOfClass:NSString.class]) return nil;
            NSString *text = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            return text.length <= 512 ? text : nil;
        }
        default:
            return nil;
    }
}

// The name behind the file, trimmed and bounded, or nil when there is none and the file is turned away.
static NSString *checkedName(id raw) {
    if (![raw isKindOfClass:NSString.class]) return nil;
    NSString *name = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return name.length && name.length <= 64 ? name : nil;
}

BOOL SGDSPPresetFromFile(id file, NSString **name, NSDictionary<NSString *, id> **values, NSString **why) {
    // A file of one preset stays small; anything past its handful of keys and bounded texts did not come
    // from Export anyway.
    if (![file isKindOfClass:NSDictionary.class]) { if (why) *why = @"Not a shared preset file."; return NO; }
    if (![file[@"type"] isKindOfClass:NSString.class]
        || ![file[@"type"] isEqualToString:SGDSPPresetShareType]) {
        if (why) *why = @"Not a shared preset file. Pick one made by Export.";
        return NO;
    }
    if (![file[@"version"] isKindOfClass:NSNumber.class]
        || ![file[@"version"] isEqualToNumber:@(SGDSPPresetShareVersion)]) {
        if (why) *why = [NSString stringWithFormat:@"A version %@ preset needs a newer or older copy of the mod.",
                         [file[@"version"] isKindOfClass:NSString.class] ? file[@"version"] : @"this file does not say"];
        return NO;
    }
    NSString *presetName = checkedName(file[@"name"]);
    if (!presetName) { if (why) *why = @"The file does not name its preset."; return NO; }
    NSDictionary *saved = file[@"values"];
    if (![saved isKindOfClass:NSDictionary.class] || saved.count < 1 || saved.count > 64) {
        if (why) *why = @"The file's preset holds nothing this copy can set, or far too much.";
        return NO;
    }
    NSMutableDictionary<NSString *, id> *checked = [NSMutableDictionary dictionary];
    for (NSString *key in saved) {
        SGDSPPresetValueKind kind = keyKind(key);
        if (!kind) continue;                                   // another build's key, left out
        if (![key hasPrefix:kPrefix]) continue;
        id value = checkedValue(key, saved[key], kind);
        if (!value) { if (why) *why = @"One of the preset's settings is not the kind this copy can set."; return NO; }
        checked[key] = value;
    }
    if (!checked.count) { if (why) *why = @"The file's preset holds nothing this copy can set."; return NO; }
    if (name) *name = presetName;
    if (values) *values = checked;
    return YES;
}

NSDictionary<NSString *, id> *SGDSPPresetShareFile(NSString *name) {
    NSDictionary *values = userPresets()[name];
    if (![values isKindOfClass:NSDictionary.class]) return nil;
    // Only keys this build accepts back: a follower's preset keeps every effect this one can set, and
    // whatever else the preset picked up along the way stays here.
    NSMutableDictionary *shared = [NSMutableDictionary dictionary];
    for (NSString *key in values) {
        SGDSPPresetValueKind kind = keyKind(key);
        if (kind) {
            id value = checkedValue(key, values[key], kind);
            if (value) shared[key] = value;
        }
    }
    return shared.count ? @{
        @"type": SGDSPPresetShareType,
        @"version": @(SGDSPPresetShareVersion),
        @"name": name,
        @"values": shared,
    } : nil;
}

void SGDSPSavePresetValues(NSString *name, NSDictionary<NSString *, id> *values) {
    if (!name.length || ![values isKindOfClass:NSDictionary.class]) return;
    NSMutableDictionary *presets = [userPresets() mutableCopy];
    presets[[name copy]] = [values copy];
    [store() setObject:presets forKey:SGKeyDSPUserPresets];
}


#pragma mark - GraphicEQ text

// One line: AutoEq's files end in a newline, and a copy out of a web page often has more.
NSString *SGDSPGraphicEqLine(NSString *text) {
    NSArray<NSString *> *words = [text ?: @"" componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    words = [words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    NSString *line = [words componentsJoinedByString:@" "];
    return [line.lowercaseString hasPrefix:@"graphiceq:"] ? line : nil;
}
