// The Visualizer's spectrum (SGRSpectrum.h): a ring of the last kSize samples, analyzed every kHop.
#import <Accelerate/Accelerate.h>
#import <math.h>
#import <stdatomic.h>
#import <string.h>
#import "SGRSpectrum.h"
#import "Core/SGCore.h"
#import "Shared/Audio/SGAudioPipeline.h"

enum { kLog2Size = 12, kSize = 1 << kLog2Size, kHalf = kSize / 2, kHop = 1024 };
// The bands' edges: a kick's fundamental at the bottom, the air of cymbals at the top.
static const double kLowest = 50, kHighest = 14000;

// Main thread, once, before the render thread reads them.
static FFTSetup sg_setup;
static float sg_window[kSize];
static atomic_bool sg_prepared;

// The render thread's own.
static float sg_ring[kSize], sg_windowed[kSize], sg_real[kHalf], sg_imag[kHalf], sg_power[kHalf];
static uint32_t sg_at, sg_sinceLast, sg_filled;
static double sg_rate;
static uint32_t sg_from[SGRSpectrumBands], sg_to[SGRSpectrumBands];   // bins, the end not included

// Published.
static _Atomic(float) sg_levels[SGRSpectrumBands];
static _Atomic(uint64_t) sg_generation;
static atomic_bool sg_reading;

void SGRSpectrumSetReading(id owner, BOOL reading) {
    static NSHashTable *owners;
    if (!owners) owners = [NSHashTable weakObjectsHashTable];
    if (owner) {
        if (reading) [owners addObject:owner];
        else [owners removeObject:owner];
    }
    atomic_store_explicit(&sg_reading, owners.allObjects.count > 0, memory_order_release);
}

void SGRSpectrumPrepare(void) {
    if (atomic_load(&sg_prepared)) return;
    sg_setup = vDSP_create_fftsetup(kLog2Size, kFFTRadix2);
    if (!sg_setup) {
        SGLog(@"redesign player: spectrum FFT allocation failed");
        return;
    }
    vDSP_hann_window(sg_window, kSize, vDSP_HANN_DENORM);
    for (int band = 0; band < SGRSpectrumBands; band++) atomic_store(&sg_levels[band], SGRSpectrumFloor);
    atomic_store_explicit(&sg_prepared, true, memory_order_release);
}

// A band takes the bins whose middles are in it, and at least one, so the low bands, narrower than a bin, still
// read something; two of them can read the same bin.
static void setRate(double rate) {
    sg_rate = rate;
    sg_at = sg_sinceLast = sg_filled = 0;
    memset(sg_ring, 0, sizeof sg_ring);
    double binHz = rate / kSize, ratio = pow(kHighest / kLowest, 1.0 / SGRSpectrumBands);
    for (int band = 0; band < SGRSpectrumBands; band++) {
        double low = kLowest * pow(ratio, band), high = low * ratio;
        uint32_t from = (uint32_t)fmax(1, ceil(low / binHz)), to = (uint32_t)fmin(kHalf, ceil(high / binHz));
        if (from >= kHalf) from = kHalf - 1;
        sg_from[band] = from;
        sg_to[band] = to > from ? to : from + 1;
    }
}

// The power over a band, summed, as a full scale sine's: a Hann window keeps 3/8 of a sine's power over its
// bins, and vDSP's real FFT gives twice the DFT, so a sine of amplitude A sums to 3/8 * kSize^2 * A^2 here.
static void analyse(void) {
    // The ring from its oldest sample, windowed.
    uint32_t tail = kSize - sg_at;
    vDSP_vmul(sg_ring + sg_at, 1, sg_window, 1, sg_windowed, 1, tail);
    vDSP_vmul(sg_ring, 1, sg_window + tail, 1, sg_windowed + tail, 1, sg_at);
    DSPSplitComplex split = {sg_real, sg_imag};
    vDSP_ctoz((const DSPComplex *)sg_windowed, 2, &split, 1, kHalf);
    vDSP_fft_zrip(sg_setup, &split, 1, kLog2Size, kFFTDirection_Forward);
    // The first bin's imaginary part is the Nyquist bin's real one, which no band reaches.
    sg_imag[0] = 0;
    vDSP_zvmags(&split, 1, sg_power, 1, kHalf);
    const float scale = 1.0f / (0.375f * (float)kSize * (float)kSize);
    for (int band = 0; band < SGRSpectrumBands; band++) {
        float sum = 0;
        vDSP_sve(sg_power + sg_from[band], 1, &sum, sg_to[band] - sg_from[band]);
        float level = sum > 0 ? 10 * log10f(sum * scale) : SGRSpectrumFloor;
        atomic_store_explicit(&sg_levels[band], fmaxf(SGRSpectrumFloor, level), memory_order_relaxed);
    }
    atomic_fetch_add_explicit(&sg_generation, 1, memory_order_release);
}

static void feedStrided(const float *samples, uint32_t count, double sampleRate, uint32_t stride) {
    if (!samples || sampleRate <= 0 || !stride || !atomic_load_explicit(&sg_prepared, memory_order_acquire)) return;
    if (sampleRate != sg_rate) setRate(sampleRate);
    while (count) {
        uint32_t run = count;
        if (run > kSize - sg_at) run = kSize - sg_at;
        if (run > kHop - sg_sinceLast) run = kHop - sg_sinceLast;
        if (stride == 1) memcpy(sg_ring + sg_at, samples, run * sizeof(float));
        else for (uint32_t i = 0; i < run; i++) sg_ring[sg_at + i] = samples[(size_t)i * stride];
        samples += (size_t)run * stride;
        count -= run;
        sg_at = (sg_at + run) & (kSize - 1);
        sg_sinceLast += run;
        if (sg_filled < kSize) sg_filled += run;
        if (sg_sinceLast == kHop) {
            sg_sinceLast = 0;
            // Not before the ring is full once: a window half of zeros would read a step in the sound.
            if (sg_filled >= kSize) analyse();
        }
    }
}

void SGRSpectrumFeed(const float *samples, uint32_t count, double sampleRate) {
    feedStrided(samples, count, sampleRate, 1);
}

uint64_t SGRSpectrumRead(float levels[SGRSpectrumBands]) {
    uint64_t generation = atomic_load_explicit(&sg_generation, memory_order_acquire);
    for (int band = 0; band < SGRSpectrumBands; band++) {
        levels[band] = atomic_load_explicit(&sg_levels[band], memory_order_relaxed);
    }
    return generation;
}

#pragma mark - the pipeline's stage

// The output's sample rate, read off the unit at prepare and read again on the render thread.
static _Atomic(double) sg_feedRate;
static _Atomic(uint32_t) sg_feedStride;

// Render thread, post-render: the finished buffer, one channel of it, into the analyser. It reads the first
// channel only: a kick in the left channel is a kick in the song, and the FFT wants mono.
static OSStatus spectrumOutput(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                               UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void)context; (void)time; (void)bus;
    if (!atomic_load_explicit(&sg_reading, memory_order_acquire)) return noErr;
    if (!flags || !(*flags & kAudioUnitRenderAction_PostRender) || (*flags & kAudioUnitRenderAction_PostRenderError)
        || !data || !data->mNumberBuffers || !frames) return noErr;
    AudioBuffer *buffer = &data->mBuffers[0];
    uint32_t stride = atomic_load_explicit(&sg_feedStride, memory_order_relaxed);
    if (!stride || buffer->mNumberChannels != stride || !buffer->mData
        || buffer->mDataByteSize < (size_t)frames * stride * sizeof(float)) return noErr;
    double rate = atomic_load_explicit(&sg_feedRate, memory_order_relaxed);
    if (rate > 0) feedStrided(buffer->mData, frames, rate, stride);
    return noErr;
}

// Off the render thread, at output start or format change: the rate the buffers play at.
static void spectrumPrepare(AudioUnit unit) {
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof format;
    double rate = 0;
    uint32_t stride = 0;
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, &size) == noErr
        && format.mFormatID == kAudioFormatLinearPCM && format.mSampleRate > 0
        && (format.mFormatFlags & kAudioFormatFlagIsFloat) && !(format.mFormatFlags & kAudioFormatFlagIsBigEndian)
        && format.mBitsPerChannel == 32 && format.mChannelsPerFrame > 0) {
        uint32_t channels = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? 1 : format.mChannelsPerFrame;
        if ((uint64_t)channels * sizeof(float) == format.mBytesPerFrame) {
            rate = format.mSampleRate;
            stride = channels;
        }
    }
    atomic_store(&sg_feedRate, rate);
    atomic_store(&sg_feedStride, stride);
}

void SGRSpectrumInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SGRSpectrumPrepare();
        static const SGAudioProcessor processor = {spectrumPrepare, spectrumOutput};
        if (!SGAudioPipelineRegister(SGAudioStageSpectrum, &processor)) {
            SGLog(@"redesign player: spectrum stage not registered, the visualiser and shader stand still");
        }
    });
}
