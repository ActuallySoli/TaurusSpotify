#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Album.h"

UIViewController *SGRAlbumSettingsPage(void) {
    SGModRow *fullCover = SGSwitchRow(@"Full screen cover", @"Spread the album cover edge to edge behind the title", SGRKeyAlbumFullCover);
    SGModRow *notesPlace = SGChoiceRow(@"Album notes", @"Where Apple Music's editorial notes appear", SGRKeyAlbumNotesPlace,
                                       @[@"Under the buttons", @"Below tracks", @"Off"], 0);
    NSArray<SGModSection *> *sections = @[
        SGNotedSection(@"Header", @[
            fullCover,
            SGSwitchRow(@"Animated cover", @"Apple Music's, where the album has one", SGRKeyAnimatedCovers),
            notesPlace,
            SGHideRow(@"Album notes", @"Apple Music's editorial notes under the buttons", SGRKeyAlbumHideNotes),
        ], @"Apple Music gets only the artist and album name. Nothing is downloaded in Low Data or Low Power Mode."),
        SGNotedSection(@"Track list", @[
            SGHideRow(@"Hide album artists", @"Featured artists stay visible", SGRKeyHideAlbumArtists),
            SGHideRow(@"Hide all track artists", @"Including featured artists", SGRKeyHideAllAlbumArtists),
            SGHideRow(@"Hide explicit tags", @"Next to track artists", SGRKeyHideExplicitAlbumTags),
        ], nil),
        SGSection(@"Under the tracks", @[
            SGHideRow(@"More by the artist", nil, SGRKeyAlbumHideMoreBy),
            SGHideRow(@"Music videos", nil, SGRKeyAlbumHideVideos),
            SGHideRow(@"On tour", nil, SGRKeyAlbumHideConcerts),
            SGHideRow(@"Merch", nil, SGRKeyAlbumHideMerch),
            SGHideRow(@"You might also like", nil, SGRKeyAlbumHideYouMightLike),
        ]),
    ];
    return [[SGModPage alloc] initWithTitle:@"Albums" intro:nil sections:sections footer:@"Changes apply after restarting Spotify."];
}
