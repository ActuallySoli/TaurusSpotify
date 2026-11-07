#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "SGRAccent.h"
#import "Redesigned/Home/Home.h"
#import "Redesigned/Navbar/Navbar.h"

static void chooseAccent(void) {
    if (!SGRAccentColor() && ![[NSUserDefaults.standardUserDefaults arrayForKey:SGRKeyAccentRecent] count]) {
        SGRPickAccent();
        return;
    }
    UIViewController *top = SGTopController();
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Accent colour" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Pick a colour" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { SGRPickAccent(); }]];
    NSArray<NSNumber *> *recent = [NSUserDefaults.standardUserDefaults arrayForKey:SGRKeyAccentRecent];
    for (NSNumber *entry in recent) {
        if (![entry isKindOfClass:NSNumber.class]) continue;
        NSInteger rgb = entry.integerValue;
        NSString *hex = [NSString stringWithFormat:@"#%06lX", (long)rgb];
        [sheet addAction:[UIAlertAction actionWithTitle:hex style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            SGSetInt(SGRKeyAccent, rgb);
            [NSNotificationCenter.defaultCenter postNotificationName:SGRAccentDidChangeNotification object:nil];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Spotify's green" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        SGSetInt(SGRKeyAccent, -1);
        [NSNotificationCenter.defaultCenter postNotificationName:SGRAccentDidChangeNotification object:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = top.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 0, 0);
    sheet.popoverPresentationController.permittedArrowDirections = 0;
    [top presentViewController:sheet animated:YES completion:nil];
}

// The redesign's rows of the Appearance card (App/Pages.m). AMOLED has no row: the redesign is always black.
NSArray<SGModRow *> *SGRAppearanceRows(void) {
    SGModRow *profile = SGSwitchRow(@"Show profile photo", @"Show the profile photo at the top left",
                                    SGRKeyNavbarProfilePhoto);
    profile.changed = ^(BOOL on) {
        SGRNavbarRefreshProfilePhotos();
        SGRHomeProfilePhotoPreferenceChanged();
    };
    SGModRow *gradient = SGSwitchRow(@"Bottom navbar gradient", @"Show the black fade behind the bottom of the glass tab bar",
                                     SGRKeyNavbarBottomGradient);
    gradient.changed = ^(BOOL on) { SGRSetTabBarGradientVisible(on); };
    SGModRow *autoAccent = SGOptionRow(@"Automatic accent colour", @"Follows the page or song cover", SGRKeyAccentAuto);
    SGModRow *plainCheck = SGOptionRow(@"Plain checkmark", @"Without the circle on saved songs", @"spotifyglass.redesign.plaincheck");
    SGModRow *prettier = SGSwitchRow(@"Prettier icons", @"Apple Music style explicit badge", SGRKeyPrettierIcons);
    SGModRow *explicitMark = SGHideRow(@"Explicit mark", @"The E badge next to explicit tracks", SGKeyHideExplicit);
    return @[
        profile,
        gradient,
        SGWithSymbol(SGStatActionRow(@"Accent colour", nil, ^NSString *{ return SGRAccentLabel(); }, ^{ chooseAccent(); }), @"paintpalette"),
        autoAccent,
        plainCheck,
        prettier,
        explicitMark,
    ];
}
