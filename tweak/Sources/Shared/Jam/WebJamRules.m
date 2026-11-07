#import "WebJamRules.h"

static BOOL isTrackID(NSString *text) {
    if (text.length != 22) return NO;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if ((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) continue;
        return NO;
    }
    return YES;
}

NSString *SGWebJamRequestURI(NSString *input) {
    if (![input isKindOfClass:NSString.class]) return nil;
    NSString *text = [input stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (isTrackID(text)) return [@"spotify:track:" stringByAppendingString:text];
    for (NSString *kind in @[@"track", @"playlist"]) {
        NSString *prefix = [NSString stringWithFormat:@"spotify:%@:", kind];
        if ([text hasPrefix:prefix]) return isTrackID([text substringFromIndex:prefix.length]) ? text : nil;
    }
    NSURLComponents *parts = [NSURLComponents componentsWithString:text];
    if (!parts) return nil;
    if (![parts.scheme.lowercaseString isEqualToString:@"https"] ||
        ![parts.host.lowercaseString isEqualToString:@"open.spotify.com"] ||
        parts.port || parts.user || parts.password) return nil;
    NSMutableArray<NSString *> *path = [[parts.percentEncodedPath componentsSeparatedByString:@"/"] mutableCopy];
    if (path.count == 4 && [path[1] hasPrefix:@"intl-"]) {
        NSString *language = [path[1] substringFromIndex:5];
        if (language.length != 2 || [language rangeOfCharacterFromSet:
            [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz"].invertedSet].location != NSNotFound) return nil;
        [path removeObjectAtIndex:1];
    }
    if (path.count != 3 || ![path[0] isEqualToString:@""] || (![path[1] isEqualToString:@"track"] && ![path[1] isEqualToString:@"playlist"])) return nil;
    NSString *trackID = path[2];
    return isTrackID(trackID) ? [NSString stringWithFormat:@"spotify:%@:%@", path[1], trackID] : nil;
}

NSString *SGWebJamTrackID(NSString *input) {
    NSString *uri = SGWebJamRequestURI(input);
    return [uri hasPrefix:@"spotify:track:"] ? [uri substringFromIndex:14] : nil;
}

NSString *SGWebJamDisplayName(id value) {
    if (![value isKindOfClass:NSString.class]) return @"Guest";
    NSString *text = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    text = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@""];
    if (!text.length) return @"Guest";
    return text.length > 32 ? [text substringWithRange:[text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 32)]] : text;
}

NSString *SGWebJamCoverURL(NSDictionary *metadata) {
    if (![metadata isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *key in @[@"image_xlarge_url", @"image_large_url", @"image_url"]) {
        id raw = metadata[key];
        if (![raw isKindOfClass:NSString.class] || [raw length] > 256) continue;
        NSString *text = raw;
        if ([text hasPrefix:@"spotify:image:"])
            text = [@"https://i.scdn.co/image/" stringByAppendingString:[text substringFromIndex:14]];
        NSString *prefix = @"https://i.scdn.co/image/";
        if (![text hasPrefix:prefix]) continue;
        NSString *identifier = [text substringFromIndex:prefix.length];
        if (identifier.length >= 32 && identifier.length <= 128 &&
            [identifier rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:
                @"0123456789abcdefABCDEF"].invertedSet].location == NSNotFound) return text;
    }
    return nil;
}

NSString *SGWebJamURIForTrackID(NSString *trackID) {
    return isTrackID(trackID) ? [@"spotify:track:" stringByAppendingString:trackID] : nil;
}

NSString *SGWebJamJSONString(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return @"\"\"";
    NSMutableString *out = [NSMutableString stringWithString:@"\""];
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        switch (c) {
            case '"': [out appendString:@"\\\""]; break;
            case '\\': [out appendString:@"\\\\"]; break;
            case '\b': [out appendString:@"\\b"]; break;
            case '\f': [out appendString:@"\\f"]; break;
            case '\n': [out appendString:@"\\n"]; break;
            case '\r': [out appendString:@"\\r"]; break;
            case '\t': [out appendString:@"\\t"]; break;
            default:
                if (c < 0x20) [out appendFormat:@"\\u%04x", c];
                else [out appendFormat:@"%C", c];
        }
    }
    [out appendString:@"\""];
    return out;
}

NSString *SGWebJamHTMLEscape(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSMutableString *out = [NSMutableString stringWithCapacity:value.length];
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        switch (c) {
            case '&': [out appendString:@"&amp;"]; break;
            case '<': [out appendString:@"&lt;"]; break;
            case '>': [out appendString:@"&gt;"]; break;
            case '"': [out appendString:@"&quot;"]; break;
            case '\'': [out appendString:@"&#39;"]; break;
            default: [out appendFormat:@"%C", c];
        }
    }
    return out;
}
