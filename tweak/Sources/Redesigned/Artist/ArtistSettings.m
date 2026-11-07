// The redesign's artist page settings.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Artist.h"

UIViewController *SGRArtistSettingsPage(void) {
    return [[SGModPage alloc] initWithTitle:@"Artists" intro:SGRestartNote sections:@[
        SGNotedSection(@"Apple Music", @[
            SGSwitchRow(@"Apple Music artist photo", @"Editorial portrait in place of Spotify's", SGRKeyArtistApplePhoto),
            SGSwitchRow(@"Animated artist artwork", @"Apple Music's motion video at the top of the page", SGRKeyArtistMotion),
            SGSwitchRow(@"Artist logo", @"In place of the name when a logo is available", SGRKeyArtistLogo),
        ], @"Only the artist's name is sent to Apple Music. Nothing is downloaded in Low Data or Low Power Mode."),
        SGSection(@"Tabs", @[
            SGHideRow(@"Video, Events and Merch tabs", nil, SGRKeyArtistHideTabs),
        ]),
        SGSection(@"On the page", @[
            SGHideRow(@"Music videos", nil, SGRKeyArtistHideVideos),
            SGHideRow(@"Artist pick", nil, SGRKeyArtistHidePick),
            SGHideRow(@"Release countdown", nil, SGRKeyArtistHideCountdown),
            SGHideRow(@"About", nil, SGRKeyArtistHideAbout),
        ]),
    ] footer:nil];
}
