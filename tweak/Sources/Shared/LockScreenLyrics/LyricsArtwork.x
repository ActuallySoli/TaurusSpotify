// The lock screen's full-screen artwork as the lyrics, a clip per line (SGLyricsClip.h draws it). A timer
// works out the line being sung and hands the lock screen a new artwork under a new ID each time it
// changes. Nothing is drawn until the lock screen asks for that artwork's video, so lines sung with the
// screen off cost nothing. It rides on Spotify's now playing info as an extra (NowPlayingExtras.h), like
// the moving artwork it takes the place of.
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "LockScreenLyrics.h"
#import "SGLyricsClip.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/NowPlayingExtras.h"
#import "Shared/Player/PlayerState.h"

static const NSTimeInterval kTick = 0.25;
// Past a line's sung end by this much, with the next line at least this far off, the line is let go and
// only the next one shows, dimmed (as the artist row does in LockScreenLyrics.x).
static const NSInteger kBreakMs = 4000;
static const double kShortest = 2, kLongest = 8;

@interface SGLockLine : NSObject
@property (nonatomic, copy) NSString *previous, *line, *next;
@property (nonatomic, copy) NSData *wordSpans;
@property (nonatomic) UIImage *cover;
@property (nonatomic) SGLyricsClipStyle style;
@property (nonatomic) SGLyricsClipComposition composition;
@property (nonatomic) NSURL *motion;
@property (nonatomic) double from, seconds, elapsedInLine, sungDuration;
@property (nonatomic) BOOL scrollIn;
@end

@implementation SGLockLine
@end

static dispatch_source_t sg_timer;
static NSString *sg_motionURI;
static NSURL *sg_motion;
static NSMutableSet<NSString *> *sg_failedMotion;
static NSString *sg_track;     // the track the clips are for
static UIImage *sg_cover;      // its cover, once Spotify's now playing info has one for it
static NSString *sg_shownID;   // the artwork handed over last, nil for none; read on sg_queue too
static NSString *sg_resumeTrack;
static NSInteger sg_resumeIndex = NSNotFound;
static NSInteger sg_resumeBucket = 0;
static NSObject *sg_lock;
static dispatch_queue_t sg_queue;   // writes the clips, one at a time
// Draws the previews, apart from the clips: one waiting behind a clip that takes seconds left the lock screen blank.
static dispatch_queue_t sg_previewQueue;

static BOOL motionFailed(NSURL *file) {
    @synchronized (sg_failedMotion) {
        return [sg_failedMotion containsObject:file.path];
    }
}

static void markMotionFailed(NSURL *file, NSString *artworkID) {
    @synchronized (sg_failedMotion) {
        if ([sg_failedMotion containsObject:file.path]) return;
        [sg_failedMotion addObject:file.path];
    }
    SGLog(@"lock lyrics: %@ could not be composited for %@; using the cover", file.lastPathComponent, artworkID);
}

static NSURL *folder(void) {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    return [caches URLByAppendingPathComponent:@"spoti.pw/Lyrics" isDirectory:YES];
}

// The blurred cover, made once per cover and shared by both queues; the caller releases it.
static CGImageRef copyBackdropFor(UIImage *cover, CGSize size) {
    static id made;
    static CGImageRef backdrop;
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    @synchronized (lock) {
        id key = cover ?: NSNull.null;
        if (!backdrop || made != key) {
            CGImageRelease(backdrop);
            backdrop = SGLyricsClipBackdrop(cover.CGImage, size);
            made = key;
        }
        return CGImageRetain(backdrop);
    }
}

static BOOL stillShown(NSString *artworkID) {
    @synchronized (sg_lock) {
        return [artworkID isEqualToString:sg_shownID];
    }
}

static void setShown(NSString *artworkID) {
    @synchronized (sg_lock) {
        sg_shownID = artworkID;
    }
}

// The lock screen's last asks, as absolute times: lines are drawn ahead only while it is showing them, previews and
// clips each by their own asks, as it asks for clips far less often.
static CFAbsoluteTime sg_askedAt, sg_previewAskedAt;
// Previews drawn ahead, by artwork ID.
static NSCache<NSString *, UIImage *> *sg_previews;
static NSCache<NSString *, NSURL *> *sg_clips;
static NSMutableSet<NSString *> *sg_preparing;
static NSSet<NSString *> *sg_wanted;
static void tick(void);

static NSURL *clipFile(NSString *artworkID) {
    return [folder() URLByAppendingPathComponent:[artworkID stringByAppendingPathExtension:@"mp4"]];
}

static SGLyricsClipKaraokeSpec karaokeSpecFor(SGLockLine *line) {
    NSUInteger count = line.wordSpans.length / sizeof(SGLyricsClipWord);
    const SGLyricsClipWord *words = count > 0 ? (const SGLyricsClipWord *)line.wordSpans.bytes : NULL;
    return (SGLyricsClipKaraokeSpec){
        .previous = line.previous,
        .line = line.line,
        .next = line.next,
        .words = words,
        .wordCount = count,
        .elapsedInLine = line.elapsedInLine,
        .sungDuration = line.sungDuration,
        .clipDuration = line.seconds,
        .songTime = line.from,
        .scrollIn = line.scrollIn,
    };
}

// On sg_previewQueue.
static UIImage *previewFor(NSString *artworkID, SGLockLine *line, CGSize size) {
    UIImage *preview = [sg_previews objectForKey:artworkID];
    if (preview) return preview;
    BOOL tryMotion = line.motion && line.composition == SGLyricsClipWords && !motionFailed(line.motion);
    CGImageRef frame = tryMotion ? SGLyricsClipMotionFrame(line.motion, line.previous, line.line, line.next, line.from) : NULL;
    if (tryMotion && !frame) markMotionFailed(line.motion, artworkID);
    if (!frame) {
        CGImageRef backdrop = copyBackdropFor(line.cover, size);
        frame = SGLyricsClipKaraokeFrame(backdrop, line.cover.CGImage, size, line.style, line.composition, karaokeSpecFor(line));
        CGImageRelease(backdrop);
    }
    if (frame) [sg_previews setObject:(preview = [UIImage imageWithCGImage:frame]) forKey:artworkID];
    CGImageRelease(frame);
    return preview;
}

static BOOL writeClip(NSString *artworkID, SGLockLine *line, CGSize size) {
    NSURL *file = clipFile(artworkID);
    if ([NSFileManager.defaultManager fileExistsAtPath:file.path]) {
        [sg_clips setObject:file forKey:artworkID];
        return YES;
    }
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    BOOL tryMotion = line.motion && line.composition == SGLyricsClipWords && !motionFailed(line.motion);
    BOOL over = tryMotion && SGLyricsClipWriteOverMotion(file, line.motion, line.previous, line.line, line.next, line.from, line.seconds);
    if (tryMotion && !over) markMotionFailed(line.motion, artworkID);
    BOOL ok = over;
    if (!ok) {
        CGImageRef backdrop = copyBackdropFor(line.cover, size);
        ok = SGLyricsClipWriteKaraoke(file, backdrop, line.cover.CGImage, size, line.style, line.composition, karaokeSpecFor(line));
        CGImageRelease(backdrop);
    }
    // The first few of a launch, and any that fails: one a line would fill the log.
    static NSUInteger told;
    if (!ok || told++ < 5) SGLog(@"lock lyrics: %@ %@ in %.0f ms", artworkID, ok ? @"written" : @"not written",
                                  (CFAbsoluteTimeGetCurrent() - start) * 1000);
    if (ok) [sg_clips setObject:file forKey:artworkID];
    return ok;
}

// Pre-renders both preview and clip before handing an artworkID to SpringBoard, and draws upcoming lines ahead
// so a line change hands both over from cache in 0 ms without flashing the plain album cover.
static void drawAhead(NSString *artworkID, SGLockLine *line, BOOL urgent) {
    CFAbsoluteTime time = CFAbsoluteTimeGetCurrent();
    CGSize size = SGLyricsClipSize(SGMotionPixels());
    for (NSUInteger kind = 0; kind < 2; kind++) {
        BOOL video = kind == 1;
        if (!urgent && time - (video ? sg_askedAt : sg_previewAskedAt) > 60) continue;
        if (video ? [sg_clips objectForKey:artworkID] != nil : [sg_previews objectForKey:artworkID] != nil) continue;
        NSString *key = [artworkID stringByAppendingString:video ? @"-video" : @"-preview"];
        @synchronized (sg_lock) {
            if ([sg_preparing containsObject:key]) continue;
            [sg_preparing addObject:key];
        }
        dispatch_async(video ? sg_queue : sg_previewQueue, ^{
            BOOL wanted;
            @synchronized (sg_lock) { wanted = [sg_wanted containsObject:artworkID]; }
            BOOL ready = NO;
            if (wanted) {
                if (video) ready = writeClip(artworkID, line, size);
                else ready = (previewFor(artworkID, line, size) != nil);
            }
            @synchronized (sg_lock) { [sg_preparing removeObject:key]; }
            if (ready && urgent) {
                dispatch_async(dispatch_get_main_queue(), ^{ tick(); });
            }
        });
    }
}

static void requestedAsset(BOOL video) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (video) sg_askedAt = CFAbsoluteTimeGetCurrent();
        else sg_previewAskedAt = CFAbsoluteTimeGetCurrent();
        tick();
    });
}

API_AVAILABLE(ios(26.0))
static MPMediaItemAnimatedArtwork *artworkFor(NSString *artworkID, SGLockLine *line) {
    CGSize size = SGLyricsClipSize(SGMotionPixels());
    return [[MPMediaItemAnimatedArtwork alloc] initWithArtworkID:artworkID
        previewImageRequestHandler:^(CGSize wanted, void (^completion)(UIImage *)) {
            requestedAsset(NO);
            // One drawn ahead is handed over at once, as Apple asks of a preview; only a miss waits for drawing.
            UIImage *ready = [sg_previews objectForKey:artworkID];
            if (ready) {
                completion(ready);
                return;
            }
            dispatch_async(sg_previewQueue, ^{
                completion(previewFor(artworkID, line, size));
                static NSUInteger told;
                if (told++ < 10) SGLog(@"lock lyrics: preview of %@ was not drawn ahead", artworkID);
            });
        }
        videoAssetFileURLRequestHandler:^(CGSize wanted, void (^completion)(NSURL *)) {
            requestedAsset(YES);
            NSURL *ready = [sg_clips objectForKey:artworkID];
            if (ready && stillShown(artworkID)) {
                completion(ready);
                return;
            }
            dispatch_async(sg_queue, ^{
                // A line already sung by the time its turn comes is not drawn.
                if (!stillShown(artworkID)) {
                    completion(nil);
                    return;
                }
                completion(writeClip(artworkID, line, size) ? clipFile(artworkID) : nil);
            });
        }];
}

static void clear(void) {
    if (!sg_shownID) return;
    setShown(nil);
    @synchronized (sg_lock) { sg_wanted = nil; }
    SGNowPlayingSetExtras(@"lyrics", nil, nil);
}

static NSString *textAt(NSArray<SGKaraokeLine *> *lines, NSInteger index) {
    return index >= 0 && index < (NSInteger)lines.count ? SGKaraokeLineText(lines[index]) : nil;
}

void SGLyricsArtworkSetMotion(NSString *uri, NSURL *file) {
    @synchronized (sg_failedMotion) {
        if (file) [sg_failedMotion removeObject:file.path];
    }
    sg_motionURI = uri;
    sg_motion = file;
    dispatch_async(dispatch_get_main_queue(), ^{ tick(); });
}

static SGLockLine *lineAt(NSArray<SGKaraokeLine *> *lines, NSInteger index, BOOL resting, NSURL *motion,
                          UIImage *cover, SGLyricsClipStyle style, SGLyricsClipComposition composition) {
    SGLockLine *shown = [SGLockLine new];
    shown.line = resting ? nil : textAt(lines, index);
    shown.next = textAt(lines, index + 1);
    shown.previous = (composition == SGLyricsClipWords && !resting) ? textAt(lines, index - 1) : nil;
    shown.cover = cover;
    shown.style = style;
    shown.composition = composition;
    shown.motion = motion;
    shown.scrollIn = (style == SGLyricsClipAnimated && !resting && index > 0);
    NSInteger start = index < 0 ? 0 : resting ? SGKaraokeSungEnd(lines[index]) + kBreakMs : lines[index].start;
    NSInteger end = index + 1 < (NSInteger)lines.count ? lines[index + 1].start
                 : index < 0 ? start : SGKaraokeSungEnd(lines[index]) + kBreakMs;
    shown.from = start / 1000.0;
    shown.seconds = MIN(MAX((end - start) / 1000.0 + 0.5, kShortest), kLongest);
    if (!resting && index >= 0 && index < (NSInteger)lines.count) {
        SGKaraokeLine *kLine = lines[index];
        NSInteger lineStart = kLine.start;
        NSInteger lineEnd = SGKaraokeSungEnd(kLine);
        if (lineEnd > lineStart) shown.sungDuration = (lineEnd - lineStart) / 1000.0;
        if (kLine.words.count > 0) {
            NSMutableData *data = [NSMutableData dataWithCapacity:kLine.words.count * sizeof(SGLyricsClipWord)];
            NSUInteger cursor = 0;
            for (SGKaraokeWord *w in kLine.words) {
                NSString *piece = w.text ?: @"";
                if (cursor > 0 && !w.joined) cursor += 1;
                if (piece.length > 0) {
                    SGLyricsClipWord cw = {
                        .location = cursor,
                        .length = piece.length,
                        .start = MAX(0.0, (double)(w.start - lineStart) / 1000.0),
                        .end = MAX(0.06, (double)(MAX(w.end, w.start + 60) - lineStart) / 1000.0),
                    };
                    [data appendBytes:&cw length:sizeof(cw)];
                }
                cursor += piece.length;
            }
            shown.wordSpans = data;
        }
    }
    return shown;
}

static void tick(void) {
    if (@available(iOS 26.0, *)) {
        SPTPlayerState *state = SGPlayerState();
        NSString *trackID = SGKaraokePlayingTrack();
        if (!trackID || !state) {
            clear();
            return;
        }
        if (![trackID isEqualToString:sg_track]) {
            sg_track = trackID;
            sg_cover = nil;
            sg_resumeTrack = nil;
            sg_resumeIndex = NSNotFound;
            sg_resumeBucket = 0;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            sg_askedAt = sg_previewAskedAt = now;
            [sg_clips removeAllObjects];
            [sg_previews removeAllObjects];
            // The IDs name the track, so the last track's clips are never asked for again.
            dispatch_async(sg_queue, ^{
                [NSFileManager.defaultManager removeItemAtURL:folder() error:nil];
                [NSFileManager.defaultManager createDirectoryAtURL:folder() withIntermediateDirectories:YES attributes:nil error:nil];
            });
        }
        NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(trackID);
        if (!lines) SGKaraokeRequestLyrics(trackID);
        SGLockArtwork artworkChoice = SGLockScreenEffectiveArtwork();
        BOOL overMotion = SGLockScreenCanvasLyricsEnabled() && SGLockArtworkHasMotion(artworkChoice);
        BOOL lyricsOn = SGLockScreenLyricsViewEnabled() && (artworkChoice == SGLockArtworkLyrics || overMotion);
        if (!lyricsOn) {
            clear();
            SGLockMotionShowPlain(NO);
            return;
        }
        // Plain text has no line being sung; the cover or moving artwork shows without lyric overlays.
        if (!lines.count || SGKaraokeLinesTiming(lines) == SGKaraokeTimingNone) {
            static NSString *told;
            if (lines && ![told isEqualToString:trackID]) {
                told = trackID;
                SGLog(@"lock lyrics: %@ has no synced lines, the lock screen keeps its artwork", trackID);
            }
            clear();
            SGLockMotionShowPlain(YES);
            return;
        }
        NSInteger position = SGKaraokePositionMs();
        if (position < 0) return;
        position -= SGKaraokeDelayMs();
        NSInteger index = SGKaraokeLeadLine(lines, position);
        BOOL nextFarOff = index + 1 == (NSInteger)lines.count || lines[index + 1].start - position > kBreakMs;
        BOOL resting = index < 0 || (position > SGKaraokeSungEnd(lines[index]) + kBreakMs && nextFarOff);
        SGLyricsClipStyle style = (SGLyricsClipStyle)SGInt(SGKeyLockScreenLyricsStyle, SGLyricsClipAnimated);
        SGLyricsClipComposition composition = (SGLyricsClipComposition)SGInt(SGKeyLockScreenLyricsLook, SGLyricsClipWords);
        NSURL *motion = overMotion && composition == SGLyricsClipWords && [sg_motionURI isEqualToString:SGURIString(state.track.URI)] ? sg_motion : nil;
        if (motion && motionFailed(motion)) motion = nil;
        NSString *look = SGLyricsClipLook(motion, style, composition);
        // Spotify's request block for its cover, read on main and kept once it is this track's.
        if (!sg_cover) {
            NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
            MPMediaItemArtwork *artwork = info[MPMediaItemPropertyArtwork];
            if (SGNowPlayingTitlesMatch(info[MPMediaItemPropertyTitle], state.track.trackTitle)
                && [artwork isKindOfClass:MPMediaItemArtwork.class]) {
                sg_cover = [artwork imageWithSize:CGSizeMake(600, 600)];
            }
        }

        double elapsedInLine = (!resting && index >= 0) ? MAX(0.0, (double)(position - lines[index].start) / 1000.0) : 0.0;
        NSString *artworkID = nil;
        SGLockLine *currentLine = nil;
        if (state.isPaused) {
            NSInteger pauseBucket = (NSInteger)llround(elapsedInLine * 10.0);
            sg_resumeTrack = trackID;
            sg_resumeIndex = index;
            sg_resumeBucket = pauseBucket;
            artworkID = [NSString stringWithFormat:@"%@-%ld%@-p%ld-%@", trackID, (long)index, resting ? @"r" : @"", (long)pauseBucket, look];
            currentLine = lineAt(lines, index, resting, motion, sg_cover, SGLyricsClipStill, composition);
            currentLine.from = MAX(0.0, (double)position / 1000.0);
            currentLine.elapsedInLine = elapsedInLine;
            currentLine.scrollIn = NO;
        } else if ([sg_resumeTrack isEqualToString:trackID] && index == sg_resumeIndex && !resting && sg_resumeBucket > 2) {
            double resumeElapsed = (double)sg_resumeBucket / 10.0;
            artworkID = [NSString stringWithFormat:@"%@-%ld-res%ld-%@", trackID, (long)index, (long)sg_resumeBucket, look];
            currentLine = lineAt(lines, index, resting, motion, sg_cover, style, composition);
            currentLine.elapsedInLine = resumeElapsed;
            currentLine.from = MAX(0.0, (lines[index].start / 1000.0) + resumeElapsed);
            currentLine.seconds = MAX(kShortest, currentLine.seconds - resumeElapsed);
            currentLine.scrollIn = NO;
        } else {
            sg_resumeIndex = NSNotFound;
            sg_resumeBucket = 0;
            artworkID = [NSString stringWithFormat:@"%@-%ld%@-%@", trackID, (long)index, resting ? @"r" : @"", look];
            currentLine = lineAt(lines, index, resting, motion, sg_cover, style, composition);
        }

        // Refresh preparation after the first system request too, even if the lyric hasn't changed.
        NSMutableDictionary<NSString *, SGLockLine *> *aheadLines = [NSMutableDictionary dictionary];
        for (NSInteger aheadIndex = index + 1; aheadIndex < MIN(index + 3, (NSInteger)lines.count); aheadIndex++) {
            NSString *ahead = [NSString stringWithFormat:@"%@-%ld-%@", trackID, (long)aheadIndex, look];
            aheadLines[ahead] = lineAt(lines, aheadIndex, NO, motion, sg_cover, style, composition);
        }
        if (index >= 0 && !resting && nextFarOff) {
            NSString *restID = [NSString stringWithFormat:@"%@-%ldr-%@", trackID, (long)index, look];
            aheadLines[restID] = lineAt(lines, index, YES, motion, sg_cover, style, composition);
        }
        @synchronized (sg_lock) {
            NSMutableSet *wanted = [NSMutableSet setWithArray:aheadLines.allKeys];
            [wanted addObject:artworkID];
            sg_wanted = wanted;
        }
        drawAhead(artworkID, currentLine, YES);
        for (NSString *ahead in aheadLines) drawAhead(ahead, aheadLines[ahead], NO);
        if ([artworkID isEqualToString:sg_shownID]) return;
        // Wait until both the preview image and video clip are ready in cache before notifying SpringBoard,
        // so the lock screen switches clips synchronously in 0 ms without flashing the plain album cover.
        if (![sg_previews objectForKey:artworkID] || ![sg_clips objectForKey:artworkID]) return;
        if (![sg_shownID hasPrefix:trackID]) {
            SGLog(@"lock lyrics: lines offered for %@", trackID);
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (!sg_previewAskedAt) sg_previewAskedAt = now;
            if (!sg_askedAt) sg_askedAt = now;
        }
        if (motion && ![sg_shownID hasSuffix:[@"-" stringByAppendingString:look]])
            SGLog(@"lock lyrics: lines over moving artwork %@", motion.lastPathComponent);
        setShown(artworkID);
        SGLockMotionShowPlain(NO);
        SGNowPlayingSetExtras(@"lyrics", @{MPNowPlayingInfoProperty3x4AnimatedArtwork:
                                               artworkFor(artworkID, currentLine)},
                              state.track.trackTitle);
    }
}

// Main thread, as everything the timer touches is.
static void setTicking(BOOL on) {
    if (on == (sg_timer != nil)) return;
    if (!on) {
        dispatch_source_cancel(sg_timer);
        sg_timer = nil;
        return;
    }
    // A strict GCD timer: the main run loop's timers are throttled while the screen is off, and the lines stood
    // still on a locked phone.
    sg_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, dispatch_get_main_queue());
    uint64_t every = (uint64_t)(kTick * NSEC_PER_SEC);
    dispatch_source_set_timer(sg_timer, dispatch_time(DISPATCH_TIME_NOW, every), every, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(sg_timer, ^{
        static CFAbsoluteTime last;
        static int late;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (last && now - last > 2 && late++ < 5) SGLog(@"%s: ticked %.1f s late", __FILE_NAME__, now - last - kTick);
        last = now;
        tick();
    });
    dispatch_resume(sg_timer);
}

@interface SGLyricsArtwork : NSObject <SGPlayerStateObserver>
@end

@implementation SGLyricsArtwork
// A paused player's line swaps to a freeze-frame at the exact paused word and phase; resuming continues from there.
- (void)playerStateDidChange:(SPTPlayerState *)state {
    SGLockArtwork choice = SGLockScreenEffectiveArtwork();
    BOOL on = SGLockScreenLyricsViewEnabled()
        && (choice == SGLockArtworkLyrics || (SGLockScreenCanvasLyricsEnabled() && SGLockArtworkHasMotion(choice)));
    setTicking(on && !state.isPaused);
    if (on) tick();
    else {
        clear();
        SGLockMotionShowPlain(NO);
    }
}
@end

%ctor {
    if (@available(iOS 26.0, *)) {
        sg_lock = [NSObject new];
        sg_queue = dispatch_queue_create("spotifyglass.lockscreen.lyrics", DISPATCH_QUEUE_SERIAL);
        sg_previewQueue = dispatch_queue_create("spotifyglass.lockscreen.lyrics.preview", DISPATCH_QUEUE_SERIAL);
        sg_previews = [NSCache new];
        sg_clips = [NSCache new];
        sg_clips.countLimit = 8;
        sg_preparing = [NSMutableSet set];
        sg_failedMotion = [NSMutableSet set];
        sg_previews.countLimit = 8;
        static SGLyricsArtwork *observer;
        observer = [SGLyricsArtwork new];
        SGAddPlayerStateObserver(observer);
        // Heard on the writing thread and handed to main without waiting (AGENTS.md).
        static SGLockArtwork choice;
        static BOOL canvasLyrics;
        static BOOL lyricsView;
        static NSInteger lyricsStyle, lyricsLook;
        choice = SGLockScreenEffectiveArtwork();
        canvasLyrics = SGLockScreenCanvasLyricsEnabled();
        lyricsView = SGLockScreenLyricsViewEnabled();
        lyricsStyle = SGInt(SGKeyLockScreenLyricsStyle, SGLyricsClipAnimated);
        lyricsLook = SGInt(SGKeyLockScreenLyricsLook, SGLyricsClipWords);
        [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL enabled = SGLockScreenCanvasLyricsEnabled();
                BOOL viewEnabled = SGLockScreenLyricsViewEnabled();
                NSInteger style = SGInt(SGKeyLockScreenLyricsStyle, SGLyricsClipAnimated);
                NSInteger look = SGInt(SGKeyLockScreenLyricsLook, SGLyricsClipWords);
                if (SGLockScreenEffectiveArtwork() == choice && enabled == canvasLyrics && viewEnabled == lyricsView
                    && style == lyricsStyle && look == lyricsLook) return;
                choice = SGLockScreenEffectiveArtwork();
                canvasLyrics = enabled;
                lyricsView = viewEnabled;
                lyricsStyle = style;
                lyricsLook = look;
                SGLog(@"lock lyrics: artwork mode, lyrics look or overlay changed");
                [observer playerStateDidChange:SGPlayerState()];
            });
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:SGNotificationLockScreenEffectiveArtworkChanged
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) {
            [observer playerStateDidChange:SGPlayerState()];
        }];
        BOOL lyricsOn = lyricsView && (choice == SGLockArtworkLyrics || (canvasLyrics && SGLockArtworkHasMotion(choice)));
        SGLog(@"lock lyrics: %@, the lock screen takes %@", lyricsOn ? @"on" : @"off",
              MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys);
    }
}
