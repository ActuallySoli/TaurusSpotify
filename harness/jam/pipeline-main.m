// Reuse the pipeline boundary fixture and add a read-only Web Jam stage.
// Spatial reverb is outside this fixture; its unavailable case leaves Sing's default path intact.
#import "Shared/AudioEffects/SGDSPEffects.h"
#import <Foundation/Foundation.h>
SGDSPReverb *SGDSPReverbCreate(double rate, int preset, double amount) { return NULL; }
void SGDSPReverbRun(void *reverb, float *left, float *right, uint32_t frames) {}
void SGDSPReverbFree(void *reverb) {}
void SGLogMessage(NSString *message) {}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wreturn-type"
#define main unusedLegacySingFixture
#include "../audio/main.m"
#undef main
#pragma clang diagnostic pop
static unsigned webCalls;
static OSStatus webOutput(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
    UInt32 bus, UInt32 frames, AudioBufferList *data) {
    assert(stageSequence % 1000 == 123);
    webCalls++;
    return noErr;
}
int main(void) { @autoreleasepool {
    static const SGAudioProcessor web = {NULL, webOutput};
    static const SGAudioProcessor a = {NULL, speed}, b = {NULL, effects}, c = {NULL, haptics};
    assert(SGAudioPipelineRegister(SGAudioStageWebJam, &web));
    assert(SGAudioPipelineRegister(SGAudioStageHaptics, &c));
    assert(SGAudioPipelineRegister(SGAudioStageSpeedPitch, &a));
    assert(SGAudioPipelineRegister(SGAudioStageEffects, &b));
    AudioStreamBasicDescription format = {44100, kAudioFormatLinearPCM,
        kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, 2, 32, 0};
    Unit source = {.format = format, .limit = 256}, output = {.output = true, .format = format, .limit = 1024};
    connect(&source, &output, 7); start(unit(&output));
    assert(render(&output, 700) == noErr);
    assert(source.renders == 3 && source.frames == 700);
    AudioUnitRenderActionFlags flags = kAudioUnitRenderAction_PostRender;
    rendered(unit(&output), &flags, NULL, 0, 700, &buffers.list);
    assert(stageSequence == 123 && stageCalls == 3 && webCalls == 1);
    assert(pcm[0][0] == 2.5f);
    flags |= kAudioUnitRenderAction_PostRenderError;
    rendered(unit(&output), &flags, NULL, 0, 700, &buffers.list);
    assert(webCalls == 1);
    dispose(unit(&output)); dispose(unit(&source));
    puts("PASS: Web Jam stage follows effects, preserves host output and skips render errors");
    return 0;
} }
