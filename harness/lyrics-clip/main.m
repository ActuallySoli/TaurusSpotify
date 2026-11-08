#import <AppKit/AppKit.h>
#import "../../tweak/Sources/Shared/LockScreenLyrics/SGLyricsClip.m"

static int failures;
#define CHECK(ok, label) do { printf("%s %s\n", (ok) ? "PASS" : "FAIL", label); if (!(ok)) failures++; } while (0)

static NSData *pixels(CGImageRef image) {
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    NSMutableData *bytes = [NSMutableData dataWithLength:width * height * 4];
    CGContextRef context = newContext(CGSizeMake(width, height), bytes.mutableBytes, width * 4);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    return bytes;
}

static void save(CGImageRef image, NSString *path) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

int main(void) {
    @autoreleasepool {
        CGSize size = SGLyricsClipSize(480);
        CGContextRef ctx = newContext(size, NULL, 0);
        CGContextSetRGBFillColor(ctx, 0.2, 0.35, 0.7, 1);
        CGContextFillRect(ctx, (CGRect){CGPointZero, size});
        CGContextSetRGBFillColor(ctx, 1, 0.4, 0.1, 1);
        CGContextFillRect(ctx, CGRectMake(0, 0, size.width / 2, size.height / 2));
        CGImageRef cover = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
        CGImageRef backdrop = SGLyricsClipBackdrop(NULL, size);
        NSArray *lines = @[@"A short lyric", @"This is a longer lyric that must wrap into several lines without disappearing behind the player controls",
            @"世界が変わってもこの歌を一緒に歌い続けよう", @"هذه الكلمات الطويلة يجب أن تبقى كاملة داخل الشاشة",
            @"A very long unbroken word: SupercalifragilisticexpialidociousSupercalifragilisticexpialidocious"];
        CGImageRef blank = SGLyricsClipFrameInAtTime(backdrop, cover, nil, nil, size, SGLyricsClipAnimated, SGLyricsClipVinyl, 1.6);
        NSData *empty = pixels(blank);
        for (NSUInteger i = 0; i < lines.count; i++) {
            CGImageRef frame = SGLyricsClipFrameInAtTime(backdrop, cover, lines[i], nil, size, SGLyricsClipAnimated, SGLyricsClipVinyl, 1.6);
            NSData *filled = pixels(frame);
            const uint8_t *a = empty.bytes, *b = filled.bytes;
            NSUInteger changed = 0, unsafe = 0, recordChanged = 0;
            for (size_t y = 0; y < size.height; y++) for (size_t x = 0; x < size.width; x++) {
                size_t offset = (y * (size_t)size.width + x) * 4;
                if (memcmp(a + offset, b + offset, 4)) {
                    changed++;
                    double gy = size.height - 1 - y; // image bytes run down from the top
                    if (x < size.width * 0.235 || x > size.width * 0.765 || gy < size.height * 0.23 || gy > size.height * 0.43) unsafe++;
                    if (gy > size.height * 0.44) recordChanged++;
                }
            }
            CHECK(changed > 20, "lyrics render visible pixels");
            CHECK(unsafe == 0, "all lyric pixels stay inside the tall-screen safe area");
            CHECK(recordChanged == 0, "changing the line does not change the record's rotation");
            save(frame, [NSString stringWithFormat:@"harness/lyrics-clip/build/vinyl-%lu.png", (unsigned long)i]);
            CGImageRelease(frame);
        }
        CGImageRef later = SGLyricsClipFrameInAtTime(backdrop, cover, nil, nil, size, SGLyricsClipAnimated, SGLyricsClipVinyl, 1.8);
        CHECK(![pixels(later) isEqual:empty], "the record advances with the song clock");
        CGImageRef loop = SGLyricsClipFrameInAtTime(backdrop, cover, nil, nil, size, SGLyricsClipAnimated, SGLyricsClipVinyl, 5.6);
        CHECK([pixels(loop) isEqual:empty], "phase repeats seamlessly after one full revolution");
        // The actual encoded asset must keep the requested phase and remain playable.
        NSURL *file = [NSURL fileURLWithPath:@"harness/lyrics-clip/build/vinyl.mp4"];
        BOOL written = SGLyricsClipWriteInAtTime(file, backdrop, cover, lines[1], nil, size,
                                               SGLyricsClipAnimated, SGLyricsClipVinyl, 1.6);
        CHECK(written, "a real phase-aligned H.264 vinyl clip is written");
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:file options:nil];
        CHECK(fabs(CMTimeGetSeconds(asset.duration) - 4) < 0.05, "animated clip contains a complete four-second rotation");
        AVAssetImageGenerator *generator = [[AVAssetImageGenerator alloc] initWithAsset:asset];
        generator.requestedTimeToleranceBefore = kCMTimeZero;
        generator.requestedTimeToleranceAfter = kCMTimeZero;
        CGImageRef decoded = [generator copyCGImageAtTime:kCMTimeZero actualTime:NULL error:nil];
        CHECK(decoded != NULL, "the encoded first frame decodes");
        CGImageRef preview = SGLyricsClipFrameInAtTime(backdrop, cover, lines[1], nil, size, SGLyricsClipAnimated, SGLyricsClipVinyl, 1.6);
        if (decoded) {
            NSData *a = pixels(decoded), *b = pixels(preview);
            const uint8_t *aa = a.bytes, *bb = b.bytes;
            double error = 0;
            for (NSUInteger i = 0; i < a.length; i++) error += abs((int)aa[i] - (int)bb[i]);
            CHECK(a.length == b.length && error / a.length < 8, "preview matches the video's first frame, including rotation");
        }
        CGImageRelease(preview); CGImageRelease(decoded); CGImageRelease(loop); CGImageRelease(later);
        CGImageRelease(blank); CGImageRelease(backdrop); CGImageRelease(cover);
    }
    return failures ? 1 : 0;
}
