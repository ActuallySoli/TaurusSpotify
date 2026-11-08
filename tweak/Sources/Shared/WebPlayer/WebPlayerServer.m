#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <poll.h>
#import <sys/socket.h>
#import <unistd.h>
#import "Core/SGPrefs.h"
#import "SGWebPlayerBridge.h"
#import "WebPlayer.h"

NSNotificationName const SGWebPlayerDidChangeNotification = @"SGWebPlayerDidChangeNotification";
static const NSUInteger kHeaderCap = 8192, kBodyCap = 4096, kResponseCap = 512 * 1024;
static const NSTimeInterval kDeadline = 5;

@interface SGWebPlayerEngine : NSObject
@property (atomic, copy) NSString *token;
@property (nonatomic, copy) NSString *address;
@property (nonatomic) uint16_t port;
@property (atomic) BOOL running;
@property (nonatomic) int listener;
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *clients;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *stamps;
- (BOOL)start:(uint16_t)port;
- (void)stop;
@end

static SGWebPlayerEngine *sg_engine;
static NSString *sg_failure;

NSString *SGWebPlayerPreferredIPv4(NSArray<NSDictionary<NSString *, NSString *> *> *interfaces) {
    NSString *best;
    NSInteger bestRank = NSIntegerMax;
    for (NSDictionary *entry in interfaces) {
        NSString *name = entry[@"name"], *ip = entry[@"ip"];
        if (![name isKindOfClass:NSString.class] || ![ip isKindOfClass:NSString.class]) continue;
        NSString *suffix = [name hasPrefix:@"en"] ? [name substringFromIndex:2] :
            [name hasPrefix:@"wlan"] ? [name substringFromIndex:4] : nil;
        if (!suffix.length || [suffix rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) continue;
        struct in_addr addr;
        if (inet_pton(AF_INET, ip.UTF8String, &addr) != 1) continue;
        uint32_t value = ntohl(addr.s_addr);
        if ((value >> 24) == 0 || (value >> 24) == 127 || (value >> 16) == 0xa9fe || value >= 0xe0000000) continue;
        NSInteger rank = suffix.integerValue + ([name hasPrefix:@"en"] ? 0 : 1000);
        if (rank < bestRank) { best = ip; bestRank = rank; }
    }
    return best;
}

static NSArray *LocalInterfaces(void) {
    NSMutableArray *list = [NSMutableArray new];
    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs)) return list;
    for (struct ifaddrs *p = addrs; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET || !(p->ifa_flags & IFF_UP) ||
            !(p->ifa_flags & IFF_RUNNING) || (p->ifa_flags & IFF_LOOPBACK)) continue;
        char ip[INET_ADDRSTRLEN];
        if (inet_ntop(AF_INET, &((struct sockaddr_in *)p->ifa_addr)->sin_addr, ip, sizeof ip))
            [list addObject:@{@"name": @(p->ifa_name), @"ip": @(ip)}];
    }
    freeifaddrs(addrs);
    return list;
}

static BOOL BearerMatches(NSString *token, NSString *header) {
    if (!token.length || ![header hasPrefix:@"Bearer "]) return NO;
    NSData *a = [[header substringFromIndex:7] dataUsingEncoding:NSUTF8StringEncoding];
    NSData *b = [token dataUsingEncoding:NSUTF8StringEncoding];
    if (a.length != b.length) return NO;
    const uint8_t *x = a.bytes, *y = b.bytes;
    uint8_t difference = 0;
    for (NSUInteger i = 0; i < b.length; ++i) difference |= x[i] ^ y[i];
    return difference == 0;
}

static NSData *JSON(id object) {
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
}

static NSData *ResponseType(int status, NSData *body, NSString *mime, NSString *extra) {
    if (body.length > kResponseCap) { status = 503; body = JSON(@{@"error": @"snapshot too large"}); }
    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 %d Result\r\nConnection: close\r\nCache-Control: no-store\r\n"
        "X-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
        "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src https://i.scdn.co; media-src blob:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n"
        "Content-Type: %@\r\n%@Content-Length: %lu\r\n\r\n",
        status, mime, extra ?: @"", (unsigned long)body.length];
    NSMutableData *data = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [data appendData:body ?: NSData.data];
    return data;
}

static NSData *Response(int status, NSData *body, BOOL html) {
    return ResponseType(status, body, html ? @"text/html; charset=utf-8" : @"application/json", nil);
}

static NSData *Error(int status) { return Response(status, JSON(@{@"error": @(status)}), NO); }

static BOOL Wait(int fd, short events, NSTimeInterval deadline) {
    for (;;) {
        double remaining = deadline - NSProcessInfo.processInfo.systemUptime;
        if (remaining <= 0) return NO;
        struct pollfd p = {fd, events, 0};
        int result = poll(&p, 1, (int)(remaining * 1000));
        if (result < 0 && errno == EINTR) continue;
        return result > 0 && (p.revents & events);
    }
}

static void WriteAll(int fd, NSData *data) {
    NSUInteger offset = 0;
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + kDeadline;
    while (offset < data.length && Wait(fd, POLLOUT, deadline)) {
        ssize_t count = write(fd, (const uint8_t *)data.bytes + offset, data.length - offset);
        if (count > 0) offset += count;
        else if (count < 0 && (errno == EAGAIN || errno == EINTR)) continue;
        else break;
    }
}

@interface SGWebRequest : NSObject
@property NSString *method, *path;
@property NSDictionary<NSString *, NSString *> *headers;
@property NSData *body;
@end
@implementation SGWebRequest
@end

static SGWebRequest *ReadRequest(int fd, int *status) {
    NSMutableData *data = [NSMutableData new];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + kDeadline;
    SGWebRequest *request;
    NSUInteger bodyStart = 0, bodyLength = 0;
    *status = 400;
    for (;;) {
        if (!request) {
            NSRange end = [data rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, data.length)];
            if (end.location != NSNotFound) {
                bodyStart = NSMaxRange(end);
                if (bodyStart > kHeaderCap) { *status = 431; return nil; }
                NSString *head = [[NSString alloc] initWithBytes:data.bytes length:end.location encoding:NSASCIIStringEncoding];
                if (!head || [head rangeOfString:@"\0"].location != NSNotFound) return nil;
                NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
                NSArray<NSString *> *parts = [lines[0] componentsSeparatedByString:@" "];
                if (parts.count != 3 || ![@[@"HTTP/1.0", @"HTTP/1.1"] containsObject:parts[2]] ||
                    ![parts[1] hasPrefix:@"/"] || parts[1].length > 2048 || parts[0].length > 16 || !parts[0].length) return nil;
                if (lines.count > 129) { *status = 431; return nil; }
                NSMutableDictionary *headers = [NSMutableDictionary new];
                NSCharacterSet *invalidName = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789-"].invertedSet;
                for (NSUInteger i = 1; i < lines.count; ++i) {
                    NSString *line = lines[i];
                    NSRange colon = [line rangeOfString:@":"];
                    if (!colon.length || colon.location == 0) return nil;
                    NSString *name = [[line substringToIndex:colon.location] lowercaseString];
                    NSString *value = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                    if ([name rangeOfCharacterFromSet:invalidName].location != NSNotFound || headers[name] ||
                        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
                    headers[name] = value;
                }
                if (headers[@"transfer-encoding"] || headers[@"expect"]) return nil;
                NSString *length = headers[@"content-length"];
                if (length) {
                    if (!length.length || [length rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) return nil;
                    if (length.length > 6 || length.longLongValue > (long long)kBodyCap) { *status = 413; return nil; }
                    bodyLength = length.integerValue;
                }
                request = [SGWebRequest new];
                request.method = parts[0]; request.path = parts[1]; request.headers = headers;
            } else if (data.length >= kHeaderCap) { *status = 431; return nil; }
        }
        if (request && data.length >= bodyStart + bodyLength) {
            if (data.length != bodyStart + bodyLength) return nil;
            request.body = [data subdataWithRange:NSMakeRange(bodyStart, bodyLength)];
            return request;
        }
        if (!Wait(fd, POLLIN, deadline)) { *status = 408; return nil; }
        uint8_t bytes[2048];
        ssize_t count = read(fd, bytes, sizeof bytes);
        if (count < 0 && (errno == EAGAIN || errno == EINTR)) continue;
        if (count <= 0) return nil;
        if (data.length + count > kHeaderCap + kBodyCap) { *status = 413; return nil; }
        [data appendBytes:bytes length:count];
    }
}

static BOOL RateAllowed(SGWebPlayerEngine *engine, NSString *address, NSString *route) {
    NSString *key = [address stringByAppendingString:route];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    [engine.lock lock];
    NSNumber *previous = engine.stamps[key];
    BOOL allowed = !previous || now - previous.doubleValue >= 0.25;
    if (allowed) {
        if (engine.stamps.count >= 16) [engine.stamps removeAllObjects];
        engine.stamps[key] = @(now);
    }
    [engine.lock unlock];
    return allowed;
}

static void ApplyAction(NSString *action) {
    id<SPTPlayer> player = SGPlaybackPlayer();
    if ([action isEqual:@"play"]) [player resume:nil];
    else if ([action isEqual:@"pause"]) [player pause:nil];
    else if ([action isEqual:@"next"]) [player skipToNextTrackWithOptions:nil];
    else if ([action isEqual:@"previous"]) [player skipToPreviousTrackWithOptions:nil];
}

static NSData *Route(SGWebPlayerEngine *engine, SGWebRequest *request, NSString *client) {
    if (!engine.running) return Error(503);
    NSString *host = [NSString stringWithFormat:@"%@:%u", engine.address, engine.port];
    if (![request.headers[@"host"] isEqualToString:host]) return Error(403);
    BOOL page = [@[@"/", @"/index.html"] containsObject:request.path];
    BOOL state = [request.path isEqual:@"/api/state"], control = [request.path isEqual:@"/api/control"];
    BOOL media = [request.path hasPrefix:@"/api/artwork/"];
    if (!page && !state && !control && !media) return Error(404);
    if (![request.method isEqual:control ? @"POST" : @"GET"]) return Error(405);
    if (page) return Response(200, [SGWebPlayerPageHTML() dataUsingEncoding:NSUTF8StringEncoding], YES);
    NSString *token = engine.token;
    if (!BearerMatches(token, request.headers[@"authorization"])) return Error(401);
    if (media) {
        if (request.path.length > 80) return Error(404);
        NSInteger status; NSString *range;
        NSData *data = SGWebPlayerMediaRead([request.path substringFromIndex:13], request.headers[@"range"], &status, &range);
        if (status == 404) return Error(404);
        NSString *extra = [NSString stringWithFormat:@"Accept-Ranges: bytes\r\nContent-Range: %@\r\n", range];
        return ResponseType((int)status, data ?: NSData.data, @"video/mp4", extra);
    }
    if (control) {
        if (!SGFlag(SGKeyWebPlayerControls, NO) ||
            ![request.headers[@"origin"] isEqualToString:[@"http://" stringByAppendingString:host]]) return Error(403);
        if (![[request.headers[@"content-type"] componentsSeparatedByString:@";"].firstObject isEqual:@"application/json"]) return Error(415);
        id object = [NSJSONSerialization JSONObjectWithData:request.body options:0 error:NULL];
        NSString *action = [object isKindOfClass:NSDictionary.class] ? object[@"action"] : nil;
        if (![action isKindOfClass:NSString.class] || ![@[@"play", @"pause", @"next", @"previous"] containsObject:action]) return Error(400);
        if (!RateAllowed(engine, client, request.path)) return Error(429);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (engine.running && [engine.token isEqual:token] && SGFlag(SGKeyWebPlayerControls, NO)) ApplyAction(action);
        });
        return Response(200, JSON(@{@"ok": @YES}), NO);
    }
    if (!RateAllowed(engine, client, request.path)) return Error(429);
    return Response(200, SGWebPlayerFeedJSON() ?: JSON(@{@"ok": @NO}), NO);
}

@implementation SGWebPlayerEngine
- (instancetype)init {
    if ((self = [super init])) {
        _listener = -1; _lock = [NSLock new]; _clients = [NSMutableSet new]; _stamps = [NSMutableDictionary new];
    }
    return self;
}
- (BOOL)start:(uint16_t)port {
    if (!self.address.length) self.address = SGWebPlayerPreferredIPv4(LocalInterfaces());
    if (!self.address) { sg_failure = @"Not available — connect to Wi-Fi"; return NO; }
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET; addr.sin_port = htons(port);
    inet_pton(AF_INET, self.address.UTF8String, &addr.sin_addr);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) || listen(fd, 4) || fcntl(fd, F_SETFL, O_NONBLOCK)) {
        close(fd); return NO;
    }
    socklen_t size = sizeof addr;
    if (getsockname(fd, (struct sockaddr *)&addr, &size)) { close(fd); return NO; }
    uint8_t key[32]; arc4random_buf(key, sizeof key);
    NSMutableString *token = [NSMutableString new];
    for (NSUInteger i = 0; i < sizeof key; ++i) [token appendFormat:@"%02x", key[i]];
    self.token = token; self.port = ntohs(addr.sin_port); self.listener = fd; self.running = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            while (self.running) {
                if (!Wait(fd, POLLIN, NSProcessInfo.processInfo.systemUptime + 0.2)) continue;
                struct sockaddr_in peer; socklen_t peerSize = sizeof peer;
                [self.lock lock];
                if (!self.running) { [self.lock unlock]; break; }
                int clientFD = accept(fd, (struct sockaddr *)&peer, &peerSize);
                [self.lock unlock];
                if (clientFD < 0) continue;
                setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
                if (fcntl(clientFD, F_SETFL, O_NONBLOCK)) { close(clientFD); continue; }
                [self.lock lock];
                BOOL allowed = self.running && self.clients.count < 4;
                if (allowed) [self.clients addObject:@(clientFD)];
                [self.lock unlock];
                if (!allowed) { close(clientFD); continue; }
                char ip[INET_ADDRSTRLEN];
                NSString *client = inet_ntop(AF_INET, &peer.sin_addr, ip, sizeof ip) ? @(ip) : @"unknown";
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    @autoreleasepool {
                        int status;
                        SGWebRequest *request = ReadRequest(clientFD, &status);
                        if (self.running) WriteAll(clientFD, request ? Route(self, request, client) : Error(status));
                        [self.lock lock];
                        [self.clients removeObject:@(clientFD)]; close(clientFD);
                        [self.lock unlock];
                    }
                });
            }
        }
    });
    return YES;
}
- (void)stop {
    [self.lock lock];
    self.running = NO; self.token = nil;
    if (self.listener >= 0) { shutdown(self.listener, SHUT_RDWR); close(self.listener); self.listener = -1; }
    for (NSNumber *fd in self.clients) shutdown(fd.intValue, SHUT_RDWR);
    [self.lock unlock];
}
@end

void SGWebPlayerStart(void) {
    NSCAssert(NSThread.isMainThread, @"Browser Player lifecycle belongs to the main thread");
    if (sg_engine.running) return;
    sg_failure = @"Not available — local listener could not start";
    SGWebPlayerEngine *engine = [SGWebPlayerEngine new];
    if ([engine start:0]) { sg_engine = engine; sg_failure = nil; SGWebPlayerFeedStart(); }
    [NSNotificationCenter.defaultCenter postNotificationName:SGWebPlayerDidChangeNotification object:nil];
}
void SGWebPlayerStop(void) {
    NSCAssert(NSThread.isMainThread, @"Browser Player lifecycle belongs to the main thread");
    [sg_engine stop]; sg_engine = nil; sg_failure = nil; SGWebPlayerFeedStop();
    [NSNotificationCenter.defaultCenter postNotificationName:SGWebPlayerDidChangeNotification object:nil];
}
BOOL SGWebPlayerRunning(void) { return sg_engine.running; }
NSString *SGWebPlayerLink(void) {
    return sg_engine.running ? [NSString stringWithFormat:@"http://%@:%u/#%@", sg_engine.address, sg_engine.port, sg_engine.token] : nil;
}
NSString *SGWebPlayerStatus(void) {
    return sg_engine.running ? [NSString stringWithFormat:@"On · %@:%u", sg_engine.address, sg_engine.port] : sg_failure ?: @"Off";
}
