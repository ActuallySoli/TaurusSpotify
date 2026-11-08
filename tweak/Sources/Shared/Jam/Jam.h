#import <Foundation/Foundation.h>
@class SGModSection;

#define SGKeyJamControls @"spotifyglass.jam.controls"
#define SGKeyJamAccountIdentity @"spotifyglass.jam.accountIdentity"
#define SGKeyJamUnlock @"spotifyglass.jam.unlock"

NSNumber *SGJamForcedFlag(NSString *key);
NSString *SGJamProductStateValueForKey(NSString *key);
BOOL SGJamForceUserCapabilities(id target);
BOOL SGJamUsesAccountIdentity(void);
BOOL SGJamOpenStartSheet(void);   // Spotify's own Start a Jam dialog, through its URI subtype registry
SGModSection *SGJamSettingsSection(void);
extern NSNotificationName const SGJamStatusDidChangeNotification;
NSString *SGJamLastResult(void);
NSString *SGJamLastFailure(void);
void SGJamObserveResponse(NSURLSessionTask *task, NSURLResponse *response);
void SGJamObserveData(NSURLSessionTask *task, NSData *data);
void SGJamObserveError(NSURLSessionTask *task, NSError *error);

// A recognized account rejection, without invitation tokens or server response text.
NSString *SGJamAccountRejection(NSURLRequest *request, NSData *body);
