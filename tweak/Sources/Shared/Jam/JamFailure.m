#import "Jam.h"

NSString *SGJamAccountRejection(NSURLRequest *request, NSData *body) {
    NSString *reply = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding].lowercaseString;
    if (![reply containsString:@"free_user_not_allowed"]) return nil;
    NSArray<NSString *> *parts = request.URL.path.pathComponents;
    NSUInteger social = [parts indexOfObject:@"social-connect"];
    BOOL sessionPath = social != NSNotFound && social + 2 < parts.count
        && [@[@"v2", @"v3"] containsObject:parts[social + 1]]
        && [parts[social + 2] isEqualToString:@"sessions"];
    BOOL create = sessionPath && social + 3 == parts.count && [request.HTTPMethod.uppercaseString isEqualToString:@"POST"];
    BOOL join = sessionPath && [parts containsObject:@"join"];
    if (create) return @"Spotify: this account cannot host a Jam (FREE_USER_NOT_ALLOWED)";
    if (join) return @"Spotify declined this account's join request (FREE_USER_NOT_ALLOWED). Free accounts can join in person; remote listening requires Premium on the joining account.";
    return @"Spotify did not allow this account's Jam action (FREE_USER_NOT_ALLOWED)";
}
