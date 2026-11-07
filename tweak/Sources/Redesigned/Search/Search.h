#import <UIKit/UIKit.h>

#define SGRKeySearchShowVideos @"spotifyglass.redesign.search.showVideos"

BOOL SGRSearchShowVideosOn(void);
UIViewController *SGRSearchSettingsPage(void);

// The page's list (trees/clean/search/01.txt:24).
extern NSString *const SGRSearchListIdentifier;

void SGRSearchCloseGap(UICollectionView *list);
