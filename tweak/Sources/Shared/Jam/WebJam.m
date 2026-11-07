// Web Jam's listener: Network.framework's TCP listener on port 8787, a minimal
// HTTP/1.1 surface (GET /, GET /state, POST /add) and the oEmbed lookup that
// turns a guest's track id into a queue entry. Every browser read is marshalled
// to the main thread, where the hub and Spotify's player are read and changed.
#import "WebJam.h"
#import "WebJamRules.h"
#import "WebJamAudio.h"
#include <math.h>
#import "Core/SGLog.h"
#import "Core/SGPrefs.h"
#import "LocalJam.h"
#import "Shared/Player/PlayerState.h"
#import <Network/Network.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <string.h>
#include <stdatomic.h>

NSNotificationName SGWebJamDidChangeNotification = @"spotifyglass.jam.web.changed";

static NSString *sg_status;
static BOOL sg_ready, sg_ownsHosting;
static NSString *sg_sessionID, *sg_lastTrack;
static NSDictionary *sg_lastNow;
static NSMutableArray<NSDictionary *> *sg_recent;
static NSMutableDictionary<NSString *, NSDictionary *> *sg_guests;
static const NSUInteger kHeaderCap = 8192, kBodyCap = 4096;
static const NSInteger kQueueCap = 100;

BOOL SGWebJamEnabled(void) {
    return SGFlag(SGKeyWebJam, NO);
}

static void setStatus(NSString *status) {
    status = status ?: @"";
    if ([sg_status isEqualToString:status]) return;
    sg_status = [status copy];
    SGLog(@"web jam: %@", status);
    [NSNotificationCenter.defaultCenter postNotificationName:SGWebJamDidChangeNotification object:nil];
}

NSString *SGWebJamStatus(void) {
    return sg_status ?: @"Off";
}

// iPhone Wi-Fi is en0; a shared address on another interface is not one a guest
// can open in a browser.
static NSString *wifiAddress(void) {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) return nil;
    NSString *address = nil;
    for (struct ifaddrs *at = interfaces; at; at = at->ifa_next) {
        if (!at->ifa_addr || at->ifa_addr->sa_family != AF_INET || !at->ifa_name) continue;
        if (strcmp(at->ifa_name, "en0") != 0) continue;
        char text[INET_ADDRSTRLEN] = {0};
        struct sockaddr_in *v4 = (struct sockaddr_in *)at->ifa_addr;
        if (!inet_ntop(AF_INET, &v4->sin_addr, text, sizeof text)) continue;
        NSString *candidate = [NSString stringWithUTF8String:text];
        if (!candidate.length || [candidate hasPrefix:@"127."] || [candidate hasPrefix:@"169.254."]) continue;
        address = candidate;
        break;
    }
    freeifaddrs(interfaces);
    return address;
}

NSString *SGWebJamJoinURL(void) {
    if (!sg_ready) return nil;
    NSString *address = wifiAddress();
    return address ? [NSString stringWithFormat:@"http://%@:%d", address, SGWebJamPort] : nil;
}

BOOL SGWebJamRunning(void) { return sg_ready; }

#pragma mark - State

static NSString *boundedText(id value) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *text = value;
    return text.length > 256 ? [text substringWithRange:[text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 256)]] : text;
}

static NSDictionary *webEntry(SGLocalJamEntry *entry) {
    BOOL playlist = [entry.uri hasPrefix:@"spotify:playlist:"];
    return @{@"id": entry.requestID ?: entry.uri ?: @"", @"uri": entry.uri ?: @"",
        @"title": boundedText(entry.title), @"artist": boundedText(entry.artist),
        @"by": boundedText(entry.addedBy ?: @"Guest"), @"kind": playlist ? @"playlist" : @"track",
        @"status": entry.requestStatus ?: @"Queued"};
}

static void observePlayback(void) {
    SPTPlayerState *at = SGPlayerState();
    NSString *uri = SGURIString(at.track.URI) ?: @"";
    BOOL playing = at && at.isPlaying && !at.isPaused;
    double position = at.isPaused ? at.positionAsOfTimestamp : at.position;
    SGWebJamAudioUpdate(playing, uri, position);
    if (uri.length && ![uri isEqual:sg_lastTrack]) {
        if (sg_lastNow) {
            [sg_recent insertObject:sg_lastNow atIndex:0];
            if (sg_recent.count > 30) [sg_recent removeLastObject];
        }
        sg_lastTrack = uri;
    }
    if (uri.length) sg_lastNow = @{@"uri": uri, @"title": boundedText(at.track.trackTitle),
        @"artist": boundedText(at.track.artistName), @"art": SGWebJamCoverURL(at.track.metadata) ?: @""};
}

static void noteGuest(NSURLComponents *parts) {
    NSString *identifier, *name;
    BOOL listening = NO;
    for (NSURLQueryItem *item in parts.queryItems) {
        if ([item.name isEqual:@"guest"]) identifier = item.value;
        else if ([item.name isEqual:@"name"]) name = item.value;
        else if ([item.name isEqual:@"listening"]) listening = [item.value isEqual:@"1"];
    }
    if (identifier.length < 12 || identifier.length > 64 || [identifier rangeOfCharacterFromSet:
        [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-"].invertedSet].location != NSNotFound) return;
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    for (NSString *key in sg_guests.allKeys)
        if (now - [sg_guests[key][@"seen"] doubleValue] > 15) [sg_guests removeObjectForKey:key];
    if (sg_guests.count >= 64 && !sg_guests[identifier]) return;
    sg_guests[identifier] = @{@"name": SGWebJamDisplayName(name), @"seen": @(now), @"listening": @(listening)};
}

static NSString *stateJSON(void) {
    observePlayback();
    SPTPlayerState *at = SGPlayerState();
    SGLocalJamHub *hub = SGLocalJamHubShared();
    NSMutableArray *queue = [NSMutableArray array], *requests = [NSMutableArray array], *guests = [NSMutableArray array];
    for (SGLocalJamEntry *entry in hub.queue) [queue addObject:webEntry(entry)];
    for (SGLocalJamEntry *entry in hub.webHistory) [requests addObject:webEntry(entry)];
    for (NSDictionary *guest in sg_guests.allValues)
        if (NSDate.timeIntervalSinceReferenceDate - [guest[@"seen"] doubleValue] <= 15)
            [guests addObject:@{@"name": guest[@"name"], @"listening": guest[@"listening"]}];
    double position = at.isPaused ? at.positionAsOfTimestamp : at.position;
    double duration = at.duration, speed = at.playbackSpeed;
    NSDictionary *json = @{@"session": sg_sessionID ?: @"", @"playing": @(at && at.isPlaying && !at.isPaused),
        @"position": @(isfinite(position) ? MAX(0, position) : 0),
        @"duration": @(isfinite(duration) ? MAX(0, duration) : 0),
        @"speed": @(isfinite(speed) && speed > 0 && speed <= 4 ? speed : 1),
        @"now": sg_lastNow ?: @{}, @"count": @(queue.count), @"queue": queue,
        @"requests": requests, @"recent": sg_recent ?: @[], @"guests": guests,
        @"status": boundedText(hub.status), @"audio": SGWebJamAudioStatus()};
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}

#pragma mark - The HTTP connection

@class SGWebJamHTTP;

@interface SGWebJamServer : NSObject
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, assign) BOOL enabled;    // main thread
@property (nonatomic, assign) BOOL wanted;     // listener queue
@property (nonatomic, assign) BOOL listening;  // listener queue
@property (nonatomic, strong) nw_listener_t listener;
@property (nonatomic, strong) NSMutableSet<SGWebJamHTTP *> *connections;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *resolved;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSURLSessionDataTask *> *resolving;
@property (nonatomic, strong) NSTimer *ticker;
@property (nonatomic, strong) id hubObserver;
@property (atomic, assign) NSUInteger generation;   // a stopped listener's late callbacks are ignored
- (void)start;
- (void)stop;
- (void)finished:(SGWebJamHTTP *)http;
- (void)resolveURI:(NSString *)uri completion:(void (^)(NSString *title, NSString *artist))done;
@end

static SGWebJamServer *sg_server;

static SGWebJamServer *sharedServer(void) {
    if (!sg_server) sg_server = [SGWebJamServer new];
    return sg_server;
}

@interface SGWebJamHTTP : NSObject
- (instancetype)initWithConnection:(nw_connection_t)connection
                             queue:(dispatch_queue_t)queue
                            server:(SGWebJamServer *)server;
- (void)begin;
- (void)cancel;
@end

@implementation SGWebJamHTTP {
    nw_connection_t _connection;
    dispatch_queue_t _queue;
    __weak SGWebJamServer *_server;
    NSMutableData *_buffer;
    BOOL _finished, _reading, _parsedHeaders, _routed;
    _Atomic BOOL _rejected;
    NSUInteger _generation;
    NSUInteger _headerEnd;
    NSInteger _contentLength;
    NSString *_method, *_path, *_contentType, *_requester;
}

- (instancetype)initWithConnection:(nw_connection_t)connection
                             queue:(dispatch_queue_t)queue
                            server:(SGWebJamServer *)server {
    if (!(self = [super init])) return nil;
    _connection = connection;
    _queue = queue;
    _server = server;
    _generation = server.generation;
    _buffer = [NSMutableData new];
    return self;
}

- (void)begin {
    dispatch_queue_t queue = _queue;
    __weak SGWebJamHTTP *weakSelf = self;
    nw_connection_set_queue(_connection, queue);
    nw_connection_set_state_changed_handler(_connection, ^(nw_connection_state_t state, nw_error_t error) {
        (void)error;
        if (state != nw_connection_state_failed && state != nw_connection_state_cancelled) return;
        dispatch_async(queue, ^{ [weakSelf connectionEnded]; });
    });
    nw_connection_start(_connection);
    [self receiveMore];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), queue, ^{
        [weakSelf timeOut];
    });
}

- (void)connectionEnded {
    if (_finished) return;
    _rejected = YES;
    _finished = YES;
    [_server finished:self];
}

- (void)timeOut {
    if (_finished) { [self cancel]; return; }
    [self sendError:408 message:@"Request timed out."];
}

- (void)cancel {
    _rejected = YES;
    _finished = YES;
    nw_connection_cancel(_connection);
    [_server finished:self];
}

- (void)receiveMore {
    if (_finished || _reading) return;
    _reading = YES;
    dispatch_queue_t queue = _queue;
    __weak SGWebJamHTTP *weakSelf = self;
    nw_connection_receive(_connection, 1, 4096, ^(dispatch_data_t content,
        nw_content_context_t context, bool is_complete, nw_error_t error) {
        (void)context;
        NSMutableData *chunk = [NSMutableData data];
        if (content) dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset,
            const void *bytes, size_t size) {
            (void)region; (void)offset;
            [chunk appendBytes:bytes length:size];
            return true;
        });
        dispatch_async(queue, ^{
            SGWebJamHTTP *strong = weakSelf;
            if (!strong) return;
            strong->_reading = NO;
            [strong consume:chunk complete:is_complete error:error];
        });
    });
}

- (void)consume:(NSData *)chunk complete:(BOOL)complete error:(nw_error_t)error {
    if (_finished) return;
    if (error) { [self cancel]; return; }
    [_buffer appendData:chunk];
    [self parse];
    if (_finished || _rejected || _routed) return;
    if (complete) { [self sendError:400 message:@"Incomplete request."]; return; }
    [self receiveMore];
}

- (void)parse {
    if (_routed || _rejected || _finished) return;
    if (!_parsedHeaders) {
        NSData *mark = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        NSRange range = [_buffer rangeOfData:mark options:0 range:NSMakeRange(0, _buffer.length)];
        if (range.location == NSNotFound) {
            if (_buffer.length > kHeaderCap) [self sendError:431 message:@"Request headers are too large."];
            return;
        }
        if (NSMaxRange(range) > kHeaderCap) {
            [self sendError:431 message:@"Request headers are too large."];
            return;
        }
        _headerEnd = NSMaxRange(range);
        [self readHeaders:[_buffer subdataWithRange:NSMakeRange(0, range.location)]];
        _parsedHeaders = YES;
        if (_finished || _rejected) return;
    }
    if (_buffer.length < _headerEnd) return;
    NSUInteger bodyLength = _buffer.length - _headerEnd;
    if (bodyLength > kBodyCap) { [self sendError:413 message:@"Request body is too large."]; return; }
    if (bodyLength < (NSUInteger)_contentLength) return;
    NSData *body = [_buffer subdataWithRange:NSMakeRange(_headerEnd, (NSUInteger)_contentLength)];
    _routed = YES;
    [self route:body];
}

- (void)readHeaders:(NSData *)data {
    NSString *head = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!head.length) { [self sendError:400 message:@"Bad request."]; return; }
    NSArray<NSString *> *lines = [head componentsSeparatedByString:@"\r\n"];
    NSArray<NSString *> *request = [lines.firstObject componentsSeparatedByString:@" "];
    if (request.count != 3) { [self sendError:400 message:@"Bad request line."]; return; }
    NSString *method = request[0], *path = request[1], *version = request[2];
    if (!method.length || method.length > 8 || !path.length || path.length > 512 ||
        ![path hasPrefix:@"/"] || (![version isEqualToString:@"HTTP/1.0"] && ![version isEqualToString:@"HTTP/1.1"])) {
        [self sendError:400 message:@"Bad request line."];
        return;
    }
    if (![method isEqualToString:@"GET"] && ![method isEqualToString:@"POST"]) {
        [self sendError:405 message:@"Only GET and POST are allowed."];
        return;
    }
    _method = method;
    _path = path;
    BOOL sawLength = NO, sawType = NO;
    NSString *host = nil, *origin = nil;
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSString *line = lines[i];
        if (!line.length) continue;
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound || colon.location == 0) {
            [self sendError:400 message:@"Bad header."];
            return;
        }
        NSString *name = [[line substringToIndex:colon.location] lowercaseString];
        NSString *value = [[line substringFromIndex:colon.location + 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
            [self sendError:400 message:@"Bad header."];
            return;
        }
        if ([name isEqualToString:@"transfer-encoding"] || [name isEqualToString:@"expect"]) {
            [self sendError:400 message:@"Unsupported transfer encoding."];
            return;
        }
        if ([name isEqualToString:@"host"]) {
            if (host) { [self sendError:400 message:@"Duplicate Host."]; return; }
            host = value;
        } else if ([name isEqualToString:@"origin"]) {
            if (origin) { [self sendError:400 message:@"Duplicate Origin."]; return; }
            origin = value;
        }
        if ([name isEqualToString:@"content-length"]) {
            if (sawLength || !value.length ||
                [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound) {
                [self sendError:400 message:@"Bad Content-Length."];
                return;
            }
            sawLength = YES;
            long long length = value.longLongValue;
            if (length > (long long)kBodyCap) {
                [self sendError:413 message:@"Request body is too large."];
                return;
            }
            _contentLength = (NSInteger)length;
        } else if ([name isEqualToString:@"content-type"]) {
            if (sawType) {
                [self sendError:400 message:@"Bad header."];
                return;
            }
            sawType = YES;
            _contentType = value;
        }
    }
    NSString *address = wifiAddress();
    NSString *authority = address ? [NSString stringWithFormat:@"%@:%d", address, SGWebJamPort] : nil;
    if (!authority || ![host isEqualToString:authority] ||
        (origin && ![origin isEqualToString:[@"http://" stringByAppendingString:authority]])) {
        [self sendError:403 message:@"Open the host's Wi-Fi address directly."];
        return;
    }
    if ([method isEqualToString:@"POST"] && !sawLength) {
        [self sendError:411 message:@"Content-Length is required."];
    }
}

- (void)route:(NSData *)body {
    if (_rejected) return;
    NSURLComponents *parts = [NSURLComponents componentsWithString:_path];
    if ([_method isEqualToString:@"GET"]) {
        if ([parts.path isEqualToString:@"/"]) {
            [self sendCode:200 type:@"text/html; charset=utf-8"
                      body:[SGWebJamHTMLPage() dataUsingEncoding:NSUTF8StringEncoding]];
        } else if ([parts.path isEqualToString:@"/state"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self->_rejected || !self->_server.enabled || self->_server.generation != self->_generation) return;
                noteGuest(parts);
                [self sendCode:200 type:@"application/json; charset=utf-8"
                          body:[stateJSON() dataUsingEncoding:NSUTF8StringEncoding]];
            });
        } else if ([parts.path isEqualToString:@"/audio"]) {
            uint32_t epoch = 0, after = 0;
            NSMutableSet *seen = [NSMutableSet set];
            for (NSURLQueryItem *item in parts.queryItems) {
                if ((![item.name isEqual:@"epoch"] && ![item.name isEqual:@"after"]) ||
                    [seen containsObject:item.name] || !item.value.length || item.value.length > 10 ||
                    [item.value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound ||
                    item.value.longLongValue > UINT32_MAX) { [self sendError:400 message:@"Invalid audio cursor."]; return; }
                [seen addObject:item.name];
                if ([item.name isEqual:@"epoch"]) epoch = (uint32_t)item.value.longLongValue;
                else after = (uint32_t)item.value.longLongValue;
            }
            SGWebJamAudioNext(epoch, after, ^(NSData *packet) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self->_rejected || !self->_server.enabled || self->_server.generation != self->_generation) return;
                    [self sendCode:packet ? 200 : 204 type:@"application/octet-stream" body:packet];
                });
            });
        } else {
            [self sendError:404 message:@"Not found."];
        }
        return;
    }
    if (![_path isEqualToString:@"/add"]) { [self sendError:404 message:@"Not found."]; return; }
    if (![[[_contentType.lowercaseString componentsSeparatedByString:@";"].firstObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] isEqualToString:@"application/json"]) {
        [self sendError:415 message:@"Send application/json."];
        return;
    }
    NSDictionary *object = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    id raw = [object isKindOfClass:NSDictionary.class] ? object[@"url"] : nil;
    if (![raw isKindOfClass:NSString.class] || [(NSString *)raw length] > 512) {
        [self sendError:400 message:@"Send a Spotify song or playlist link, URI, or track ID."];
        return;
    }
    NSString *uri = SGWebJamRequestURI(raw);
    _requester = SGWebJamDisplayName(object[@"name"]);
    if (!uri) {
        [self sendError:400 message:@"Use a Spotify song or playlist link, URI, or 22-character track ID."];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [self queueURI:uri trackID:nil]; });
}

// Main thread: dedupe and resolve before touching the hub, so a request's answer
// says what actually happened instead of only that the HTTP call landed.
- (void)queueURI:(NSString *)uri trackID:(NSString *)trackID {
    if (_rejected) return;
    SGWebJamServer *server = _server;
    SGLocalJamHub *hub = SGLocalJamHubShared();
    if (!server.enabled || server.generation != _generation || !hub.hosting) {
        [self sendError:409 message:@"The host has ended this Web Jam."];
        return;
    }
    if (hub.queue.count >= kQueueCap) {
        [self sendError:409 message:@"The queue is full."];
        return;
    }
    for (SGLocalJamEntry *entry in hub.queue) {
        if ([entry.uri isEqualToString:uri]) {
            [self sendError:409 message:@"That song or playlist is already in the queue."];
            return;
        }
    }
    NSDictionary *cached = server.resolved[uri];
    NSString *title = cached[@"title"] ?: ([uri hasPrefix:@"spotify:playlist:"] ? @"Requested playlist" : @"Requested song");
    NSString *artist = cached[@"artist"] ?: @"Guest";
    if (![hub addWebRequestURI:uri title:title artist:artist by:_requester ?: @"Guest"]) {
        [self sendError:409 message:@"That request is already waiting, or the queue is full."];
        return;
    }
    SGLocalJamEntry *added = nil;
    for (SGLocalJamEntry *entry in hub.queue) if ([entry.uri isEqualToString:uri]) { added = entry; break; }
    NSString *json = [NSString stringWithFormat:@"{\"ok\":true,\"title\":%@}", SGWebJamJSONString(title)];
    [self sendCode:200 type:@"application/json; charset=utf-8" body:[json dataUsingEncoding:NSUTF8StringEncoding]];
    if (cached) return;
    NSUInteger generation = _generation;
    [server resolveURI:uri completion:^(NSString *resolvedTitle, NSString *resolvedArtist) {
        if (!server.enabled || server.generation != generation || !hub.hosting) return;
        [hub updateWebRequest:added title:resolvedTitle artist:resolvedArtist];
    }];
}

static NSString *reason(NSInteger code) {
    switch (code) {
        case 200: return @"OK";
        case 204: return @"No Content";
        case 400: return @"Bad Request";
        case 403: return @"Forbidden";
        case 405: return @"Method Not Allowed";
        case 408: return @"Request Timeout";
        case 409: return @"Conflict";
        case 411: return @"Length Required";
        case 413: return @"Payload Too Large";
        case 415: return @"Unsupported Media Type";
        case 431: return @"Request Header Fields Too Large";
        case 500: return @"Internal Server Error";
        default: return @"Not Found";
    }
}

- (void)sendError:(NSInteger)code message:(NSString *)message {
    _rejected = YES;
    NSString *json = [NSString stringWithFormat:
        @"{\"ok\":false,\"error\":%@}", SGWebJamJSONString(message)];
    [self sendCode:code type:@"application/json; charset=utf-8"
              body:[json dataUsingEncoding:NSUTF8StringEncoding]];
}

- (void)sendCode:(NSInteger)code type:(NSString *)type body:(NSData *)body {
    dispatch_queue_t queue = _queue;
    __weak SGWebJamHTTP *weakSelf = self;
    dispatch_async(queue, ^{ [weakSelf writeCode:code type:type body:body]; });
}

- (void)writeCode:(NSInteger)code type:(NSString *)type body:(NSData *)body {
    if (_finished) return;
    _finished = YES;
    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 %ld %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nConnection: close\r\n"
         "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
         "Content-Security-Policy: default-src 'none'; img-src https://i.scdn.co; style-src 'unsafe-inline'; "
         "script-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n\r\n",
        (long)code, reason(code), type ?: @"text/plain; charset=utf-8", (unsigned long)body.length];
    NSMutableData *response = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (body.length) [response appendData:body];
    dispatch_data_t content = dispatch_data_create(response.bytes, response.length, nil,
        DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    dispatch_queue_t queue = _queue;
    __weak SGWebJamHTTP *weakSelf = self;
    NSData *held = response;
    nw_connection_send(_connection, content, NW_CONNECTION_FINAL_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        (void)error; (void)held;
        dispatch_async(queue, ^{
            SGWebJamHTTP *strong = weakSelf;
            if (!strong) return;
            nw_connection_cancel(strong->_connection);
            [strong->_server finished:strong];
        });
    });
}

@end

#pragma mark - The server

@implementation SGWebJamServer

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _queue = dispatch_queue_create("spotifyglass.webjam", DISPATCH_QUEUE_SERIAL);
    _connections = [NSMutableSet set];
    _resolved = [NSMutableDictionary dictionary];
    _resolving = [NSMutableDictionary dictionary];
    return self;
}

- (void)start {
    if (!NSThread.isMainThread) {
        __weak SGWebJamServer *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf start]; });
        return;
    }
    if (self.enabled) return;
    self.enabled = YES;
    self.generation += 1;
    NSUInteger generation = self.generation;
    sg_sessionID = NSUUID.UUID.UUIDString;
    sg_lastTrack = nil; sg_lastNow = nil;
    sg_recent = [NSMutableArray array]; sg_guests = [NSMutableDictionary dictionary];
    setStatus(@"Starting…");
    __weak SGWebJamServer *weakSelf = self;
    self.hubObserver = [NSNotificationCenter.defaultCenter addObserverForName:SGLocalJamDidChangeNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        if (weakSelf.enabled && !SGLocalJamHubShared().hosting) [weakSelf stop];
    }];
    dispatch_async(self.queue, ^{
        SGWebJamServer *strong = weakSelf;
        if (!strong || generation != strong.generation) return;
        strong.wanted = YES;
        [strong createListenerForGeneration:generation];
    });
}

- (void)createListenerForGeneration:(NSUInteger)generation {
    if (!self.wanted || self.listener) return;
    nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL,
        NW_PARAMETERS_DEFAULT_CONFIGURATION);
    if (parameters) nw_parameters_set_required_interface_type(parameters, nw_interface_type_wifi);
    nw_listener_t listener = parameters ?
        nw_listener_create_with_port("8787", parameters) : NULL;
    if (!listener) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation == self.generation) [self unavailable];
        });
        return;
    }
    self.listener = listener;
    nw_listener_set_queue(listener, self.queue);
    __weak SGWebJamServer *weakSelf = self;
    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
        (void)error;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf listenerState:state generation:generation];
        });
    });
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
        if (generation != weakSelf.generation) nw_connection_cancel(connection);
        else [weakSelf accept:connection];
    });
    nw_listener_start(listener);
    self.listening = YES;
}

- (void)listenerState:(nw_listener_state_t)state generation:(NSUInteger)generation {
    if (generation != self.generation) return;
    if (!self.enabled) return;
    if (state == nw_listener_state_ready) {
        sg_ready = YES;
        SGWebJamAudioStart();
        setStatus(@"On · guests can join on this Wi-Fi");
        [self startTicker];
    } else if (state == nw_listener_state_waiting) {
        sg_ready = NO;
        setStatus(@"On · waiting for this Wi-Fi");
    } else if (state == nw_listener_state_failed) {
        [self unavailable];
    } else if (state == nw_listener_state_cancelled) {
        [self stop];
    }
}

- (void)unavailable {
    [self stop];
    setStatus(@"Web Jam unavailable");
}

- (void)stop {
    if (!NSThread.isMainThread) {
        __weak SGWebJamServer *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf stop]; });
        return;
    }
    self.enabled = NO;
    self.generation += 1;
    sg_ready = NO;
    SGWebJamAudioStop();
    [sg_guests removeAllObjects]; [sg_recent removeAllObjects]; sg_lastNow = nil; sg_lastTrack = nil;
    SGSetEnabled(SGKeyWebJam, NO);
    if (self.hubObserver) [NSNotificationCenter.defaultCenter removeObserver:self.hubObserver];
    self.hubObserver = nil;
    for (NSURLSessionDataTask *task in self.resolving.allValues) [task cancel];
    [self.resolving removeAllObjects];
    BOOL leave = sg_ownsHosting;
    sg_ownsHosting = NO;
    if (leave && SGLocalJamHubShared().hosting) [SGLocalJamHubShared() leave];
    SGLocalJamRuntimeStopIfUnused();
    [self stopTicker];
    setStatus(@"Off");
    __weak SGWebJamServer *weakSelf = self;
    dispatch_async(self.queue, ^{ [weakSelf teardown]; });
}

- (void)teardown {
    self.wanted = NO;
    for (SGWebJamHTTP *http in self.connections.allObjects) [http cancel];
    [self.connections removeAllObjects];
    if (self.listener) {
        nw_listener_cancel(self.listener);
        self.listener = nil;
    }
    self.listening = NO;
}

- (void)accept:(nw_connection_t)connection {
    if (!self.wanted || !self.listening || self.connections.count >= 8) {
        nw_connection_cancel(connection);
        return;
    }
    SGWebJamHTTP *http = [[SGWebJamHTTP alloc] initWithConnection:connection
        queue:self.queue server:self];
    [self.connections addObject:http];
    [http begin];
}

- (void)finished:(SGWebJamHTTP *)http {
    [self.connections removeObject:http];
}

- (void)startTicker {
    if (self.ticker) return;
    __weak SGWebJamServer *weakSelf = self;
    NSTimer *ticker = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        SGWebJamServer *strong = weakSelf;
        if (!strong || !strong.enabled) return;
        observePlayback();
        [SGLocalJamHubShared() playWebRequestAtEnd];
    }];
    self.ticker = ticker;
    [NSRunLoop.currentRunLoop addTimer:ticker forMode:NSRunLoopCommonModes];
}

- (void)stopTicker {
    [self.ticker invalidate];
    self.ticker = nil;
}

// oEmbed names the title; Spotify's track payload has no author_name, so the
// artist falls back to Guest like any failed lookup. The fallback is cached too.
- (void)resolveURI:(NSString *)uri completion:(void (^)(NSString *, NSString *))done {
    NSDictionary *cached = self.resolved[uri];
    if (cached) { done(cached[@"title"], cached[@"artist"]); return; }
    if (self.resolving[uri] || self.resolving.count >= 8) { done(([uri hasPrefix:@"spotify:playlist:"] ? @"Requested playlist" : @"Requested song"), @"Guest"); return; }
    NSURLComponents *parts = [NSURLComponents componentsWithString:@"https://open.spotify.com/oembed"];
    parts.queryItems = @[[NSURLQueryItem queryItemWithName:@"url"
        value:uri]];
    if (!parts.URL) { done(([uri hasPrefix:@"spotify:playlist:"] ? @"Requested playlist" : @"Requested song"), @"Guest"); return; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:parts.URL];
    request.timeoutInterval = 4.0;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    __weak SGWebJamServer *weakSelf = self;
    NSUInteger generation = self.generation;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *title = ([uri hasPrefix:@"spotify:playlist:"] ? @"Requested playlist" : @"Requested song"), *artist = @"Guest";
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ?
            ((NSHTTPURLResponse *)response).statusCode : 0;
        if (!error && status == 200 && data.length && data.length <= 65536) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:NSDictionary.class]) {
                id fetchedTitle = json[@"title"], fetchedArtist = json[@"author_name"];
                if ([fetchedTitle isKindOfClass:NSString.class] && [fetchedTitle length]) title = fetchedTitle;
                if ([fetchedArtist isKindOfClass:NSString.class] && [fetchedArtist length]) artist = fetchedArtist;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            SGWebJamServer *strong = weakSelf;
            if (!strong.enabled || strong.generation != generation) return;
            [strong.resolving removeObjectForKey:uri];
            if (strong.resolved.count >= 256) [strong.resolved removeAllObjects];
            if (strong) strong.resolved[uri] = @{@"title": title, @"artist": artist};
            done(title, artist);
        });
    }];
    self.resolving[uri] = task;
    [task resume];
}

@end

#pragma mark - Public

// The party queue and its playback live in Local Jam's hub, so Web Jam brings hosting up with it;
// otherwise guests could add songs that never play.
static void ensureHosting(void) {
    SGLocalJamRuntimeStart();
    SGLocalJamHub *hub = SGLocalJamHubShared();
    if (!hub.joined) {
        sg_ownsHosting = YES;
        [hub startHost];
    }
}

void SGWebJamSetEnabled(BOOL on) {
    SGSetEnabled(SGKeyWebJam, on);
    if (on) {
        if (SGLocalJamHubShared().joined && !SGLocalJamHubShared().hosting) {
            SGSetEnabled(SGKeyWebJam, NO);
            setStatus(@"Leave the Local Jam before hosting a Web Jam");
            return;
        }
        ensureHosting(); [sharedServer() start];
    }
    else [sharedServer() stop];
}

void SGWebJamRuntimeStart(void) {
    if (!SGWebJamEnabled()) return;
    ensureHosting();
    [sharedServer() start];
}

__attribute__((constructor)) static void SGWebJamInstall(void) {
    SGWebJamRuntimeStart();
}
