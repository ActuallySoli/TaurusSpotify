#import <Foundation/Foundation.h>

@class UIViewController;

#define SGKeyAutoMix @"spotifyglass.automix"
#define SGKeyAutoMixStyle @"spotifyglass.automix.style"
#define SGKeyAutoMixLength @"spotifyglass.automix.length"
#define SGKeyAutoMixPlaylists @"spotifyglass.automix.playlists"
#define SGKeyAutoMixAlbums @"spotifyglass.automix.albums"
#define SGKeyAutoMixLikedSongs @"spotifyglass.automix.likedsongs"
#define SGKeyAutoMixRadio @"spotifyglass.automix.radio"
#define SGKeyAutoMixQueue @"spotifyglass.automix.queue"
#define SGKeyAutoMixAutoplay @"spotifyglass.automix.autoplay"

extern NSNotificationName const SGAutoMixStatusDidChangeNotification;

BOOL SGAutoMixEnabled(void);
BOOL SGAutoMixSupportedVersion(NSString *version);
BOOL SGAutoMixContextAllowed(NSString *uri);
NSInteger SGAutoMixBlendSeconds(void);
BOOL SGAutoMixUsesBeatMatching(void);
BOOL SGAutoMixTrackAllowed(NSString *uri, NSString *provider);
BOOL SGAutoMixHasTransition(NSDictionary *metadata);
NSDictionary *SGAutoMixContextMetadata(NSString *uri, NSDictionary *metadata);
id SGAutoMixCopyContext(id context);
id SGAutoMixCopyRequest(id request, BOOL nested);
NSData *SGAutoMixConfiguration(NSData *configuration);

void SGAutoMixPreferencesAvailable(id preferences);
void SGAutoMixPreferenceChanged(id preferences, NSString *key, id value);
void SGAutoMixPlayerStateChanged(id state);
void SGAutoMixPlayerAvailable(id player);
BOOL SGAutoMixApplyCurrentPlayback(void);
BOOL SGAutoMixPreviewTransition(void);
void SGAutoMixSettingsChanged(void);
void SGAutoMixRestorePreferences(void);
NSString *SGAutoMixStatus(void);
NSString *SGAutoMixLastTransition(void);   // "time · outgoing selection · song" for an observed track change
NSString *SGAutoMixTransitionDetails(void);
// The fade window this playback carries the song into the next one with, in seconds of the song:
// YES while a window exists, start/end in *outStart/*outEnd and the incoming song's title in *outNext.
BOOL SGAutoMixMixWindow(double *outStart, double *outEnd, NSString **outNext);
UIViewController *SGAutoMixSettingsPage(void);
