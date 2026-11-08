#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Search.h"

UIViewController *SGRSearchSettingsPage(void) {
    SGModRow *videos = SGOptionRow(@"Short video carousels", @"Playlists you can watch and Discover something new", SGRKeySearchShowVideos);
    return [[SGModPage alloc] initWithTitle:@"Search"
                                      intro:nil
                                   sections:@[SGSection(nil, @[videos])]
                                     footer:@"Changes apply after restarting Spotify."];
}
