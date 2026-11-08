#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Home.h"

UIViewController *SGRHomeSettingsPage(void) {
    SGModRow *topPicks = SGOptionRow(@"Top picks", @"Draw Home's first shelf large", SGRKeyHomeTopPicks);
    SGModRow *topPicksColor = SGSwitchRow(@"Colour behind Top picks", @"A glow from the leading card's cover", SGRKeyHomeTopPicksColor);
    NSArray<SGModRow *> *onHome = @[
        SGHideRow(@"Shortcuts", @"The two-column grid at the top of Home", SGRKeyHomeHideShortcuts),
        SGHideRow(@"DJ", nil, SGRKeyHomeHideDJ),
        SGOptionRow(@"Song suggestions", @"Songs you might like carousel", SGRKeyHomeShowSuggestions),
        SGOptionRow(@"Video and playlist previews", @"Tall muted preview cards", SGRKeyHomeShowPreviews),
    ];
    return [[SGModPage alloc] initWithTitle:@"Home"
                                      intro:nil
                                   sections:@[
                                       SGSection(@"Top picks", @[topPicks, topPicksColor]),
                                       SGSection(@"On Home", onHome),
                                   ]
                                     footer:@"Changes apply after restarting Spotify."];
}
