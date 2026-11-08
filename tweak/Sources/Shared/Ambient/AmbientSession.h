#import <Foundation/Foundation.h>

// Called on the audio-session caller's thread; only atomics, no engine or UI work.
BOOL SGAmbientDeferSessionDeactivation(BOOL active, NSUInteger options);
