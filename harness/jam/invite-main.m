#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "Shared/Privacy/Privacy.h"
#import "Shared/Jam/Jam.h"
void SGLogMessage(NSString *message) { (void)message; }
void SGRegisterFlagForcer(BOOL beforeUser, id (^atLaunch)(NSString *), id (^now)(NSString *)) {
    (void)beforeUser; (void)atLaunch; (void)now;
}
id SGLinkDispatcher(void) { return nil; }

@interface StubJoinSheetPresenter : NSObject {
@public
    uint8_t userCapabilities[7];
}
@end
@implementation StubJoinSheetPresenter
@end

@interface StubJamDeeplinkHandler : NSObject {
@public
    uint8_t userCapabilities[7];
    uint8_t isNearbyJamInviteDeeplinkEnabled;
    uint8_t isJoinSheetFromJoinOptionsEnabled;
    __unsafe_unretained StubJoinSheetPresenter *joinSheetPresenter;
}
@end
@implementation StubJamDeeplinkHandler
@end

static void check(BOOL ok) { if (!ok) exit(1); }
int main(void) { @autoreleasepool {
    NSString *invite = @"https://open.spotify.com/socialsession/fixture-token?si=join&context=room%2Fone&utm_source=friend";
    NSURL *url = [NSURL URLWithString:invite];
    check([SGCleanLinkURL(url).absoluteString isEqual:invite]);
    check([SGCleanLinksInText(invite) isEqual:invite]);
    NSString *track = @"https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=tracking&t=10";
    check([SGCleanLinkURL([NSURL URLWithString:track]).absoluteString isEqual:@"https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?t=10"]);
    puts("PASS: Jam invitation parameters survive link cleaning; track tracking still removed");
    NSData *denied = [@"{\"reason\":\"FREE_USER_NOT_ALLOWED\",\"token\":\"secret-invite-token\"}" dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://spclient.wg.spotify.com/social-connect/v3/sessions"]];
    request.HTTPMethod = @"POST";
    check([SGJamAccountRejection(request, denied) containsString:@"cannot host"]);
    request.URL = [NSURL URLWithString:@"https://spclient.wg.spotify.com/social-connect/v3/sessions/secret-session/join?token=secret-invite-token"];
    NSString *join = SGJamAccountRejection(request, denied);
    check([join containsString:@"join request"] && ![join containsString:@"cannot host"]);
    check([join containsString:@"joining account"] && ![join containsString:@"secret"]);
    request.URL = [NSURL URLWithString:@"https://spclient.wg.spotify.com/social-connect/v3/sessions/current"];
    request.HTTPMethod = @"GET";
    check([SGJamAccountRejection(request, denied) containsString:@"Jam action"]);
    check(![SGJamAccountRejection(request, denied) containsString:@"cannot host"]);
    check(SGJamAccountRejection(request, [@"{\"error\":\"expired\"}" dataUsingEncoding:NSUTF8StringEncoding]) == nil);
    check(SGJamAccountRejection(request, [NSData dataWithBytes:"\xff" length:1]) == nil);
    puts("PASS: account rejection distinguishes host/join/unknown actions and never includes invitation tokens");
    check([SGJamProductStateValueForKey(@"jam-social-session") isEqualToString:@"EXPANDED"]);
    check([SGJamProductStateValueForKey(@"jam-queue-commands-feedback") isEqualToString:@"1"]);
    check([SGJamForcedFlag(@"ios-sociallistening-configuration-impl.is_nearby_jam_invite_deeplink_enabled") isEqual:@YES]);
    check([SGJamForcedFlag(@"ios-sociallistening-configuration-impl.join_sheet_from_join_options_enabled") isEqual:@YES]);
    StubJoinSheetPresenter *presenter = [StubJoinSheetPresenter new];
    presenter->userCapabilities[5] = 1;
    StubJamDeeplinkHandler *handler = [StubJamDeeplinkHandler new];
    handler->joinSheetPresenter = presenter;
    handler->userCapabilities[5] = 1; // canShowPremiumUpsell = 1 (BASIC default)
    handler->userCapabilities[6] = 1; // canShowPremiumGatedStartJamEntryPoint = 1
    check(SGJamForceUserCapabilities(handler));
    check(handler->userCapabilities[0] == 1 && handler->userCapabilities[1] == 1 &&
          handler->userCapabilities[2] == 1 && handler->userCapabilities[3] == 1 &&
          handler->userCapabilities[4] == 1 && handler->userCapabilities[5] == 0 &&
          handler->userCapabilities[6] == 0);
    check(presenter->userCapabilities[4] == 1 && presenter->userCapabilities[5] == 0);
    check(handler->isNearbyJamInviteDeeplinkEnabled == 1 && handler->isJoinSheetFromJoinOptionsEnabled == 1);
    puts("PASS: Jam product-state EXPANDED tier and deeplink userCapabilities unlock remote Jam invites without upsell");
} return 0; }
