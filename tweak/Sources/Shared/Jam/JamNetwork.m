#import "Core/SGCore.h"
#import "Core/SGURLSession.h"
#import "Jam.h"

NSNotificationName const SGJamStatusDidChangeNotification = @"spotifyglass.jam.statusChanged";
static NSString *sg_result = @"No Jam request observed yet";
static NSString *sg_failure = @"No Jam failure observed yet";
static char kResultKey, kErrorBodyKey;

static BOOL jamTask(NSURLSessionTask *task) {
    NSURL *url = SGURLSessionTaskURL(task);
    NSString *host = url.host.lowercaseString;
    return ([host isEqualToString:@"spotify.com"] || [host hasSuffix:@".spotify.com"])
        && [url.path.lowercaseString containsString:@"/social-connect/"];
}

static NSString *operation(NSURLSessionTask *task) {
    NSURLRequest *request = SGURLSessionTaskRequest(task, NO) ?: SGURLSessionTaskRequest(task, YES);
    NSString *method = request.HTTPMethod.uppercaseString ?: @"GET";
    if (![@[@"GET", @"POST", @"PUT", @"DELETE", @"PATCH"] containsObject:method]) method = @"request";
    NSArray *parts = request.URL.path.pathComponents;
    NSUInteger index = [parts indexOfObject:@"social-connect"];
    NSString *version = index != NSNotFound && index + 1 < parts.count ? parts[index + 1] : nil;
    if (![@[@"v2", @"v3"] containsObject:version]) version = @"API";
    NSMutableArray *path = [NSMutableArray array];
    // Spotify's Jam endpoint words, kept verbatim so the record reads like the
    // real endpoint; anything else in the path is a session or member id.
    NSSet *known = [NSSet setWithArray:@[@"sessions", @"current", @"session_update", @"session_messages",
        @"broadcast_status_update", @"membership_upgrade_messages", @"upsell_messages",
        @"commands", @"from", @"join", @"leave", @"participants", @"devices"]];
    if (index != NSNotFound) for (NSUInteger i = index + 2; i < parts.count && path.count < 10; i++) {
        [path addObject:[known containsObject:parts[i]] ? parts[i] : @"<id>"];
    }
    return [NSString stringWithFormat:@"%@ %@ %@", method, version, path.count ? [path componentsJoinedByString:@"/"] : @"session"];
}

static void record(NSString *result, BOOL failure) {
    @synchronized (SGJamStatusDidChangeNotification) {
        sg_result = [result copy];
        if (failure) sg_failure = [result copy];
    }
    SGLog(@"jam: %@", result);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:SGJamStatusDidChangeNotification object:nil];
    });
}

NSString *SGJamLastResult(void) {
    @synchronized (SGJamStatusDidChangeNotification) { return sg_result; }
}

NSString *SGJamLastFailure(void) {
    @synchronized (SGJamStatusDidChangeNotification) { return sg_failure; }
}

void SGJamObserveResponse(NSURLSessionTask *task, NSURLResponse *response) {
    if (!jamTask(task) || ![response isKindOfClass:NSHTTPURLResponse.class]) return;
    // Only session calls say anything about Jam; the devices poll next to them answers 200 even
    // when the start is refused, and it used to overwrite the result with a false "accepted".
    if (![SGURLSessionTaskURL(task).path containsString:@"/sessions"]) return;
    NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
    BOOL absent = status == 404 && [operation(task) hasPrefix:@"GET "]
        && [SGURLSessionTaskURL(task).lastPathComponent isEqualToString:@"current"];
    NSString *result = [NSString stringWithFormat:absent ? @"No current Jam (HTTP %ld; %@)"
        : status >= 200 && status < 300 ? @"Spotify accepted a Jam request (HTTP %ld; %@)"
        : @"Spotify returned HTTP %ld for Jam (%@)", (long)status, operation(task)];
    objc_setAssociatedObject(task, &kResultKey, result, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(task, &kErrorBodyKey, status >= 400 && !absent ? [NSMutableData data] : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    record(result, status >= 400 && !absent);
}

void SGJamObserveData(NSURLSessionTask *task, NSData *data) {
    NSMutableData *body = objc_getAssociatedObject(task, &kErrorBodyKey);
    if (!body || !data.length || body.length >= 4096) return;
    [body appendData:[data subdataWithRange:NSMakeRange(0, MIN(data.length, 4096 - body.length))]];
}

void SGJamObserveError(NSURLSessionTask *task, NSError *error) {
    if (!jamTask(task)) return;
    NSData *body = objc_getAssociatedObject(task, &kErrorBodyKey);
    objc_setAssociatedObject(task, &kErrorBodyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (error) {
        record([NSString stringWithFormat:@"Jam connection failed (%@ %ld; %@)", error.domain, (long)error.code, operation(task)], YES);
        return;
    }
    if (!body) return;
    NSString *base = objc_getAssociatedObject(task, &kResultKey);
    if (!body.length) { record([base stringByAppendingString:@"; empty reply"], YES); return; }
    NSString *reply = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding].lowercaseString;
    NSString *account = SGJamAccountRejection(SGURLSessionTaskRequest(task, NO) ?: SGURLSessionTaskRequest(task, YES), body);
    if (account) {
        record([NSString stringWithFormat:@"%@; %@", base, account], YES);
        return;
    }
    NSMutableArray *mentions = [NSMutableArray array];
    for (NSString *word in @[@"premium", @"permission", @"scope", @"unauthorized", @"in_person"]) {
        if ([reply containsString:word]) [mentions addObject:word];
    }
    if (mentions.count) {
        record([NSString stringWithFormat:@"%@; reply mentions %@ (%lu bytes)", base,
            [mentions componentsJoinedByString:@", "], (unsigned long)body.length], YES);
        return;
    }
    record([NSString stringWithFormat:@"%@; %lu reply bytes, no recognized reason", base, (unsigned long)body.length], YES);
}
