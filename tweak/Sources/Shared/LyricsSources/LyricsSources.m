// The chain: every source in the order the Lyrics page puts them in, asked one after another, the
// first with timed lyrics answering for the track.
//
// Stopping at the first answer is what makes the lyrics card under the player appear at all. For a
// track Spotify has no lyrics of its own for, the card is only offered when the answer to Spotify's
// lyrics request arrives within about a second of the player building its list of cards; a walk that
// went on through every source for word timing took three seconds and more, and the card never came.
// So the order is the priority, as it reads on the Lyrics page: a source further down is only asked
// when those above it had nothing timed, and then only for what they lacked.
#import "Core/SGCore.h"
#import "LyricsSources.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LocalFiles/LocalFiles.h"
#import "Shared/LocalFiles/LocalLyrics.h"
#import "Settings/SGSourcesPage.h"
#import "Settings/SGPageStyle.h"
#import "Headers/SPTPlayer.h"
#import <stdatomic.h>

static const NSTimeInterval kTimeout = 6;
static const NSUInteger kKeptTracks = 40;

// What the switches were called while Musixmatch was the only source; read once, to carry an
// existing install's settings over to the order.
static NSString *const kLegacyMusixmatch = @"spotifyglass.musixmatchLyrics";
static NSString *const kLegacyAllTracks = @"spotifyglass.musixmatchAllTracks";
static NSString *const kLegacyNetEase = @"spotifyglass.neteaseWordTiming";
static NSString *const kTrackProvidersKey = @"spotifyglass.lyrics.trackProviders";

@implementation SGLyricsLink
@end

@implementation SGLyricsResult
@end

@implementation SGLyricsQuery
@end

@implementation SGLyricsProvider
@end

#pragma mark - the requests the sources share

// Every request any source has lost to the network or to a server too busy to answer, counted so a
// walk can tell "no source has lyrics" from "a source could not say". Only the first is kept.
static _Atomic NSUInteger sg_failures;
static NSTimeInterval sg_rateLimitUntilTime = 0;
static NSTimeInterval sg_rateLimitRetryAfter = 0;

void SGLyricsNoteRateLimit(NSTimeInterval wait) {
    if (wait <= 0) wait = 15.0;
    if (wait > 120.0) wait = 120.0;
    NSTimeInterval until = CACurrentMediaTime() + wait;
    if (until > sg_rateLimitUntilTime) {
        sg_rateLimitUntilTime = until;
        sg_rateLimitRetryAfter = wait;
    }
}

NSTimeInterval SGLyricsCurrentRateLimitUntil(void) {
    return sg_rateLimitUntilTime;
}

NSTimeInterval SGLyricsCurrentRetryAfter(void) {
    return sg_rateLimitRetryAfter > 0 ? sg_rateLimitRetryAfter : 15.0;
}

BOOL SGLyricsReplyFailed(NSURLResponse *response, NSError *error) {
    NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
    return error || status == 429 || status >= 500;
}

void SGLyricsNoteReply(NSURLResponse *response, NSError *error) {
    if ([response isKindOfClass:NSHTTPURLResponse.class]) {
        NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
        if (status == 429) {
            NSString *retryHeader = ((NSHTTPURLResponse *)response).allHeaderFields[@"Retry-After"]
                ?: ((NSHTTPURLResponse *)response).allHeaderFields[@"retry-after"];
            NSTimeInterval wait = [retryHeader doubleValue] > 0 ? [retryHeader doubleValue] : 15.0;
            SGLyricsNoteRateLimit(wait);
        }
    }
    if (SGLyricsReplyFailed(response, error)) atomic_fetch_add(&sg_failures, 1);
}

NSURL *SGLyricsURL(NSString *base, NSDictionary<NSString *, NSString *> *query) {
    NSURLComponents *url = [NSURLComponents componentsWithString:base];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    [query enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        [items addObject:[NSURLQueryItem queryItemWithName:name value:value]];
    }];
    url.queryItems = items;
    return url.URL;
}

static NSMutableURLRequest *requestFor(NSURL *url, NSDictionary<NSString *, NSString *> *headers) {
    if (!url) return nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:kTimeout];
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        [request setValue:value forHTTPHeaderField:name];
    }];
    return request;
}

// The body whatever the status, and the reply it came with; nil for both when there was none.
static void sendForReplyWithRetry(NSURLRequest *request, NSUInteger retries, void (^done)(NSData *body, NSHTTPURLResponse *response)) {
    if (!request) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(nil, nil); });
        return;
    }
    NSURL *url = request.URL;
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *reply = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        SGLyricsNoteReply(response, error);
        if (reply.statusCode == 429) {
            NSString *retryHeader = reply.allHeaderFields[@"Retry-After"] ?: reply.allHeaderFields[@"retry-after"];
            NSTimeInterval wait = [retryHeader doubleValue] > 0 ? [retryHeader doubleValue] : 15.0;
            if (wait < 5.0) wait = 15.0;
            if (wait > 120.0) wait = 120.0;
            SGLyricsNoteRateLimit(wait);
            if (retries > 0) {
                SGLog(@"lyrics: rate limit on %@, waiting %.1fs to retry (%lu left)", url.host, wait, (unsigned long)retries);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                    sendForReplyWithRetry(request, retries - 1, done);
                });
                return;
            }
        }
        if (error || reply.statusCode >= 400) SGLog(@"lyrics: %@ answered %ld, error %@", url.host, (long)reply.statusCode, error);
        dispatch_async(dispatch_get_main_queue(), ^{ done(data, reply); });
    }] resume];
}

static void sendForReply(NSURLRequest *request, void (^done)(NSData *body, NSHTTPURLResponse *response)) {
    sendForReplyWithRetry(request, 3, done);
}

static void send(NSURLRequest *request, void (^done)(NSData *body)) {
    sendForReply(request, ^(NSData *body, NSHTTPURLResponse *reply) {
        done(reply.statusCode >= 400 ? nil : body);
    });
}

static id jsonIn(NSData *body) {
    return body.length ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : nil;
}

// A source may answer JSON null where a number should be; NSNull is not nil and does not answer
// doubleValue, and reading one straight off killed whole launches. Every unguarded number in a
// source's JSON goes through this.
NSInteger SGLyricsNumber(id value) {
    return [value respondsToSelector:@selector(doubleValue)] ? (NSInteger)[value doubleValue] : 0;
}

void SGLyricsGetJSON(NSURL *url, NSDictionary<NSString *, NSString *> *headers, void (^done)(id root)) {
    send(requestFor(url, headers), ^(NSData *body) {
        done(jsonIn(body));
    });
}

void SGLyricsGetJSONReply(NSURL *url, NSDictionary<NSString *, NSString *> *headers, void (^done)(id root, NSHTTPURLResponse *response)) {
    sendForReply(requestFor(url, headers), ^(NSData *body, NSHTTPURLResponse *reply) {
        done(jsonIn(body), reply);
    });
}

void SGLyricsGetText(NSURL *url, void (^done)(NSString *text)) {
    send(requestFor(url, nil), ^(NSData *body) {
        done(body.length ? [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] : nil);
    });
}

void SGLyricsPostJSON(NSURL *url, NSDictionary<NSString *, NSString *> *headers, id body, void (^done)(id root)) {
    NSData *written = [NSJSONSerialization isValidJSONObject:body]
        ? [NSJSONSerialization dataWithJSONObject:body options:0 error:nil] : nil;
    NSMutableURLRequest *request = written ? requestFor(url, headers) : nil;
    request.HTTPMethod = @"POST";
    request.HTTPBody = written;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    send(request, ^(NSData *answer) {
        done(jsonIn(answer));
    });
}

// A pause this long between two lines gets a ♪, so Spotify's page does not hold the last one.
static const NSInteger kBreakMs = 3000;

void SGLyricsPageLines(NSArray<SGKaraokeLine *> *lines, NSArray<NSNumber *> **starts, NSArray<NSString *> **texts) {
    NSMutableArray<NSNumber *> *at = [NSMutableArray array];
    NSMutableArray<NSString *> *said = [NSMutableArray array];
    SGKaraokeLine *last = nil;
    for (SGKaraokeLine *line in lines) {
        if (last && line.start - last.end >= kBreakMs) {
            [at addObject:@(last.end)];
            [said addObject:@"♪"];
        }
        NSString *text = SGKaraokeLineText(line);
        // The backing vocals read on the same line on Spotify's own page, which has one row a line.
        if (line.backing) text = [text stringByAppendingFormat:@" %@", SGKaraokeLineText(line.backing)];
        [at addObject:@(line.start)];
        [said addObject:text];
        last = line;
    }
    if (last) {
        [at addObject:@(last.end)];
        [said addObject:@""];
    }
    *starts = at;
    *texts = said;
}

#pragma mark - which sources there are, and in what order

NSArray<SGLyricsProvider *> *SGLyricsAllProviders(void) {
    static NSArray<SGLyricsProvider *> *all;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SGLyricsProvider *(^make)(NSString *, NSString *, NSString *, SGLyricsAsk) =
        ^(NSString *key, NSString *name, NSString *detail, SGLyricsAsk ask) {
            SGLyricsProvider *provider = [SGLyricsProvider new];
            provider.key = key;
            provider.name = name;
            provider.detail = detail;
            // A source that matches by Spotify's own track id has everything it needs from the
            // start; the rest wait for the player to name the track before they can search.
            provider.needsName = ![key isEqualToString:@"musixmatch"] && ![key isEqualToString:SGSpicyLyricsKey];
            provider.ask = ask;
            return provider;
        };
        all = @[
            make(@"binilyrics", @"BiniLyrics", @"Apple Music word timing", SGBiniLyricsAsk),
            make(@"musixmatch", @"Musixmatch", @"Spotify's licensed catalog", SGMusixmatchAsk),
            make(@"unison", @"Unison", @"Hand-timed, few tracks", SGUnisonAsk),
            make(@"netease", @"NetEase", @"Word timing, censored", SGNetEaseAsk),
            make(@"lrclib", @"LRCLIB", @"Line timing, open fallback", SGLrcLibAsk),
            make(SGSpicyLyricsKey, @"Spicy Lyrics", @"Community word syncs, your own key", SGSpicyLyricsAsk),
            make(@"qqmusic", @"QQ Music", @"Line timing, Chinese catalog", SGQQMusicAsk),
            make(@"kugou", @"KuGou", @"Word timing, Chinese catalog", SGKuGouAsk),
            make(SGImportedLRCKey, @"Imported LRC", @"Your own .lrc files", SGImportedLRCAsk),
        ];
    });
    return all;
}

SGLyricsProvider *SGLyricsProviderFor(NSString *key) {
    for (SGLyricsProvider *provider in SGLyricsAllProviders()) {
        if ([provider.key isEqualToString:key]) return provider;
    }
    return nil;
}

// An install from before the order existed keeps what it had: the sources it was using, in the only
// order there was. Nothing is switched on for it that it had not already asked for.
static NSArray<NSString *> *fromLegacyKeys(void) {
    if (!SGFlag(kLegacyMusixmatch, NO)) return @[];
    NSMutableArray<NSString *> *order = [NSMutableArray arrayWithObject:@"musixmatch"];
    if (SGFlag(kLegacyNetEase, NO)) [order addObject:@"netease"];
    return order;
}

// With nothing stored and nothing to carry over, every source is on: the user's own files first, word
// timing ahead of line timing, and the two Chinese catalogs last, asked only once the rest have missed.
// Spicy Lyrics passes straight on without its key.
static NSArray<NSString *> *defaultOrder(void) {
    return @[SGImportedLRCKey, SGSpicyLyricsKey, @"binilyrics", @"musixmatch", @"unison", @"netease", @"lrclib", @"qqmusic", @"kugou"];
}

NSArray<NSString *> *SGLyricsOrder(void) {
    id stored = [NSUserDefaults.standardUserDefaults arrayForKey:SGKeyLyricsProviders];
    NSArray *legacy = fromLegacyKeys();
    NSArray *keys = [stored isKindOfClass:NSArray.class] ? stored : legacy.count ? legacy : defaultOrder();
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (id key in keys) {
        if ([key isKindOfClass:NSString.class] && SGLyricsProviderFor(key) && ![order containsObject:key]) [order addObject:key];
    }
    return order;
}

void SGLyricsSetOrder(NSArray<NSString *> *keys) {
    [NSUserDefaults.standardUserDefaults setObject:keys ?: @[] forKey:SGKeyLyricsProviders];
}

// With EeveeSpotify injected, its own lyrics answer Spotify's requests and the mod's stand aside: two
// tweaks holding and answering the same request froze Spotify after launch.
BOOL SGLyricsEnabled(void) {
    return SGLyricsOrder().count > 0 && !SGLyricsStandAsideForEevee();
}

#pragma mark - what is known about the track

// The player knows every track it has played by name, which is what every source but Musixmatch
// searches by. The track is looked up by id rather than compared with the one playing now: a lyrics
static NSMutableDictionary<NSString *, NSDictionary *> *sg_trackInfoCache;

void SGLyricsRememberTrackInfo(NSString *trackID, NSString *title, NSString *artist, NSString *album, NSInteger seconds) {
    if (!trackID.length || !title.length) return;
    NSString *clean = [trackID stringByRemovingPercentEncoding] ?: trackID;
    if ([clean hasPrefix:@"spotify:track:"]) clean = [clean substringFromIndex:14];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sg_trackInfoCache = [NSMutableDictionary dictionary]; });
    @synchronized (sg_trackInfoCache) {
        if (sg_trackInfoCache.count >= 2000) [sg_trackInfoCache removeAllObjects];
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        dict[@"title"] = title;
        if (artist.length) dict[@"artist"] = artist;
        if (album.length) dict[@"album"] = album;
        if (seconds > 0) dict[@"seconds"] = @(seconds);
        sg_trackInfoCache[clean] = dict;
        sg_trackInfoCache[trackID] = dict;
    }
}

void SGLyricsResolveTrackName(NSString *trackID, void (^done)(NSString *title, NSString *artist, NSString *album, NSInteger seconds)) {
    if (!trackID.length) {
        done(nil, nil, nil, 0);
        return;
    }
    NSString *clean = [trackID stringByRemovingPercentEncoding] ?: trackID;
    if ([clean hasPrefix:@"spotify:track:"]) clean = [clean substringFromIndex:14];

    NSDictionary *cached = nil;
    @synchronized (sg_trackInfoCache) {
        cached = sg_trackInfoCache[clean] ?: sg_trackInfoCache[trackID];
    }
    if (cached[@"title"]) {
        done(cached[@"title"], cached[@"artist"], cached[@"album"], [cached[@"seconds"] integerValue]);
        return;
    }

    SPTPlayerTrack *playerTrack = SGKaraokeTrackFor(clean) ?: SGKaraokeTrackFor(trackID);
    if (playerTrack.trackTitle.length) {
        NSString *title = playerTrack.trackTitle;
        NSString *artist = playerTrack.artistName;
        NSString *album = [playerTrack.metadata[@"album_title"] isKindOfClass:NSString.class] ? playerTrack.metadata[@"album_title"] : nil;
        NSInteger secs = [playerTrack.metadata[@"duration"] respondsToSelector:@selector(integerValue)] ? [playerTrack.metadata[@"duration"] integerValue] / 1000 : 0;
        SGLyricsRememberTrackInfo(clean, title, artist, album, secs);
        done(title, artist, album, secs);
        return;
    }

    SGSpclientHeaders(^(NSDictionary<NSString *, NSString *> *headers) {
        NSString *auth = headers[@"authorization"];
        if (!auth.length || !clean.length) {
            done(nil, nil, nil, 0);
            return;
        }
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.spotify.com/v1/tracks/%@", clean]];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:3.0];
        [req setValue:auth forHTTPHeaderField:@"Authorization"];
        [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if ([data isKindOfClass:NSData.class] && data.length) {
                NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([root isKindOfClass:NSDictionary.class]) {
                    NSString *name = root[@"name"];
                    NSArray *artists = root[@"artists"];
                    NSString *artistName = [artists isKindOfClass:NSArray.class] && artists.count ? artists[0][@"name"] : nil;
                    NSString *albumName = [root[@"album"] isKindOfClass:NSDictionary.class] ? root[@"album"][@"name"] : nil;
                    NSInteger duration = [root[@"duration_ms"] integerValue] / 1000;
                    if (name.length) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            SGLyricsRememberTrackInfo(clean, name, artistName, albumName, duration);
                            done(name, artistName, albumName, duration);
                        });
                        return;
                    }
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                done(nil, nil, nil, 0);
            });
        }] resume];
    });
}

// request often lands a beat before the player moves on to its track, and comparing then left the
// query nameless. A track the player has not reported starts with nothing, and the first source
// that matches by id fills the rest in.
static SGLyricsQuery *queryFor(NSString *trackID) {
    SGLyricsQuery *query = [SGLyricsQuery new];
    query.trackID = trackID;
    NSString *clean = [trackID stringByRemovingPercentEncoding] ?: trackID;
    if ([clean hasPrefix:@"spotify:track:"]) clean = [clean substringFromIndex:14];
    NSDictionary *local = SGLocalFileInfo(trackID) ?: SGLocalFileInfo(clean);
    if (local) {
        query.title = local[@"title"];
        query.artist = local[@"artist"];
        query.album = local[@"album"];
        query.seconds = [local[@"seconds"] integerValue];
        return query;
    }
    @synchronized (sg_trackInfoCache) {
        NSDictionary *cached = sg_trackInfoCache[clean] ?: sg_trackInfoCache[trackID];
        if (cached[@"title"]) {
            query.title = cached[@"title"];
            query.artist = cached[@"artist"];
            query.album = cached[@"album"];
            query.seconds = [cached[@"seconds"] integerValue];
            return query;
        }
    }
    SPTPlayerTrack *track = SGKaraokeTrackFor(clean) ?: SGKaraokeTrackFor(trackID);
    if (!track) return query;
    query.title = track.trackTitle;
    query.artist = track.artistName;
    NSDictionary<NSString *, NSString *> *metadata = track.metadata;
    id album = metadata[@"album_title"];
    id length = metadata[@"duration"];
    if ([album isKindOfClass:NSString.class]) query.album = album;
    if ([length respondsToSelector:@selector(integerValue)]) query.seconds = [length integerValue] / 1000;
    return query;
}

static void learnFrom(SGLyricsQuery *query, SGLyricsResult *result) {
    if (!query.title.length && result.title.length) query.title = result.title;
    if (!query.artist.length && result.artist.length) query.artist = result.artist;
    if (!query.album.length && result.album.length) query.album = result.album;
    if (query.seconds <= 0 && result.seconds > 0) query.seconds = result.seconds;
    if (query.trackID.length && query.title.length) {
        SGLyricsRememberTrackInfo(query.trackID, query.title, query.artist, query.album, query.seconds);
    }
}

#pragma mark - the walk

// Main queue only, except sg_missing and sg_credits.
static NSMutableDictionary<NSString *, id> *sg_kept;
static NSMutableDictionary<NSString *, NSMutableArray *> *sg_waiting;
static NSMutableSet<NSString *> *sg_missing;
static NSMutableDictionary<NSString *, NSString *> *sg_credits;
// Spotify's own has_lyrics per track, as its metadata said. The player's metadata is read many
// times a second while a list scrolls, so a value already noted costs one lookup and no write.
static NSMutableDictionary<NSString *, NSNumber *> *sg_spotifyHas;
static NSMutableDictionary<NSString *, NSNumber *> *sg_generation;
static const NSUInteger kNotedTracks = 200;

static void setUp(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_kept = [NSMutableDictionary dictionary];
        sg_waiting = [NSMutableDictionary dictionary];
        sg_missing = [NSMutableSet set];
        sg_credits = [NSMutableDictionary dictionary];
        sg_spotifyHas = [NSMutableDictionary dictionary];
        sg_generation = [NSMutableDictionary dictionary];
    });
}

NSString *SGLyricsProviderForTrack(NSString *trackID) {
    if (!trackID.length) return nil;
    NSString *key = [NSUserDefaults.standardUserDefaults dictionaryForKey:kTrackProvidersKey][trackID];
    return SGLyricsProviderFor(key) ? key : nil;
}

void SGLyricsForgetTrack(NSString *trackID) {
    if (!trackID.length) return;
    NSString *clean = [trackID stringByRemovingPercentEncoding] ?: trackID;
    if ([clean hasPrefix:@"spotify:track:"]) clean = [clean substringFromIndex:14];
    dispatch_async(dispatch_get_main_queue(), ^{
        setUp();
        sg_generation[trackID] = @(sg_generation[trackID].unsignedIntegerValue + 1);
        sg_generation[clean] = @(sg_generation[clean].unsignedIntegerValue + 1);
        [sg_kept removeObjectForKey:trackID];
        [sg_kept removeObjectForKey:clean];
        [sg_missing removeObject:trackID];
        [sg_missing removeObject:clean];
        [sg_waiting removeObjectForKey:trackID];
        [sg_waiting removeObjectForKey:clean];
    });
}

void SGLyricsSetProviderForTrack(NSString *trackID, NSString *providerKey) {
    if (!trackID.length || (providerKey.length && !SGLyricsProviderFor(providerKey))) {
        SGLog(@"lyrics: ignored invalid per-track source for %@", trackID ?: @"(no track)");
        return;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary<NSString *, NSString *> *providers = [[defaults dictionaryForKey:kTrackProvidersKey] mutableCopy]
        ?: [NSMutableDictionary dictionary];
    if (providerKey.length) providers[trackID] = providerKey;
    else [providers removeObjectForKey:trackID];
    if (providers.count) [defaults setObject:providers forKey:kTrackProvidersKey];
    else [defaults removeObjectForKey:kTrackProvidersKey];
    SGLyricsForgetTrack(trackID);
}

// Whether the source's lines are better than what the walk already has: any lines beat none, and
// finer timing beats coarser — words timed beat a line's start, which beats plain text. Read off the
// lines themselves, which say how they were really timed, rather than off what the source claimed.
static BOOL betterLines(SGLyricsResult *merged, SGLyricsResult *fresh) {
    if (!fresh.karaokeLines.count) return NO;
    return !merged.karaokeLines.count || SGKaraokeLinesTiming(fresh.karaokeLines) < SGKaraokeLinesTiming(merged.karaokeLines);
}

static NSString *timingName(NSArray<SGKaraokeLine *> *lines) {
    switch (SGKaraokeLinesTiming(lines)) {
        case SGKaraokeTimingWords: return @"word timed";
        case SGKaraokeTimingLine: return @"line timed";
        default: return @"untimed";
    }
}

// The same for the text Spotify's own page shows: any text beats none, timed beats untimed.
static BOOL betterTexts(SGLyricsResult *merged, SGLyricsResult *fresh) {
    if (!fresh.texts.count) return NO;
    return !merged.texts.count || (fresh.synced && !merged.synced);
}

// How long a lyrics request waits for the player to name its track before the walk starts without a
// name. The request routinely lands a few hundred milliseconds before the player reports the track
// it belongs to, and a walk started in that gap passes over every source that searches by name.
static const NSTimeInterval kNameWait = 1.5, kNamePoll = 0.1;

static BOOL named(SGLyricsQuery *query) {
    return query.title.length && query.artist.length;
}

// The credits that carry links or must show, by their text, as their sources answered. Main queue.
static NSMutableDictionary<NSString *, SGLyricsResult *> *sg_noted;
static const NSUInteger kNotedCredits = 100;

static void noteCredit(SGLyricsResult *result) {
    if (!result.provider.length || !(result.creditRequired || result.creditLinks.count)) return;
    if (!sg_noted) sg_noted = [NSMutableDictionary dictionary];
    if (sg_noted.count >= kNotedCredits) [sg_noted removeAllObjects];
    sg_noted[result.provider] = result;
}

BOOL SGLyricsCreditRequired(NSString *credit) {
    return credit && sg_noted[credit].creditRequired;
}

NSArray<SGLyricsLink *> *SGLyricsCreditLinks(NSString *text) {
    if (!text.length) return nil;
    SGLyricsResult *exact = sg_noted[text];
    if (exact) return exact.creditLinks;
    // The longest credit the text holds, so "Spicy Lyrics, synced by a" is not read as a shorter one.
    SGLyricsResult *found = nil;
    for (NSString *credit in sg_noted) {
        if ([text containsString:credit] && credit.length > found.provider.length) found = sg_noted[credit];
    }
    return found.creditLinks;
}

void SGLyricsOpenCreditLinks(NSArray<SGLyricsLink *> *links, UIView *from) {
    if (!links.count) return;
    if (links.count == 1) {
        [UIApplication.sharedApplication openURL:links.firstObject.url options:@{} completionHandler:nil];
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (SGLyricsLink *link in links) {
        NSURL *url = link.url;
        [sheet addAction:[UIAlertAction actionWithTitle:link.title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = from;
    sheet.popoverPresentationController.sourceRect = from.bounds;
    [SGTopController() presentViewController:sheet animated:YES completion:nil];
}

// One walk down the order for one track.
@interface SGLyricsWalk : NSObject
@property (nonatomic, copy) NSArray<NSString *> *order;
@property (nonatomic) NSUInteger index;
@property (nonatomic) NSUInteger generation;
@property (nonatomic, strong) SGLyricsQuery *query;
@property (nonatomic, strong) SGLyricsResult *merged;
// Sources that needed a name the query did not have when their turn came.
@property (nonatomic, strong) NSMutableArray<NSString *> *passedOver;
// sg_failures when the walk started. Another walk's failure counts too, which at worst asks again.
@property (nonatomic) NSUInteger failuresAtStart;
@property (nonatomic) NSTimeInterval rateLimitRecordedAtStart;
@end

@implementation SGLyricsWalk
@end

// Musixmatch's community translations are not waited for here: the lines take them as they are kept
// for the lyrics view (Shared/Lyrics/KaraokeSource.x), whichever source won, Spotify included.
static void finish(SGLyricsWalk *walk) {
    if (walk.generation != sg_generation[walk.query.trackID].unsignedIntegerValue) return;
    SGLyricsQuery *query = walk.query;
    SGLyricsResult *merged = walk.merged;
    NSString *trackID = query.trackID;
    if (SGLyricsCurrentRateLimitUntil() > walk.rateLimitRecordedAtStart) {
        merged.rateLimited = YES;
        merged.retryAfter = MAX(merged.retryAfter, SGLyricsCurrentRetryAfter());
    }
    if (merged.karaokeLines.count && !merged.texts.count) {
        NSArray<NSNumber *> *starts = nil;
        NSArray<NSString *> *texts = nil;
        SGLyricsPageLines(merged.karaokeLines, &starts, &texts);
        merged.starts = starts;
        merged.texts = texts;
        if (SGKaraokeLinesTiming(merged.karaokeLines) != SGKaraokeTimingNone) {
            merged.synced = YES;
        }
    }
    SGLyricsResult *lyrics = merged.karaokeLines.count || merged.texts.count ? merged : nil;
    // A walk that ends with nothing is only an answer when every source got to search. One that passed a
    // source over for want of a name asked it nothing, and keeping that as "no lyrics" would stick to the
    // track: every later request would get the kept nil, and the lyrics card would be taken off the track
    // for the rest of the session. The same goes for a walk during which a request failed: a busy
    // server's 503 read as "no lyrics" hid a track's lyrics until Spotify was restarted.
    BOOL everyoneAsked = !walk.passedOver.count;
    BOOL failed = (atomic_load(&sg_failures) != walk.failuresAtStart) || merged.rateLimited;
    if (lyrics || (everyoneAsked && !failed) || merged.instrumental) {
        if (sg_kept.count >= kKeptTracks) [sg_kept removeAllObjects];
        sg_kept[trackID] = lyrics ?: NSNull.null;
        if (!lyrics) {
            @synchronized (sg_missing) { [sg_missing addObject:trackID]; }
        }
    }
    SGLog(@"lyrics: %@ ends with %@", trackID, lyrics
          ? [NSString stringWithFormat:@"%lu %@ lines from %@, %lu page lines",
             (unsigned long)lyrics.karaokeLines.count, timingName(lyrics.karaokeLines),
             lyrics.provider, (unsigned long)lyrics.texts.count]
          : everyoneAsked && failed ? (merged.rateLimited ? @"rate limit encountered; not kept" : @"nothing, a request failed on the way; not kept, so the next request asks again")
          : everyoneAsked ? @"nothing"
          : [NSString stringWithFormat:@"nothing, %@ never knowing its name; not kept, so the next request asks again",
             [walk.passedOver componentsJoinedByString:@", "]]);
    NSArray *waiting = sg_waiting[trackID];
    [sg_waiting removeObjectForKey:trackID];
    for (void (^done)(SGLyricsResult *) in waiting) done(lyrics ?: (merged.rateLimited ? merged : nil));
}

static void step(SGLyricsWalk *walk) {
    if (walk.generation != sg_generation[walk.query.trackID].unsignedIntegerValue) return;
    SGLyricsQuery *query = walk.query;
    SGLyricsResult *merged = walk.merged;
    if (merged.synced && merged.texts.count && merged.karaokeLines.count) {
        finish(walk);
        return;
    }
    if (walk.index >= walk.order.count) {
        if (walk.passedOver.count && named(query)) {
            SGLog(@"lyrics: %@ named partway as \"%@\" by \"%@\", asking %@ after all", query.trackID,
                  query.title, query.artist, [walk.passedOver componentsJoinedByString:@", "]);
            walk.order = walk.passedOver;
            walk.index = 0;
            walk.passedOver = [NSMutableArray array];
            step(walk);
            return;
        }
        finish(walk);
        return;
    }
    SGLyricsProvider *provider = SGLyricsProviderFor(walk.order[walk.index++]);
    BOOL needsName = provider.needsName;
    if ([provider.key isEqualToString:SGImportedLRCKey] && SGImportedLRCLinkedTo(query.trackID)) {
        needsName = NO;
    }
    if (needsName && !named(query)) {
        [walk.passedOver addObject:provider.key];
        step(walk);
        return;
    }
    provider.ask(query, ^(SGLyricsResult *fresh) {
        if (walk.generation != sg_generation[query.trackID].unsignedIntegerValue) return;
        if (fresh.rateLimited) {
            merged.rateLimited = YES;
            merged.retryAfter = MAX(merged.retryAfter, fresh.retryAfter > 0 ? fresh.retryAfter : 15.0);
        }
        learnFrom(query, fresh);
        noteCredit(fresh);
        if (walk.passedOver.count && named(query)) {
            walk.order = [walk.passedOver arrayByAddingObjectsFromArray:[walk.order subarrayWithRange:NSMakeRange(walk.index, walk.order.count - walk.index)]];
            walk.index = 0;
            walk.passedOver = [NSMutableArray array];
        }
        if (fresh.instrumental) {
            SGLog(@"lyrics: %@ is instrumental, by %@", query.trackID, provider.key);
            merged.instrumental = YES;
            finish(walk);
            return;
        }
        if (betterLines(merged, fresh)) {
            merged.karaokeLines = fresh.karaokeLines;
            merged.wordTimed = fresh.wordTimed || (SGKaraokeLinesTiming(fresh.karaokeLines) == SGKaraokeTimingWords);
            merged.provider = fresh.provider ?: provider.name;
            if (fresh.texts.count) {
                merged.starts = fresh.starts;
                merged.texts = fresh.texts;
                merged.synced = fresh.synced;
                merged.pageProvider = fresh.provider ?: provider.name;
            }
        }
        if (betterTexts(merged, fresh)) {
            merged.starts = fresh.starts;
            merged.texts = fresh.texts;
            merged.synced = fresh.synced;
            if (!merged.provider) merged.provider = fresh.provider ?: provider.name;
            merged.pageProvider = fresh.provider ?: provider.name;
        }
        step(walk);
    });
}

static void startWalk(NSString *trackID, SGLyricsQuery *query) {
    NSString *selected = SGLyricsProviderForTrack(trackID);
    NSArray<NSString *> *order = selected ? @[selected] : SGLyricsOrder();
    SGLog(@"lyrics: asking %@ for %@ as \"%@\" by \"%@\", album \"%@\", %lds",
          [order componentsJoinedByString:@", "], trackID, query.title, query.artist, query.album, (long)query.seconds);
    SGLyricsWalk *walk = [SGLyricsWalk new];
    walk.order = order;
    walk.generation = sg_generation[trackID].unsignedIntegerValue;
    walk.query = query;
    walk.merged = [SGLyricsResult new];
    walk.passedOver = [NSMutableArray array];
    walk.failuresAtStart = atomic_load(&sg_failures);
    walk.rateLimitRecordedAtStart = sg_rateLimitUntilTime;
    step(walk);
}

// Starts the walk as soon as the player has named the track, or once it has waited long enough
// that it is not going to: a track opened for something other than what is playing is never named.
static void whenNamed(NSString *trackID, NSTimeInterval waited) {
    SGLyricsQuery *query = queryFor(trackID);
    NSString *playing = SGKaraokePlayingTrack();
    BOOL isPlayingTrack = playing && [trackID isEqualToString:playing];
    if (named(query)) {
        startWalk(trackID, query);
        return;
    }
    if (isPlayingTrack && waited < kNameWait) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kNamePoll * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            whenNamed(trackID, waited + kNamePoll);
        });
        return;
    }
    SGLyricsResolveTrackName(trackID, ^(NSString *title, NSString *artist, NSString *album, NSInteger seconds) {
        if (title.length) {
            query.title = title;
            if (artist.length) query.artist = artist;
            if (album.length) query.album = album;
            if (seconds > 0) query.seconds = seconds;
        }
        startWalk(trackID, query);
    });
}

void SGLyricsFetch(NSString *trackID, void (^done)(SGLyricsResult *result)) {
    setUp();
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!trackID.length) {
            done(nil);
            return;
        }
        id kept = sg_kept[trackID];
        if (kept) {
            done(kept == NSNull.null ? nil : kept);
            return;
        }
        NSMutableArray *waiting = sg_waiting[trackID];
        if (waiting) {
            [waiting addObject:[done copy]];
            return;
        }
        sg_waiting[trackID] = [NSMutableArray arrayWithObject:[done copy]];
        whenNamed(trackID, 0);
    });
}

BOOL SGLyricsMayHave(NSString *trackID) {
    setUp();
    @synchronized (sg_missing) { return ![sg_missing containsObject:trackID]; }
}

void SGLyricsPrefetch(NSString *trackID) {
    if (!trackID.length) return;
    SGLyricsFetch(trackID, ^(SGLyricsResult *result) {});
}

NSInteger SGLyricsSpotifyHas(NSString *trackID) {
    setUp();
    if (!trackID) return -1;
    @synchronized (sg_spotifyHas) {
        NSNumber *has = sg_spotifyHas[trackID];
        return has ? has.integerValue : -1;
    }
}

void SGLyricsNoteSpotifyHas(NSString *trackID, BOOL has) {
    setUp();
    if (!trackID.length) return;
    @synchronized (sg_spotifyHas) {
        NSNumber *noted = sg_spotifyHas[trackID];
        if (noted && noted.boolValue == has) return;
        if (sg_spotifyHas.count >= kNotedTracks) [sg_spotifyHas removeAllObjects];
        sg_spotifyHas[trackID] = @(has);
    }
}

NSString *const SGLyricsOwnRequestKey = @"spotifyglass.ownRequest";

// The cards under the player load together, and the list is shown without any card still loading
// once this many milliseconds have passed (NowPlaying_ScrollImpl's scrollCardsAsyncLoadingTimeoutMs,
// 2 s unless the server says otherwise, 1 s at the least). The lyrics card is one of them and waits
// for the color-lyrics reply, which with a source of the mod's on comes after the chain has answered;
// so the wait is set to the most the flag allows.
id SGLyricsForcedFlag(NSString *key) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ on = SGLyricsEnabled(); });
    if (!on) return nil;
    if ([key isEqualToString:@"ios-nowplaying-scroll-impl.scroll_cards_async_loading_timeout_ms"]) return @5000;
    return nil;
}

// After an override; no row shows the timeout, so nothing is locked.
__attribute__((constructor)) static void registerForcer(void) {
    SGRegisterFlagForcer(NO, ^id(NSString *key) { return SGLyricsForcedFlag(key); }, nil);
}

#pragma mark - the language of translations

NSArray<NSString *> *SGLyricsTranslationLanguages(void) {
    return @[@"", @"ar", @"zh-Hans", @"zh-Hant", @"cs", @"da", @"nl", @"en", @"fi", @"fr", @"de", @"el", @"he",
             @"hi", @"hu", @"id", @"it", @"ja", @"ko", @"nb", @"pl", @"pt", @"ro", @"ru", @"sk", @"es", @"sv",
             @"th", @"tr", @"uk", @"vi"];
}

NSArray<NSString *> *SGLyricsTranslationLanguageNames(void) {
    NSLocale *english = [NSLocale localeWithLocaleIdentifier:@"en"];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *tag in SGLyricsTranslationLanguages()) {
        [names addObject:tag.length ? [english localizedStringForLocaleIdentifier:tag] ?: tag : @"Any · iPhone's language"];
    }
    return names;
}

NSString *SGLyricsTranslationLanguage(void) {
    NSArray<NSString *> *tags = SGLyricsTranslationLanguages();
    NSInteger index = SGInt(SGKeyLyricsTranslationLanguage, 0);
    return index > 0 && index < (NSInteger)tags.count ? tags[(NSUInteger)index] : nil;
}

NSString *SGLyricsCreditFor(NSString *trackID) {
    setUp();
    if (!trackID.length) return @"Spotify";
    NSString *clean = [trackID stringByRemovingPercentEncoding] ?: trackID;
    if ([clean hasPrefix:@"spotify:track:"]) clean = [clean substringFromIndex:14];
    @synchronized (sg_credits) {
        NSString *c = sg_credits[trackID] ?: sg_credits[clean];
        if (c.length) return c;
    }
    NSString *base = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"spoti.pw/Lyrics"];
    NSString *filePath = [[base stringByAppendingPathComponent:clean] stringByAppendingPathExtension:@"json"];
    NSData *data = [NSData dataWithContentsOfFile:filePath];
    if (data.length) {
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *credit = dict[@"credit"] ?: dict[@"source"] ?: dict[@"provider"];
        if (credit.length) {
            @synchronized (sg_credits) { sg_credits[clean] = credit; }
            return credit;
        }
    }
    return @"Spotify";
}

void SGLyricsSetCredit(NSString *trackID, NSString *name) {
    setUp();
    if (!trackID.length) return;
    NSString *clean = [trackID stringByRemovingPercentEncoding] ?: trackID;
    if ([clean hasPrefix:@"spotify:track:"]) clean = [clean substringFromIndex:14];
    NSString *val = name.length ? name : @"Spotify";
    @synchronized (sg_credits) {
        if (sg_credits.count >= 2000) [sg_credits removeAllObjects];
        sg_credits[trackID] = val;
        sg_credits[clean] = val;
    }
}

// Once, at launch: the keys Musixmatch owned alone become an order, so the Lyrics page opens on what
// the install was already doing rather than on nothing.
void SGLyricsMigrateLegacyKeys(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:SGKeyLyricsProviders]) return;
    NSArray<NSString *> *order = fromLegacyKeys();
    if (!order.count) return;
    SGLyricsSetOrder(order);
    SGSetEnabled(SGKeyLyricsAllTracks, SGFlag(kLegacyAllTracks, NO));
    SGLog(@"lyrics: carried the Musixmatch switches over as %@", [order componentsJoinedByString:@", "]);
}
