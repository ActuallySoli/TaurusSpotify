#import "AutoMix.h"
#import "Core/SGPrefs.h"
#import "Shared/AdBlock/Protobuf.h"
#include <math.h>

NSNotificationName const SGAutoMixStatusDidChangeNotification = @"spotifyglass.automix.statusChanged";

BOOL SGAutoMixSupportedVersion(NSString *version) {
    return [version isEqualToString:@"9.1.90"] || [version isEqualToString:@"9.1.94"];
}

BOOL SGAutoMixEnabled(void) {
    return SGFlag(SGKeyAutoMix, NO);
}

BOOL SGAutoMixUsesBeatMatching(void) {
    return SGInt(SGKeyAutoMixStyle, 0) == 0;
}

NSInteger SGAutoMixBlendSeconds(void) {
    return MAX(1, MIN(12, SGInt(SGKeyAutoMixLength, 5)));
}

BOOL SGAutoMixContextAllowed(NSString *uri) {
    if (![uri isKindOfClass:NSString.class]) return NO;
    if ([uri hasPrefix:@"context://"]) uri = [uri substringFromIndex:10];
    NSArray<NSString *> *parts = [uri componentsSeparatedByString:@":"];
    if (parts.count < 3 || ![parts[0] isEqualToString:@"spotify"]) return NO;
    NSString *kind = parts[1];
    if ([kind isEqualToString:@"collection"] || [kind isEqualToString:@"user"]) {
        if ([parts.lastObject isEqualToString:@"tracks"])
            return SGFlag(SGKeyAutoMixLikedSongs, YES);
        if ([parts containsObject:@"playlist"]) return SGFlag(SGKeyAutoMixPlaylists, YES);
        return NO;
    }
    if ([kind isEqualToString:@"playlist"]) return SGFlag(SGKeyAutoMixPlaylists, YES);
    if ([kind isEqualToString:@"album"]) return SGFlag(SGKeyAutoMixAlbums, YES);
    if ([kind isEqualToString:@"station"] || [kind isEqualToString:@"radio"] || [kind isEqualToString:@"artist"])
        return SGFlag(SGKeyAutoMixRadio, YES);
    return NO;
}

BOOL SGAutoMixTrackAllowed(NSString *uri, NSString *provider) {
    if (![uri isKindOfClass:NSString.class] || ![uri hasPrefix:@"spotify:track:"]) return NO;
    if ([provider isEqualToString:@"queue"] && !SGFlag(SGKeyAutoMixQueue, YES)) return NO;
    if (([provider isEqualToString:@"autoplay"] || [provider isEqualToString:@"autoplay-resolver"])
        && !SGFlag(SGKeyAutoMixAutoplay, YES)) return NO;
    return YES;
}

BOOL SGAutoMixHasTransition(NSDictionary *metadata) {
    if (![metadata isKindOfClass:NSDictionary.class]) return NO;
    id uri = metadata[@"automix.transition_uri"];
    if ([uri isKindOfClass:NSString.class] && [uri length]) return YES;
    for (NSString *key in @[@"audio.fade_out_start_time", @"audio.fade_out_duration", @"audio.fade_overlap", @"media.stop_position"]) {
        id value = metadata[key];
        double number = 0;
        if ([value isKindOfClass:NSNumber.class]) number = [value doubleValue];
        else if ([value isKindOfClass:NSString.class]) {
            NSScanner *scanner = [NSScanner scannerWithString:value];
            if (![scanner scanDouble:&number] || !scanner.isAtEnd) continue;
        } else continue;
        BOOL allowZero = [key isEqualToString:@"audio.fade_out_start_time"];
        if (isfinite(number) && (allowZero ? number >= 0 : number > 0)) return YES;
    }
    return NO;
}

NSDictionary *SGAutoMixContextMetadata(NSString *uri, NSDictionary *metadata) {
    if (!SGAutoMixEnabled() || !SGAutoMixUsesBeatMatching() || !SGAutoMixContextAllowed(uri)) return nil;
    if (metadata && ![metadata isKindOfClass:NSDictionary.class]) return nil;
    if (metadata[@"automix.mode"] != nil) return nil;
    NSMutableDictionary *patched = metadata ? [metadata mutableCopy] : [NSMutableDictionary dictionary];
    patched[@"automix.mode"] = @"regular";
    patched[@"automix.ignore_setting"] = @"true";
    patched[@"automix.queue"] = SGFlag(SGKeyAutoMixQueue, YES) ? @"true" : @"false";
    patched[@"automix.autoplay"] = SGFlag(SGKeyAutoMixAutoplay, YES) ? @"true" : @"false";
    return patched;
}

NSData *SGAutoMixConfiguration(NSData *configuration) {
    if (!SGAutoMixEnabled() || ![configuration isKindOfClass:NSData.class]) return configuration;
    NSMutableArray<SGPBField *> *fields = SGPBParse(configuration);
    if (!fields) return configuration;
    NSDictionary<NSString *, NSString *> *required = @{
        @"core-automix": @"automix_enabled",
        @"core-playback-setup": @"crossfade_enabled",
    };
    NSMutableSet *found = [NSMutableSet set];
    for (SGPBField *field in fields) {
        if (field.number != 3 || field.wire != 2) continue;
        NSMutableArray<SGPBField *> *value = SGPBParse(field.payload);
        NSArray<SGPBField *> *identifier = SGPBParse(SGPBFirst(value, 1).payload);
        NSString *component = SGPBText(SGPBFirst(identifier, 1));
        NSString *property = SGPBText(SGPBFirst(identifier, 2));
        if (!component || !property || ![property isEqualToString:required[component]]) continue;
        [found addObject:component];
        NSIndexSet *oldValue = [value indexesOfObjectsPassingTest:^BOOL(SGPBField *entry, NSUInteger idx, BOOL *stop) {
            return entry.number >= 3 && entry.number <= 5;
        }];
        [value removeObjectsAtIndexes:oldValue];
        [value addObject:SGPBBytes(3, SGPBSerialize(@[SGPBVarint(1, 1)]))];
        field.payload = SGPBSerialize(value);
    }
    for (NSString *component in required) {
        if ([found containsObject:component]) continue;
        NSData *identifier = SGPBSerialize(@[SGPBString(1, component), SGPBString(2, required[component])]);
        [fields addObject:SGPBBytes(3, SGPBSerialize(@[SGPBBytes(1, identifier),
            SGPBBytes(3, SGPBSerialize(@[SGPBVarint(1, 1)]))]))];
    }
    return SGPBSerialize(fields);
}
