#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import "Shared/Audio/SGAudioPipeline.h"
#import <assert.h>
#import <pthread.h>
static const SGAudioProcessor *registered;
static AudioStreamBasicDescription testFormat;
bool SGAudioPipelineRegister(SGAudioStage stage, const SGAudioProcessor *processor) {
    assert(stage == SGAudioStageWebJam); registered = processor; return true;
}
OSStatus AudioUnitGetProperty(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope,
    AudioUnitElement element, void *data, UInt32 *size) {
    memcpy(data, &testFormat, sizeof testFormat); return noErr;
}
#import "../../tweak/Sources/Shared/Jam/WebJamAudio.m"
static void check(BOOL ok, const char *message) { if (!ok) { fprintf(stderr, "FAIL %s\n", message); exit(1); } printf("PASS %s\n", message); }
static uint32_t number(const uint8_t *p) { return p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static void prepare(BOOL planar, unsigned channels, unsigned rate) {
    testFormat = (AudioStreamBasicDescription){rate, kAudioFormatLinearPCM,
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
        4 * (planar ? 1 : channels), 1, 4 * (planar ? 1 : channels), channels, 32, 0};
    registered->prepare((AudioUnit)1);
}
static void feed(unsigned frames, BOOL planar, unsigned channels) {
    float left[4096], right[4096];
    for (unsigned i = 0; i < 4096; i++) { left[i] = channels == 2 && !planar && i % 2 ? -.25 : .5; right[i] = -.25; }
    struct { AudioBufferList list; AudioBuffer extra; } buffers;
    buffers.list.mNumberBuffers = planar ? channels : 1;
    buffers.list.mBuffers[0] = (AudioBuffer){planar ? 1 : channels, frames * sizeof(float) * (planar ? 1 : channels), left};
    if (planar && channels == 2) buffers.list.mBuffers[1] = (AudioBuffer){1, frames * sizeof(float), right};
    AudioUnitRenderActionFlags flags = kAudioUnitRenderAction_PostRender;
    AudioTimeStamp time = {0};
    registered->output(&buffers, &flags, &time, 0, frames, &buffers.list);
    assert(left[0] == .5 && right[0] == -.25);
}
static NSData *next(uint32_t epoch, uint32_t seq) {
    __block NSData *packet;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    SGWebJamAudioNext(epoch, seq, ^(NSData *data) { packet = data; dispatch_semaphore_signal(sem); });
    assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    return packet;
}
static void fill(BOOL planar, unsigned channels, unsigned count) {
    for (unsigned i = 0; i < count; i++) { feed(1000, planar, channels); dispatch_sync(sg_audioQueue, ^{ drainAudio(); }); }
}
static void *stressProducer(void *unused) { for (int i = 0; i < 5000; i++) feed(256, YES, 2); return NULL; }
int main(void) { @autoreleasepool {
    check(registered != NULL, "audio registers after the existing output effects");
    prepare(YES, 2, 48000); SGWebJamAudioStart(); SGWebJamAudioUpdate(YES, @"song-a", 0);
    fill(YES, 2, 24);
    NSData *packet = next(0, 0); const uint8_t *p = packet.bytes;
    check(packet.length == 16 + 44 + 48000 && !memcmp(p, "WJAM", 4) && !memcmp(p + 16, "RIFF", 4), "live packet has a complete quarter-second WAV");
    check(number(p + 40) == 48000 && p[38] == 2, "WAV retains stereo and the output sample rate");
    const int16_t *samples = (const int16_t *)(p + 60);
    check(samples[0] >= 16383 && samples[0] <= 16384 && samples[1] == -8192, "stereo samples survive conversion without modifying host buffers");
    uint32_t epoch = number(p + 4), sequence = number(p + 8);
    NSData *following = next(epoch, sequence);
    check(following && number((const uint8_t *)following.bytes + 8) == sequence + 1, "guest cursors read consecutive segments");
    check(next(epoch, number((const uint8_t *)following.bytes + 8)) == nil, "caught-up guests get no duplicate audio");
    [packet writeToFile:@"harness/jam/build/audio-packet.bin" atomically:YES];
    SGWebJamAudioUpdate(NO, @"song-a", .5);
    check(next(epoch, sequence) == nil && ![SGWebJamAudioStatus()[@"ready"] boolValue], "pause revokes buffered audio immediately");
    SGWebJamAudioUpdate(YES, @"song-b", 0); fill(YES, 2, 12);
    packet = next(epoch, sequence); p = packet.bytes;
    check(packet && number(p + 4) != epoch && number(p + 12) == 1, "track changes reset the guest stream");
    SGWebJamAudioUpdate(YES, @"song-b", 80);
    check(next(number(p + 4), number(p + 8)) == nil, "seek revokes pre-seek packets");
    prepare(NO, 2, 44100); fill(NO, 2, 12);
    packet = next(0, 0); p = packet.bytes; samples = (const int16_t *)(p + 60);
    check(number(p + 40) == 44100 && samples[0] >= 16383 && samples[1] == -8192, "interleaved 44.1 kHz stereo is supported");
    prepare(YES, 1, 48000); fill(YES, 1, 12);
    packet = next(0, 0); samples = (const int16_t *)((const uint8_t *)packet.bytes + 60);
    check(samples[0] == samples[1], "mono is duplicated into both guest channels");
    testFormat.mBitsPerChannel = 16; registered->prepare((AudioUnit)1);
    check(![SGWebJamAudioStatus()[@"supported"] boolValue] && next(0, 0) == nil, "unsupported output formats fail closed");
    prepare(YES, 2, 48000);
    pthread_t producer; pthread_create(&producer, NULL, stressProducer, NULL);
    for (int i = 0; i < 100; i++) { SGWebJamAudioUpdate(i % 2, @"stress", i); (void)SGWebJamAudioStatus(); }
    pthread_join(producer, NULL);
    dispatch_sync(sg_audioQueue, ^{ drainAudio(); check(sg_segments.count <= kAudioRecent, "retained audio stays bounded under render pressure"); });
    SGWebJamAudioStop(); check(next(0, 0) == nil, "Stop revokes all audio");
    SGWebJamAudioStart(); SGWebJamAudioUpdate(YES, @"new-session", 0); fill(YES, 2, 12);
    check(next(0, 0) != nil, "audio restarts after Stop without stale samples");
    SGWebJamAudioStop(); dispatch_sync(sg_audioQueue, ^{});
    puts("PASS: Web Jam production audio capture, WAV transport and lifecycle");
} return 0; }
