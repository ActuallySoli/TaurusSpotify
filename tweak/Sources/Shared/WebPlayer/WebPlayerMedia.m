#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import "Core/SGPrefs.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "SGWebPlayerBridge.h"
#import "WebPlayer.h"

static const off_t kClipCap = 16 * 1024 * 1024;
static const NSUInteger kChunkCap = 256 * 1024;

@interface SGWebMediaAsset : NSObject
@property (nonatomic, copy) NSURL *file;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic) off_t length;
@property (nonatomic) dev_t device;
@property (nonatomic) ino_t inode;
@end
@implementation SGWebMediaAsset
@end

static NSObject *MediaLock(void) {
    static NSObject *lock; static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; }); return lock;
}
static SGWebMediaAsset *sg_asset;
static BOOL sg_mediaActive;
static NSUInteger sg_mediaGeneration;
static NSString *sg_mediaTrack;
static BOOL sg_mediaEnabled;

static BOOL Hex(NSString *text, NSUInteger minimum, NSUInteger maximum) {
    return text.length >= minimum && text.length <= maximum &&
        [text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"].invertedSet].location == NSNotFound;
}

NSString *SGWebPlayerCoverURL(NSDictionary *metadata) {
    if (![metadata isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *key in @[@"image_xlarge_url", @"image_large_url", @"image_url"]) {
        id raw = metadata[key];
        if (![raw isKindOfClass:NSString.class] || [raw length] > 256) continue;
        NSString *text = raw;
        if ([text hasPrefix:@"spotify:image:"]) text = [@"https://i.scdn.co/image/" stringByAppendingString:[text substringFromIndex:14]];
        NSURLComponents *url = [NSURLComponents componentsWithString:text];
        if (![url.scheme isEqual:@"https"] || ![url.host isEqual:@"i.scdn.co"] || url.user || url.password ||
            url.port || url.query || url.fragment || ![url.percentEncodedPath hasPrefix:@"/image/"]) continue;
        NSString *identifier = [url.percentEncodedPath substringFromIndex:7];
        if (Hex(identifier, 32, 128) && [text isEqual:[@"https://i.scdn.co/image/" stringByAppendingString:identifier]]) return text;
    }
    return nil;
}

static NSURL *MediaFolder(void) {
#ifdef SG_WEBPLAYER_HARNESS
    extern NSURL *SGWebPlayerHarnessMotionFolder(void);
    return SGWebPlayerHarnessMotionFolder();
#else
    NSURL *cache = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    return [cache URLByAppendingPathComponent:@"spoti.pw/Motion" isDirectory:YES];
#endif
}

static SGWebMediaAsset *ValidatedAsset(NSURL *file) {
    if (!file.isFileURL || ![file.pathExtension isEqual:@"mp4"] || !Hex(file.lastPathComponent.stringByDeletingPathExtension, 40, 40)) return nil;
    NSString *folder = [MediaFolder().URLByResolvingSymlinksInPath.path stringByAppendingString:@"/"];
    NSString *path = file.URLByResolvingSymlinksInPath.path;
    struct stat original;
    if (![path hasPrefix:folder] || lstat(file.path.fileSystemRepresentation, &original) || S_ISLNK(original.st_mode)) return nil;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return nil;
    struct stat info;
    uint8_t signature[12];
    BOOL valid = !fstat(fd, &info) && S_ISREG(info.st_mode) && info.st_size >= 12 && info.st_size <= kClipCap &&
        pread(fd, signature, sizeof signature, 0) == sizeof signature && !memcmp(signature + 4, "ftyp", 4);
    close(fd);
    if (!valid) return nil;
    SGWebMediaAsset *asset = [SGWebMediaAsset new];
    asset.file = [NSURL fileURLWithPath:path]; asset.identifier = NSUUID.UUID.UUIDString;
    asset.length = info.st_size; asset.device = info.st_dev; asset.inode = info.st_ino;
    return asset;
}

void SGWebPlayerMediaStart(void) {
    NSCAssert(NSThread.isMainThread, @"Artwork lifecycle belongs to main");
    sg_mediaActive = YES; sg_mediaTrack = nil; sg_mediaEnabled = NO; ++sg_mediaGeneration;
    @synchronized (MediaLock()) { sg_asset = nil; }
}
void SGWebPlayerMediaStop(void) {
    NSCAssert(NSThread.isMainThread, @"Artwork lifecycle belongs to main");
    sg_mediaActive = NO; sg_mediaTrack = nil; ++sg_mediaGeneration;
    @synchronized (MediaLock()) { sg_asset = nil; }
}
void SGWebPlayerMediaUpdate(SPTPlayerState *state, NSString *uri) {
    NSCAssert(NSThread.isMainThread, @"Artwork track belongs to main");
    BOOL enabled = sg_mediaActive && SGFlag(SGKeyWebPlayerMotion, NO);
    if ([sg_mediaTrack ?: @"" isEqual:uri ?: @""] && enabled == sg_mediaEnabled) return;
    sg_mediaTrack = [uri copy]; sg_mediaEnabled = enabled;
    NSUInteger generation = ++sg_mediaGeneration;
    @synchronized (MediaLock()) { sg_asset = nil; }
    if (!enabled || ![uri hasPrefix:@"spotify:track:"]) return;
    NSDictionary *metadata = [state.track.metadata isKindOfClass:NSDictionary.class] ? state.track.metadata : nil;
    NSString *album = [metadata[@"album_title"] isKindOfClass:NSString.class] ? metadata[@"album_title"] : nil;
    // The shared source walk may finish after Stop or a skip; only this generation can publish it.
    SGMotionClipFor(uri, SGMotionCanvasIn(metadata), state.track.artistName, album, SGMotionTall, 480, ^(NSURL *file, NSString *source) {
        (void)source;
        if (!sg_mediaActive || generation != sg_mediaGeneration || !file) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            SGWebMediaAsset *asset = ValidatedAsset(file);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (sg_mediaActive && generation == sg_mediaGeneration && SGFlag(SGKeyWebPlayerMotion, NO))
                    @synchronized (MediaLock()) { sg_asset = asset; }
            });
        });
    });
}
NSDictionary *SGWebPlayerMediaDescription(void) {
    @synchronized (MediaLock()) {
        if (!sg_asset) return nil;
        return @{@"id": sg_asset.identifier, @"path": [@"/api/artwork/" stringByAppendingString:sg_asset.identifier], @"bytes": @(sg_asset.length)};
    }
}

NSData *SGWebPlayerMediaRead(NSString *identifier, NSString *range, NSInteger *status, NSString **contentRange) {
    *status = 404; *contentRange = nil;
    SGWebMediaAsset *asset;
    @synchronized (MediaLock()) { if ([sg_asset.identifier isEqual:identifier]) asset = sg_asset; }
    if (!asset || !SGFlag(SGKeyWebPlayerMotion, NO)) return nil;
    *status = 416; *contentRange = [NSString stringWithFormat:@"bytes */%lld", (long long)asset.length];
    if (![range hasPrefix:@"bytes="] || range.length > 48) return nil;
    NSArray<NSString *> *bounds = [[range substringFromIndex:6] componentsSeparatedByString:@"-"];
    if (bounds.count != 2) return nil;
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet;
    for (NSString *bound in bounds) if (!bound.length || bound.length > 10 || [bound rangeOfCharacterFromSet:invalid].location != NSNotFound) return nil;
    unsigned long long start = bounds[0].longLongValue, end = bounds[1].longLongValue;
    if (start > end || start >= (unsigned long long)asset.length || end - start >= kChunkCap) return nil;
    end = MIN(end, (unsigned long long)asset.length - 1);
    NSUInteger length = (NSUInteger)(end - start + 1);
    int fd = open(asset.file.path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) { *status = 404; *contentRange = nil; return nil; }
    struct stat info;
    BOOL valid = !fstat(fd, &info) && S_ISREG(info.st_mode) && info.st_dev == asset.device && info.st_ino == asset.inode && info.st_size == asset.length;
    NSMutableData *data = valid ? [NSMutableData dataWithLength:length] : nil;
    NSUInteger offset = 0;
    while (valid && offset < length) {
        ssize_t got = pread(fd, (uint8_t *)data.mutableBytes + offset, length - offset, (off_t)start + offset);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) { valid = NO; break; }
        offset += (NSUInteger)got;
    }
    close(fd);
    @synchronized (MediaLock()) { valid = valid && sg_asset == asset; }
    if (!valid) { *status = 404; *contentRange = nil; return nil; }
    *status = 206; *contentRange = [NSString stringWithFormat:@"bytes %llu-%llu/%lld", start, end, (long long)asset.length];
    return data;
}
