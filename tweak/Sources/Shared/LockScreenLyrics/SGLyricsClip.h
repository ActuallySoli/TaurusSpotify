// A line of lyrics as a short video for the lock screen's full-screen artwork (LyricsArtwork.x): the
// line, and the next one dimmed under it, over the cover blurred. Core Graphics, Core Text, Core Image
// and AVFoundation only, so harness/lyrics-clip renders the same files on the Mac.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SGLyricsClipStyle) {
    SGLyricsClipStill = 0,   // one frame, held
    SGLyricsClipAnimated,    // the cover breathes behind the words, in a loop
};

// Where the words sit against the artwork. Words runs over the whole screen as before; the rest keep
// the cover itself in sight -- Poster holds it sharp above the line, Vinyl spins it as a record,
// Messages speaks the line in a chat bubble beside it, Polaroid prints it in a tilted frame with the
// line on the chin, Stickers pastes it on as a die-cut with the line on a label, Duotone tints it to
// two tones under the line.
typedef NS_ENUM(NSInteger, SGLyricsClipComposition) {
    SGLyricsClipWords = 0,   // the line over the blurred cover, full screen
    SGLyricsClipPoster,      // the cover, sharp and rounded, above the line
    SGLyricsClipVinyl,       // the cover as a spinning record, the line under it
    SGLyricsClipMessages,    // the line in a chat bubble beside the cover
    SGLyricsClipPolaroid,    // the cover as a tilted print, the line written on the chin
    SGLyricsClipStickers,    // the cover as a die-cut sticker, the line on a label sticker
    SGLyricsClipDuotone,     // the cover tinted to two tones, the line on it
};

NSArray<NSString *> *SGLyricsClipCompositionNames(void);

// The 3:4 size of a clip `pixels` wide, both sides a multiple of 16 for the encoder.
CGSize SGLyricsClipSize(CGFloat pixels);
// The cover blurred and darkened to fill `size`, made once per track; a dark field for a NULL cover.
CGImageRef SGLyricsClipBackdrop(CGImageRef cover, CGSize size) CF_RETURNS_RETAINED;
// The clip's first frame, for the lock screen's preview image. `line` or `next` may be nil.
// The `In` forms take the composition and the sharp cover; the plain ones are the Words look.
CGImageRef SGLyricsClipFrame(CGImageRef backdrop, NSString *line, NSString *next, CGSize size) CF_RETURNS_RETAINED;
CGImageRef SGLyricsClipFrameIn(CGImageRef backdrop, CGImageRef cover, NSString *line, NSString *next, CGSize size,
                               SGLyricsClipStyle style, SGLyricsClipComposition composition) CF_RETURNS_RETAINED;
// Writes the clip as H.264 to `file`, replacing it, and returns once it is written; NO if it was not.
BOOL SGLyricsClipWrite(NSURL *file, CGImageRef backdrop, NSString *line, NSString *next, CGSize size, SGLyricsClipStyle style);
BOOL SGLyricsClipWriteIn(NSURL *file, CGImageRef backdrop, CGImageRef cover, NSString *line, NSString *next, CGSize size,
                         SGLyricsClipStyle style, SGLyricsClipComposition composition);
BOOL SGLyricsClipWriteOverMotion(NSURL *file, NSURL *motion, NSString *previous, NSString *line, NSString *next,
                                  double from, double seconds);
// The cache key of a clip: the moving artwork, the style and the composition.
NSString *SGLyricsClipLook(NSURL *motion, SGLyricsClipStyle style, SGLyricsClipComposition composition);
CGImageRef SGLyricsClipMotionFrame(NSURL *motion, NSString *previous, NSString *line, NSString *next, double from) CF_RETURNS_RETAINED;

// Track-relative phase keeps the record's angle continuous when the current lyric changes.
CGImageRef SGLyricsClipFrameInAtTime(CGImageRef backdrop, CGImageRef cover, NSString *line, NSString *next, CGSize size,
                                    SGLyricsClipStyle style, SGLyricsClipComposition composition, double from) CF_RETURNS_RETAINED;
BOOL SGLyricsClipWriteInAtTime(NSURL *file, CGImageRef backdrop, CGImageRef cover, NSString *line, NSString *next, CGSize size,
                              SGLyricsClipStyle style, SGLyricsClipComposition composition, double from);

typedef struct {
    NSUInteger location;
    NSUInteger length;
    double start;   // seconds from the start of the line
    double end;     // seconds from the start of the line
} SGLyricsClipWord;

typedef struct {
    __unsafe_unretained NSString *previous;
    __unsafe_unretained NSString *line;
    __unsafe_unretained NSString *next;
    const SGLyricsClipWord *words;
    NSUInteger wordCount;
    double elapsedInLine;   // seconds already sung in `line` at frame 0 (pause freeze-frame / mid-line resume)
    double sungDuration;    // seconds `line` takes to be sung (0 uses default estimate)
    double clipDuration;    // seconds the video clip runs (0 uses kLoopSeconds)
    double songTime;        // track position in seconds at frame 0, for continuous phase
    BOOL scrollIn;          // eases the line stack up over the first 0.28 s when animated
} SGLyricsClipKaraokeSpec;

CGImageRef SGLyricsClipKaraokeFrame(CGImageRef backdrop, CGImageRef cover, CGSize size,
                                    SGLyricsClipStyle style, SGLyricsClipComposition composition,
                                    SGLyricsClipKaraokeSpec spec) CF_RETURNS_RETAINED;
BOOL SGLyricsClipWriteKaraoke(NSURL *file, CGImageRef backdrop, CGImageRef cover, CGSize size,
                              SGLyricsClipStyle style, SGLyricsClipComposition composition,
                              SGLyricsClipKaraokeSpec spec);
