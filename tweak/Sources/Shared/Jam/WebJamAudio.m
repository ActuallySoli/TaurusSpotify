#import "WebJamAudio.h"
#import "Shared/Audio/SGAudioPipeline.h"
#import "Shared/Audio/SGAudioRingBuffer.h"
#import <mach/mach_time.h>
#include <stdatomic.h>
#include <math.h>
#include <string.h>

enum { kAudioFrames = 2048, kAudioPackets = 128, kAudioRecent = 16 };
static SGAudioRingBuffer *sg_audioRing;
static dispatch_queue_t sg_audioQueue;
static dispatch_source_t sg_audioTimer;
static atomic_bool sg_capture;
static atomic_uint sg_audioEpoch = 1, sg_audioRate, sg_audioChannels, sg_audioPlanar;
static BOOL sg_registered, sg_audioStarted, sg_wasPlaying;
static NSString *sg_audioTrack;
static double sg_position, sg_positionAt, sg_tickSeconds;

// Producer only. Storage remains allocated for the process lifetime.
static float sg_copy[kAudioFrames * 2];
static uint64_t sg_sourceFrame;

// Worker only.
static float sg_read[kAudioFrames * 2];
static NSMutableData *sg_pcm;
static NSMutableArray<NSDictionary *> *sg_segments;
static uint32_t sg_workerEpoch, sg_workerRate, sg_sequence;
static uint64_t sg_expectedFrame;
static double sg_receivedAt;

static double monotonic(void) { return mach_absolute_time() * sg_tickSeconds; }

static void clearAudio(void) {
    sg_pcm = [NSMutableData data];
    sg_segments = [NSMutableArray array];
    sg_workerRate = 0;
    sg_expectedFrame = UINT64_MAX;
    sg_receivedAt = 0;
}

static void little16(uint8_t *p, uint16_t n) { p[0] = n; p[1] = n >> 8; }
static void little32(uint8_t *p, uint32_t n) {
    p[0] = n; p[1] = n >> 8; p[2] = n >> 16; p[3] = n >> 24;
}

static NSData *wave(NSData *pcm, uint32_t rate) {
    NSMutableData *data = [NSMutableData dataWithLength:44 + pcm.length];
    uint8_t *p = data.mutableBytes;
    memcpy(p, "RIFF", 4); little32(p + 4, (uint32_t)pcm.length + 36);
    memcpy(p + 8, "WAVEfmt ", 8); little32(p + 16, 16);
    little16(p + 20, 1); little16(p + 22, 2);
    little32(p + 24, rate); little32(p + 28, rate * 4);
    little16(p + 32, 4); little16(p + 34, 16);
    memcpy(p + 36, "data", 4); little32(p + 40, (uint32_t)pcm.length);
    memcpy(p + 44, pcm.bytes, pcm.length);
    return data;
}

static void drainAudio(void) {
    uint32_t epoch = atomic_load_explicit(&sg_audioEpoch, memory_order_acquire);
    if (sg_workerEpoch != epoch) { clearAudio(); sg_workerEpoch = epoch; }
    SGAudioStamp stamp;
    while (SGAudioRingRead(sg_audioRing, &stamp, sg_read)) {
        if (!atomic_load_explicit(&sg_capture, memory_order_acquire) || stamp.generation != epoch ||
            monotonic() - stamp.track * sg_tickSeconds > 0.8) continue;
        if (sg_workerRate != stamp.format || sg_expectedFrame != stamp.sourceFrame) {
            clearAudio();
            sg_workerRate = stamp.format;
        }
        sg_expectedFrame = stamp.sourceFrame + stamp.frames;
        sg_receivedAt = monotonic();
        NSUInteger oldSize = sg_pcm.length;
        [sg_pcm increaseLengthBy:stamp.frames * 4];
        uint8_t *out = (uint8_t *)sg_pcm.mutableBytes + oldSize;
        for (uint32_t i = 0; i < stamp.frames * 2; i++) {
            float sample = sg_read[i];
            if (!isfinite(sample)) sample = 0;
            int16_t value = (int16_t)lrintf(fmaxf(-1, fminf(1, sample)) * 32767);
            little16(out + i * 2, (uint16_t)value);
        }
        NSUInteger size = (sg_workerRate / 4) * 4;
        while (size && sg_pcm.length >= size) {
            NSData *pcm = [sg_pcm subdataWithRange:NSMakeRange(0, size)];
            [sg_pcm replaceBytesInRange:NSMakeRange(0, size) withBytes:NULL length:0];
            [sg_segments addObject:@{@"sequence": @(++sg_sequence), @"wave": wave(pcm, sg_workerRate)}];
            if (sg_segments.count > kAudioRecent) [sg_segments removeObjectAtIndex:0];
        }
    }
}

static OSStatus audioOutput(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                            UInt32 bus, UInt32 frames, AudioBufferList *data) {
    if (!atomic_load_explicit(&sg_capture, memory_order_acquire) || !sg_audioRing ||
        !flags || !(*flags & kAudioUnitRenderAction_PostRender) ||
        (*flags & kAudioUnitRenderAction_PostRenderError) || !data || !frames) return noErr;
    uint32_t rate = atomic_load(&sg_audioRate), channels = atomic_load(&sg_audioChannels);
    BOOL planar = atomic_load(&sg_audioPlanar);
    if (!rate || !channels || data->mNumberBuffers != (planar ? channels : 1)) return noErr;
    for (uint32_t b = 0; b < data->mNumberBuffers; b++) {
        uint32_t stride = planar ? 1 : channels;
        if (!data->mBuffers[b].mData || data->mBuffers[b].mNumberChannels != stride ||
            (uint64_t)frames * stride * sizeof(float) > data->mBuffers[b].mDataByteSize) return noErr;
    }
    uint32_t epoch = atomic_load_explicit(&sg_audioEpoch, memory_order_acquire);
    const float *left = data->mBuffers[0].mData;
    const float *right = planar && channels == 2 ? data->mBuffers[1].mData : left;
    uint32_t stride = planar ? 1 : channels;
    if (!planar && channels == 2) right++;
    for (uint32_t offset = 0; offset < frames;) {
        uint32_t count = MIN(kAudioFrames, frames - offset);
        for (uint32_t i = 0; i < count; i++) {
            BOOL silent = (*flags & kAudioUnitRenderAction_OutputIsSilence) != 0;
            sg_copy[i * 2] = silent ? 0 : left[(size_t)(offset + i) * stride];
            sg_copy[i * 2 + 1] = silent ? 0 : right[(size_t)(offset + i) * stride];
        }
        SGAudioStamp stamp = {epoch, mach_absolute_time(), sg_sourceFrame, rate, count};
        SGAudioRingWrite(sg_audioRing, stamp, sg_copy);
        sg_sourceFrame += count;
        offset += count;
    }
    return noErr;
}

static void audioPrepare(AudioUnit output) {
    AudioStreamBasicDescription format = {0}; UInt32 size = sizeof format;
    BOOL supported = AudioUnitGetProperty(output, kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Output, 0, &format, &size) == noErr &&
        format.mFormatID == kAudioFormatLinearPCM && (format.mFormatFlags & kAudioFormatFlagIsFloat) &&
        !(format.mFormatFlags & kAudioFormatFlagIsBigEndian) && format.mBitsPerChannel == 32 &&
        format.mSampleRate >= 8000 && format.mSampleRate <= 192000 &&
        (format.mChannelsPerFrame == 1 || format.mChannelsPerFrame == 2) &&
        format.mBytesPerFrame == sizeof(float) * ((format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : format.mChannelsPerFrame);
    atomic_store(&sg_audioRate, supported ? (uint32_t)format.mSampleRate : 0);
    atomic_store(&sg_audioChannels, supported ? format.mChannelsPerFrame : 0);
    atomic_store(&sg_audioPlanar, (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0);
    atomic_fetch_add_explicit(&sg_audioEpoch, 1, memory_order_release);
}

__attribute__((constructor)) static void installAudio(void) {
    mach_timebase_info_data_t timebase; mach_timebase_info(&timebase);
    sg_tickSeconds = (double)timebase.numer / timebase.denom / 1e9;
    sg_audioQueue = dispatch_queue_create("spotifyglass.webjam.audio", DISPATCH_QUEUE_SERIAL);
    sg_audioRing = SGAudioRingCreate(kAudioPackets, kAudioFrames, 2);
    static const SGAudioProcessor processor = {audioPrepare, audioOutput};
    sg_registered = sg_audioRing && SGAudioPipelineRegister(SGAudioStageWebJam, &processor);
}

void SGWebJamAudioStart(void) {
    if (sg_audioStarted || !sg_registered) return;
    sg_audioStarted = YES;
    sg_audioTrack = nil; sg_wasPlaying = NO; sg_positionAt = 0;
    atomic_fetch_add_explicit(&sg_audioEpoch, 1, memory_order_release);
    sg_audioTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sg_audioQueue);
    dispatch_source_set_timer(sg_audioTimer, DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(sg_audioTimer, ^{ drainAudio(); });
    dispatch_resume(sg_audioTimer);
}

void SGWebJamAudioStop(void) {
    atomic_store_explicit(&sg_capture, false, memory_order_release);
    atomic_fetch_add_explicit(&sg_audioEpoch, 1, memory_order_release);
    sg_audioStarted = NO; sg_wasPlaying = NO; sg_audioTrack = nil;
    if (sg_audioTimer) dispatch_source_cancel(sg_audioTimer);
    sg_audioTimer = nil;
    dispatch_async(sg_audioQueue, ^{ drainAudio(); clearAudio(); });
}

void SGWebJamAudioUpdate(BOOL playing, NSString *uri, double position) {
    playing = playing && sg_audioStarted;
    double now = monotonic();
    BOOL seek = sg_positionAt > 0 && playing && sg_wasPlaying && isfinite(position) &&
        fabs((position - sg_position) - (now - sg_positionAt)) > 1.5;
    if (playing != sg_wasPlaying || ![sg_audioTrack isEqualToString:uri ?: @""] || seek) {
        atomic_store_explicit(&sg_capture, false, memory_order_release);
        atomic_fetch_add_explicit(&sg_audioEpoch, 1, memory_order_release);
        sg_audioTrack = [uri ?: @"" copy];
    }
    sg_position = isfinite(position) ? position : 0; sg_positionAt = now; sg_wasPlaying = playing;
    atomic_store_explicit(&sg_capture, playing, memory_order_release);
}

NSDictionary *SGWebJamAudioStatus(void) {
    __block NSDictionary *status;
    dispatch_sync(sg_audioQueue, ^{
        uint32_t epoch = atomic_load(&sg_audioEpoch);
        BOOL ready = atomic_load(&sg_capture) && sg_workerEpoch == epoch &&
            sg_segments.count > 0 && monotonic() - sg_receivedAt < 1.0;
        status = @{@"supported": @(sg_registered && atomic_load(&sg_audioRate) > 0),
            @"ready": @(ready), @"epoch": @(epoch)};
    });
    return status;
}

void SGWebJamAudioNext(uint32_t epoch, uint32_t after, void (^done)(NSData *)) {
    dispatch_async(sg_audioQueue, ^{
        uint32_t current = atomic_load(&sg_audioEpoch);
        if (!atomic_load(&sg_capture) || sg_workerEpoch != current || !sg_segments.count ||
            monotonic() - sg_receivedAt >= 1.0) { done(nil); return; }
        NSDictionary *segment = nil;
        BOOL reset = epoch != current || !after || after < [sg_segments.firstObject[@"sequence"] unsignedIntValue] - 1 ||
            after > [sg_segments.lastObject[@"sequence"] unsignedIntValue];
        if (reset) segment = sg_segments[sg_segments.count > 2 ? sg_segments.count - 2 : 0];
        else for (NSDictionary *candidate in sg_segments)
            if ([candidate[@"sequence"] unsignedIntValue] > after) { segment = candidate; break; }
        if (!segment) { done(nil); return; }
        NSMutableData *packet = [NSMutableData dataWithLength:16];
        uint8_t *bytes = packet.mutableBytes;
        memcpy(bytes, "WJAM", 4); little32(bytes + 4, current);
        little32(bytes + 8, [segment[@"sequence"] unsignedIntValue]); little32(bytes + 12, reset);
        [packet appendData:segment[@"wave"]];
        if (current != atomic_load(&sg_audioEpoch)) { done(nil); return; }
        done(packet);
    });
}
