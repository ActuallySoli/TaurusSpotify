#import <UIKit/UIKit.h>

// Apple Music's animated cover at the top of an album (AlbumHeader.x); on until switched off.
#define SGRKeyAnimatedCovers @"spotifyglass.redesign.animatedcovers"
#define SGRKeyAlbumFullCover @"spotifyglass.redesign.album.fullCover"
#define SGRKeyAlbumNotesPlace @"spotifyglass.redesign.album.notesPlace"
#define SGRKeyAlbumHideNotes @"spotifyglass.redesign.album.hideNotes"
#define SGRKeyHideAlbumArtists @"spotifyglass.redesign.hideAlbumArtists"
#define SGRKeyHideAllAlbumArtists @"spotifyglass.redesign.hideAllAlbumArtists"
#define SGRKeyHideExplicitAlbumTags @"spotifyglass.redesign.hideExplicitAlbumTags"
#define SGRKeyAlbumHideMoreBy @"spotifyglass.redesign.album.hideMoreBy"
#define SGRKeyAlbumHideVideos @"spotifyglass.redesign.album.hideVideos"
#define SGRKeyAlbumHideConcerts @"spotifyglass.redesign.album.hideConcerts"
#define SGRKeyAlbumHideMerch @"spotifyglass.redesign.album.hideMerch"
#define SGRKeyAlbumHideYouMightLike @"spotifyglass.redesign.album.hideYouMightLike"

UIViewController *SGRAlbumSettingsPage(void);

UIView *SGRAlbumPageOf(UIView *view);

UIColor *SGRAlbumFieldColor(UIView *view);
// The cover of the page `view` is on, for its field to take its colour from. The same image again is a no-op.
void SGRAlbumSetArtwork(UIView *view, UIImage *image);
