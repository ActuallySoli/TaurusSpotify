#import <Foundation/Foundation.h>
#import <math.h>
#import "Core/SGPrefs.h"
#import "SGWebPlayerBridge.h"
#import "WebPlayer.h"

@interface SGWebPlayerFeed : NSObject
@property (atomic, copy) NSData *json;
@end
@implementation SGWebPlayerFeed
@end

static dispatch_source_t sg_feedTimer;
static SGWebPlayerFeed *Feed(void) {
    static SGWebPlayerFeed *feed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ feed = [SGWebPlayerFeed new]; });
    return feed;
}

static NSString *Text(id value, NSUInteger limit) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *text = value;
    if (text.length <= limit) return text;
    NSRange range = [text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, limit)];
    return [text substringWithRange:range];
}

static NSDictionary *TrackJSON(SPTPlayerTrack *track, NSString *identifier) {
    return @{@"id": Text(identifier, 2048), @"title": Text(track.trackTitle, 2048), @"artist": Text(track.artistName, 2048)};
}

static NSDictionary *LineJSON(SGKaraokeLine *line, NSUInteger *budget, NSUInteger *wordBudget) {
    if (!*budget) return nil;
    NSMutableDictionary *json = [@{@"s": @(line.start), @"e": @(line.end), @"timing": @(line.timing),
        @"text": Text(SGKaraokeLineText(line), MIN(*budget, 2048))} mutableCopy];
    *budget -= MIN(*budget, [json[@"text"] length]);
    json[@"voice"] = Text(line.voice, MIN(*budget, 64)); *budget -= MIN(*budget, [json[@"voice"] length]);
    json[@"translation"] = Text(line.translation, MIN(*budget, 2048)); *budget -= MIN(*budget, [json[@"translation"] length]);
    NSMutableArray *words = [NSMutableArray new];
    for (SGKaraokeWord *word in line.words) {
        if (!*budget || !*wordBudget || words.count >= 100) break;
        NSString *text = Text(word.text, MIN(*budget, 128));
        *budget -= MIN(*budget, text.length); --*wordBudget;
        [words addObject:@{@"t": text, @"s": @(word.start), @"e": @(word.end), @"joined": @(word.joined)}];
    }
    json[@"words"] = words;
    return json;
}

static NSDictionary *Snapshot(void) {
    NSCAssert(NSThread.isMainThread, @"Player snapshot belongs to the main thread");
    id<SPTPlayer> player = SGPlaybackPlayer();
    SPTPlayerState *state = player ? player.state : SGPlayerState();
    SPTPlayerTrack *track = state.track;
    NSString *uri = SGURIString(track.URI);
    NSString *trackID = [uri hasPrefix:@"spotify:track:"] ? [uri substringFromIndex:14] : SGKaraokePlayingTrack();
    NSString *identifier = uri ?: trackID;
    BOOL paused = !state || state.isPaused || !state.isPlaying;
    double position = state ? (paused ? state.positionAsOfTimestamp : state.position) : -1;
    double speed = state.playbackSpeed;
    NSMutableDictionary *json = [@{@"ok": @(identifier.length > 0), @"controls": @(SGFlag(SGKeyWebPlayerControls, NO)),
        @"paused": @(paused), @"speed": @(isfinite(speed) && speed > 0 && speed <= 10 ? speed : 1),
        @"positionMs": @(isfinite(position) && position >= 0 && position < 1e9 ? position * 1000 : -1)} mutableCopy];
    SGWebPlayerMediaUpdate(state, uri);
    if (!identifier.length) return json;
    if (isfinite(state.duration) && state.duration > 0 && state.duration < 1e9) json[@"durationMs"] = @(state.duration * 1000);
    json[@"track"] = TrackJSON(track, identifier);
    NSDictionary *metadata = [track respondsToSelector:@selector(metadata)] && [track.metadata isKindOfClass:NSDictionary.class] ? track.metadata : nil;
    NSString *cover = SGWebPlayerCoverURL(metadata);
    if (cover) json[@"cover"] = cover;
    NSDictionary *motion = SGWebPlayerMediaDescription();
    if (motion) json[@"motion"] = motion;
    json[@"lyricsDelayMs"] = @(SGKaraokeDelayMs());
    json[@"looking"] = @(SGKaraokeLooking(trackID));
    NSArray *lines = trackID ? SGKaraokeLinesForTrack(trackID) : nil;
    NSMutableArray *rows = [NSMutableArray new];
    NSUInteger budget = 40000, wordBudget = 2500;
    BOOL truncated = NO;
    for (SGKaraokeLine *line in lines) {
        if (rows.count >= 240 || !budget || !wordBudget) break;
        NSDictionary *row = LineJSON(line, &budget, &wordBudget);
        if (row) {
            [rows addObject:row];
            if ([row[@"words"] count] < line.words.count || [row[@"text"] length] < SGKaraokeLineText(line).length ||
                [row[@"translation"] length] < line.translation.length) truncated = YES;
        }
    }
    json[@"lines"] = rows;
    NSMutableArray *queue = [NSMutableArray new];
    NSArray *future = [state respondsToSelector:@selector(future)] && [state.future isKindOfClass:NSArray.class] ? state.future : nil;
    for (id next in future) {
        if (queue.count >= 10) break;
        if ([next isKindOfClass:NSClassFromString(@"SPTPlayerTrack")]) [queue addObject:TrackJSON(next, SGURIString([next URI]))];
    }
    json[@"queue"] = queue;
    json[@"truncated"] = @(truncated || rows.count < lines.count);
    return json;
}

static void Tick(void) {
    @autoreleasepool {
        NSMutableDictionary *snapshot = [Snapshot() mutableCopy];
        NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:NULL];
        if (data.length > 512 * 1024) {
            snapshot[@"lines"] = @[]; snapshot[@"truncated"] = @YES;
            data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:NULL];
        }
        Feed().json = data;
    }
}

void SGWebPlayerFeedStart(void) {
    NSCAssert(NSThread.isMainThread, @"Browser Player timer belongs to the main thread");
    if (sg_feedTimer) return;
    SGWebPlayerMediaStart();
    Tick();
    sg_feedTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(sg_feedTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), NSEC_PER_SEC / 2, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(sg_feedTimer, ^{ if (sg_feedTimer) Tick(); });
    dispatch_resume(sg_feedTimer);
}
void SGWebPlayerFeedStop(void) {
    if (sg_feedTimer) { dispatch_source_cancel(sg_feedTimer); sg_feedTimer = nil; }
    SGWebPlayerMediaStop();
    Feed().json = nil;
}
NSData *SGWebPlayerFeedJSON(void) { return Feed().json; }
