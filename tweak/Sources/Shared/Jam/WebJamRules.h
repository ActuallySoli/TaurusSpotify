// Web Jam's transport-free rules: what a guest pasted, how it becomes a track, and
// how its text leaves this process. Foundation only, so the Mac fixture compiles it.
#import <Foundation/Foundation.h>

// The 22-character track id in a bare id, a spotify:track: URI or an
// https://open.spotify.com/track/ link; nil for anything else.
NSString *SGWebJamTrackID(NSString *input);
NSString *SGWebJamRequestURI(NSString *input);
NSString *SGWebJamDisplayName(id value);
// spotify:track:<id> for a valid id, nil otherwise.
NSString *SGWebJamURIForTrackID(NSString *trackID);
NSString *SGWebJamCoverURL(NSDictionary *metadata);
// A JSON string literal, quotes included; control characters escaped.
NSString *SGWebJamJSONString(NSString *value);
// Text safe inside HTML body text or a quoted attribute.
NSString *SGWebJamHTMLEscape(NSString *value);
