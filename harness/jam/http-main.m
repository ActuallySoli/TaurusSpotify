#import "../../tweak/Sources/Shared/Jam/WebJam.m"

void SGLogMessage(NSString *message) {}
NSString *SGWebJamHTMLPage(void) { return @"page"; }
SPTPlayerState *SGPlayerState(void) { return nil; }
NSString *SGURIString(id value) { return [value isKindOfClass:NSString.class] ? value : nil; }
void SGWebJamAudioStart(void) {}
void SGWebJamAudioStop(void) {}
void SGWebJamAudioUpdate(BOOL playing, NSString *uri, double position) {}
NSDictionary *SGWebJamAudioStatus(void) { return @{@"ready": @NO}; }
void SGWebJamAudioNext(uint32_t epoch, uint32_t after, void (^done)(NSData *)) { done(nil); }
@interface TestHub : NSObject
@property BOOL hosting, joined;
@property NSUInteger leaves;
@end
@implementation TestHub
- (BOOL)isHosting { return self.hosting; }
- (void)startHost { self.hosting = YES; self.joined = YES; }
- (void)leave {
    self.hosting = NO; self.joined = NO; self.leaves++;
    [NSNotificationCenter.defaultCenter postNotificationName:SGLocalJamDidChangeNotification object:nil];
}
@end
NSNotificationName SGLocalJamDidChangeNotification = @"test.jam.changed";
static TestHub *testHub;
SGLocalJamHub *SGLocalJamHubShared(void) { return (SGLocalJamHub *)testHub; }
void SGLocalJamRuntimeStart(void) {}
void SGLocalJamRuntimeStopIfUnused(void) {}

@interface TestServer : SGWebJamServer
@end
@implementation TestServer
- (void)createListenerForGeneration:(NSUInteger)generation {}
@end

@interface Probe : SGWebJamHTTP
@property NSInteger routes, code;
@end
@implementation Probe
- (void)route:(NSData *)body { self.routes++; }
- (void)sendError:(NSInteger)code message:(NSString *)message { self.code = code; [super sendError:code message:message]; }
- (void)sendCode:(NSInteger)code type:(NSString *)type body:(NSData *)body {}
@end
static void check(BOOL ok, NSString *message) {
    if (!ok) { NSLog(@"FAIL %@", message); exit(1); }
    NSLog(@"PASS %@", message);
}
int main(void) { @autoreleasepool {
    testHub = [TestHub new];
    check(SGWebJamJoinURL() == nil, @"no join link before the listener is ready");
    NSString *address = wifiAddress() ? [NSString stringWithFormat:@"http://%@:8787", wifiAddress()] : nil;
    check(address != nil, @"Wi-Fi address available for HTTP tests");
    NSString *host = [address substringFromIndex:7];
    dispatch_queue_t queue = dispatch_queue_create("test.http", DISPATCH_QUEUE_SERIAL);
    dispatch_sync(queue, ^{
        for (NSString *origin in @[@"", [NSString stringWithFormat:@"Origin: %@\r\n", address], @"Origin: https://attacker.invalid\r\n"]) {
            Probe *probe = [[Probe alloc] initWithConnection:nil queue:queue server:nil];
            NSString *request = [NSString stringWithFormat:@"POST /add HTTP/1.1\r\nHost: %@\r\n%@Content-Type: application/json\r\nContent-Length: 2\r\n\r\n{}", host, origin];
            [probe consume:[request dataUsingEncoding:NSUTF8StringEncoding] complete:YES error:nil];
            [probe parse];
            check([origin containsString:@"attacker"] ? probe.code == 403 && probe.routes == 0 : probe.routes == 1 && probe.code == 0,
                @"one request routes once, including half-close; foreign origins rejected");
        }
        NSArray *badHeaders = @[
            @"Content-Length: 2\r\nContent-Length: 2\r\n",
            @"Content-Length: 99999999999999999999999999\r\n",
            @"Content-Length: ٢\r\n",
            @"Content-Length: -2\r\n",
            @"Transfer-Encoding: chunked\r\n",
            @"Content-Length: 2\r\nContent-Type: application/json\r\nContent-Type: text/plain\r\n"
        ];
        for (NSString *headers in badHeaders) {
            Probe *bad = [[Probe alloc] initWithConnection:nil queue:queue server:nil];
            NSString *request = [NSString stringWithFormat:@"POST /add HTTP/1.1\r\nHost: %@\r\n%@\r\n{}", host, headers];
            [bad consume:[request dataUsingEncoding:NSUTF8StringEncoding] complete:YES error:nil];
            check(bad.code >= 400 && bad.routes == 0, @"ambiguous or oversized request is rejected");
        }
        Probe *badVersion = [[Probe alloc] initWithConnection:nil queue:queue server:nil];
        NSString *request = [NSString stringWithFormat:@"GET /state HTTP/1.bogus\r\nHost: %@\r\n\r\n", host];
        [badVersion consume:[request dataUsingEncoding:NSUTF8StringEncoding] complete:YES error:nil];
        check(badVersion.code == 400 && badVersion.routes == 0, @"invalid HTTP version is rejected");
        Probe *probe = [[Probe alloc] initWithConnection:nil queue:queue server:nil];
        [probe consume:[@"GET /state HTTP/1.1\r\nHost: attacker.invalid:8787\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding] complete:YES error:nil];
        check(probe.code == 403 && probe.routes == 0, @"foreign Host cannot access session state");
    });
    sg_server = [TestServer new];
    SGWebJamSetEnabled(YES);
    check(testHub.hosting && sg_ownsHosting, @"Web Jam creates hosting when needed");
    [sg_server listenerState:nw_listener_state_ready generation:sg_server.generation];
    check(SGWebJamRunning() && SGWebJamJoinURL() != nil, @"ready listener exposes its join link");
    NSUInteger oldGeneration = sg_server.generation;
    Probe *stale = [[Probe alloc] initWithConnection:nil queue:queue server:sg_server];
    SGWebJamSetEnabled(NO);
    [stale queueURI:@"spotify:track:1111111111111111111111" trackID:@"1111111111111111111111"];
    check(stale.code == 409, @"stopped generation rejects a queued add");
    check(!testHub.hosting && testHub.leaves == 1 && !SGWebJamRunning() && SGWebJamJoinURL() == nil,
        @"Stop ends Web Jam-owned hosting and hides its join link");
    [testHub startHost];
    SGWebJamSetEnabled(YES);
    check(!sg_ownsHosting, @"existing Local Jam is not owned by Web Jam");
    [sg_server listenerState:nw_listener_state_ready generation:oldGeneration];
    check(!SGWebJamRunning(), @"old listener callbacks cannot expose a new session link");
    Probe *cancelled = [[Probe alloc] initWithConnection:nil queue:queue server:sg_server];
    [cancelled connectionEnded];
    [cancelled queueURI:@"spotify:track:1111111111111111111111" trackID:@"1111111111111111111111"];
    check(cancelled.code == 0, @"disconnected requests cannot reach the shared queue");
    SGWebJamSetEnabled(NO);
    check(testHub.hosting && testHub.leaves == 1, @"Stop preserves an existing Local Jam");
    SGWebJamSetEnabled(YES);
    [testHub leave];
    check(!sg_server.enabled && !SGWebJamEnabled(), @"leaving the shared host stops Web Jam");
    SGWebJamSetEnabled(YES);
    [sg_server unavailable];
    check(!testHub.hosting && !SGWebJamEnabled() && SGWebJamJoinURL() == nil,
        @"listener failure cleans up hosting and the stored switch");
    testHub.joined = YES;
    SGWebJamSetEnabled(YES);
    check(!SGWebJamEnabled() && !testHub.hosting, @"a Local Jam guest cannot silently become host");
    dispatch_sync(sg_server.queue, ^{});
    [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyWebJam];
} return 0; }
