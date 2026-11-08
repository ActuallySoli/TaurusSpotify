#import <Foundation/Foundation.h>

static inline NSUInteger SGRLyricsShaderFrameRate(NSProcessInfoThermalState thermal, BOOL lowPower) {
    if (thermal >= NSProcessInfoThermalStateCritical) return 0;
    if (thermal >= NSProcessInfoThermalStateSerious) return 15;
    return lowPower || thermal >= NSProcessInfoThermalStateFair ? 30 : 60;
}
