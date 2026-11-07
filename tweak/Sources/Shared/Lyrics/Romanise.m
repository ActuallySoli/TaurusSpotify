// A line in the Latin alphabet, offline, by Apple's own transforms (ICU's under them). Japanese goes
// through the tokenizer's Latin transcription, which reads kanji the Japanese way: Any-Latin alone
// reads them as Mandarin (君の名前 as "jūnno míng qián" instead of "kimi no namae"). Pinyin keeps its
// tone marks; every other script is brought down to plain ASCII, which reads better sung along to
// than ICU's scholarly marks (Greek "Kalēméra", Thai "s̄wạs̄dī").
//
// ponytail: ICU transliterates rather than reads aloud: Arabic and Hebrew come out as their consonants
// ("mrhba"), Thai in ISO 11940's spelling rather than the one signs use, and a line mixing Latin with
// another script loses the Latin part's accents ("Café" as "Cafe"). A reading per language is the upgrade.
#import "Core/SGCore.h"
#import "Lyrics.h"

NSNotificationName const SGLyricsRomanisedDidChangeNotification = @"spotifyglass.lyricsRomanisedDidChange";
NSNotificationName const SGLyricsFuriganaDidChangeNotification = @"spotifyglass.redesign.lyricsFuriganaDidChange";

@implementation SGLyricsFuriganaSpan
@end

static BOOL has(NSString *text, NSString *pattern) {
    return [text rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}

static BOOL hasKana(NSString *text) {
    return has(text, @"[\\p{Hiragana}\\p{Katakana}]");
}

BOOL SGLyricsLooksJapanese(NSArray<SGKaraokeLine *> *lines) {
    for (SGKaraokeLine *line in lines) {
        if (hasKana(SGKaraokeLineText(line))) return YES;
    }
    return NO;
}

// The tokenizer's reading of each word, a space between words; what it has no reading for (punctuation,
// another script) is kept for the transform after it.
static NSString *readJapanese(NSString *text) {
    NSMutableString *read = [NSMutableString string];
    CFLocaleRef japanese = CFLocaleCreate(NULL, CFSTR("ja"));
    CFStringTokenizerRef words = CFStringTokenizerCreate(NULL, (__bridge CFStringRef)text, CFRangeMake(0, text.length),
                                                         kCFStringTokenizerUnitWord, japanese);
    NSUInteger from = 0;
    while (CFStringTokenizerAdvanceToNextToken(words) != kCFStringTokenizerTokenNone) {
        CFRange range = CFStringTokenizerGetCurrentTokenRange(words);
        NSString *between = [text substringWithRange:NSMakeRange(from, range.location - from)];
        NSString *word = CFBridgingRelease(CFStringTokenizerCopyCurrentTokenAttribute(words, kCFStringTokenizerAttributeLatinTranscription));
        if (read.length && !between.length) [read appendString:@" "];
        [read appendString:between];
        [read appendString:word ?: [text substringWithRange:NSMakeRange(range.location, range.length)]];
        from = range.location + range.length;
    }
    [read appendString:[text substringFromIndex:from]];
    CFRelease(words);
    CFRelease(japanese);
    return read;
}

NSString *SGLyricsRomanised(NSString *text, BOOL japanese) {
    NSInteger script = SGInt(SGKeyLyricsPronunciationScript, 0);
    if (script == 1) {
        if (!text.length || has(text, @"\\p{Hangul}")) return nil;
    } else {
        // Only a line with a letter of another script: Latin with accents (German, Vietnamese) is left alone.
        if (!text.length || !has(text, @"[\\p{L}&&[^\\p{Latin}]]")) return nil;
    }
    static NSCache<NSString *, NSString *> *kept;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ kept = [NSCache new]; });
    NSString *key = [NSString stringWithFormat:@"%ld:%d:%@", (long)script, japanese, text];
    NSString *romanised = [kept objectForKey:key];
    if (romanised) return romanised.length ? romanised : nil;
    BOOL kana = japanese || hasKana(text);
    NSString *source = kana ? readJapanese(text) : text;
    // Han left over is Chinese: its pinyin keeps the tones, and only its punctuation is made ASCII.
    NSString *transform = (script == 0 && !kana && has(text, @"\\p{Han}")) ? @"Any-Latin; [[:P:][:Zs:]] Latin-ASCII" : @"Any-Latin; Latin-ASCII";
    romanised = [[source stringByApplyingTransform:transform reverse:NO]
                 stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] ?: @"";
    if (script == 1 && romanised.length) {
        romanised = [[romanised stringByApplyingTransform:@"Latin-Hangul" reverse:NO]
                     stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] ?: @"";
    }
    if ([romanised caseInsensitiveCompare:text] == NSOrderedSame) romanised = @"";
    [kept setObject:romanised forKey:key];
    return romanised.length ? romanised : nil;
}

NSArray<SGLyricsFuriganaSpan *> *SGLyricsFuriganaSpans(NSString *text) {
    if (!text.length || !has(text, @"\\p{Han}")) return @[];
    static NSCache<NSString *, NSArray<SGLyricsFuriganaSpan *> *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    NSArray<SGLyricsFuriganaSpan *> *cached = [cache objectForKey:text];
    if (cached) return cached;

    NSMutableArray<SGLyricsFuriganaSpan *> *spans = [NSMutableArray array];
    CFLocaleRef japanese = CFLocaleCreate(NULL, CFSTR("ja"));
    CFStringTokenizerRef words = CFStringTokenizerCreate(NULL, (__bridge CFStringRef)text, CFRangeMake(0, text.length),
                                                         kCFStringTokenizerUnitWord, japanese);
    while (CFStringTokenizerAdvanceToNextToken(words) != kCFStringTokenizerTokenNone) {
        CFRange cfRange = CFStringTokenizerGetCurrentTokenRange(words);
        if (cfRange.location == kCFNotFound || cfRange.length <= 0) continue;
        NSRange range = NSMakeRange((NSUInteger)cfRange.location, (NSUInteger)cfRange.length);
        NSString *token = [text substringWithRange:range];
        if (!has(token, @"\\p{Han}")) continue;
        NSString *latin = CFBridgingRelease(CFStringTokenizerCopyCurrentTokenAttribute(words, kCFStringTokenizerAttributeLatinTranscription));
        if (!latin.length) continue;
        NSString *kana = [latin stringByApplyingTransform:@"Latin-Hiragana" reverse:NO];
        if (!kana.length || [kana isEqualToString:token]) continue;

        // Trim shared leading and trailing kana (okurigana) so the furigana sits directly over the Kanji root.
        while (range.length > 0 && kana.length > 0) {
            unichar tc = [text characterAtIndex:range.location + range.length - 1];
            unichar kc = [kana characterAtIndex:kana.length - 1];
            if (tc == kc) {
                range.length--;
                kana = [kana substringToIndex:kana.length - 1];
            } else {
                break;
            }
        }
        while (range.length > 0 && kana.length > 0) {
            unichar tc = [text characterAtIndex:range.location];
            unichar kc = [kana characterAtIndex:0];
            if (tc == kc) {
                range.location++;
                range.length--;
                kana = [kana substringFromIndex:1];
            } else {
                break;
            }
        }
        if (range.length > 0 && kana.length > 0) {
            SGLyricsFuriganaSpan *span = [SGLyricsFuriganaSpan new];
            span.range = range;
            span.reading = kana;
            [spans addObject:span];
        }
    }
    CFRelease(words);
    CFRelease(japanese);
    NSArray<SGLyricsFuriganaSpan *> *result = [spans copy];
    [cache setObject:result forKey:text];
    return result;
}
