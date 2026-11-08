#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Library.h"

UIViewController *SGRLibrarySettingsPage(void) {
    SGModRow *chips = SGOptionRow(@"Hide filter chips", @"Playlists, Podcasts, Albums and Artists under the title", SGRKeyLibraryHideChips);
    return [[SGModPage alloc] initWithTitle:@"Library"
                                      intro:nil
                                   sections:@[SGSection(nil, @[chips])]
                                     footer:@"Changes apply after restarting Spotify."];
}
