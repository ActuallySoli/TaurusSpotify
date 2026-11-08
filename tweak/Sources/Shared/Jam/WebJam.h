// Web Jam: a page on this iPhone's Wi-Fi where guests with stock Spotify add a
// song to the Local Jam queue from a browser. The rules are in WebJamRules,
// the listener and request flow in WebJam.m, the two pages in WebJamPage.m.
#import <Foundation/Foundation.h>

#define SGKeyWebJam @"spotifyglass.jam.web"
#define SGWebJamPort 8787

@class UIViewController;

extern NSNotificationName SGWebJamDidChangeNotification;

BOOL SGWebJamEnabled(void);
BOOL SGWebJamRunning(void);
NSString *SGWebJamStatus(void);      // on/off, or the listener's error
NSString *SGWebJamJoinURL(void);     // http://<wifi-ip>:8787, nil unless ready on Wi-Fi
void SGWebJamSetEnabled(BOOL on);    // stores the switch and starts or stops now
void SGWebJamRuntimeStart(void);     // at launch: start when the stored switch is on

// Mod Settings: the switch, the address and its QR code (WebJamPage.m).
UIViewController *SGWebJamPage(void);
// The guest page served at / (WebJamPage.m); all guest data goes in text nodes.
NSString *SGWebJamHTMLPage(void);
