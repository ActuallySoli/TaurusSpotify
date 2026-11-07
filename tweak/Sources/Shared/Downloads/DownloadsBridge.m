#import "Core/SGCore.h"
#import "Downloads.h"
#import "DownloadsBridge.h"

NSNotificationName const SGDownloadsDidChangeNotification = @"spotifyglass.downloads.changed";

Class<SGDownloadsCompanion> SGDownloadsCompanion(void) {
    Class found = NSClassFromString(@"SAPTaurusBridge");
    if (found && [found respondsToSelector:@selector(interfaceVersion)]
        && [(Class<SGDownloadsCompanion>)found interfaceVersion] >= 1) return (Class<SGDownloadsCompanion>)found;
    return nil;
}

BOOL SGDownloadsAvailable(void) { return SGDownloadsCompanion() != nil; }

BOOL SGDownloadsActive(void) { return [SGDownloadsCompanion() downloadActive]; }

NSString *SGDownloadsSummary(void) {
    Class<SGDownloadsCompanion> companion = SGDownloadsCompanion();
    if (!companion) {
        NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        if (version.length && ![@[@"9.1.90", @"9.1.94"] containsObject:version])
            return [NSString stringWithFormat:@"Downloads unavailable on Spotify %@", version];
        return @"Downloads engine isn't loaded";
    }
    return [companion downloadSummary] ?: @"No download started";
}

NSString *SGDownloadsUnavailableReason(void) {
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if ([@[@"9.1.90", @"9.1.94"] containsObject:version])
        return [NSString stringWithFormat:@"This copy is Spotify %@, but the Downloads engine is missing or could not load. Install a Taurus IPA built with Downloads from the matching verified decrypted release. A tweak-only build or a build made with --no-downloads does not include the engine.", version];
    return [NSString stringWithFormat:@"This copy is Spotify %@. Downloads supports the exact Spotify 9.1.90 and 9.1.94 builds whose executable UUIDs and patch bytes were checked. Install a Taurus IPA built with Downloads from one of those releases.", version.length ? version : @"(version unavailable)"];
}

NSString *SGDownloadsRowSummary(void) {
    if (!SGDownloadsAvailable()) return @"Unavailable";
    return SGDownloadsActive() ? @"Downloading" : @"Ready";
}
