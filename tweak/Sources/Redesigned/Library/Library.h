#import <UIKit/UIKit.h>

#define SGRKeyLibraryHideChips @"spotifyglass.redesign.library.hideChips"

BOOL SGRLibraryHideChipsOn(void);
UIViewController *SGRLibrarySettingsPage(void);

// The list of every library page (trees/clean/library/03.txt:25).
extern NSString *const SGRLibraryListIdentifier;

void SGRLibraryClearScrim(UIView *header);
