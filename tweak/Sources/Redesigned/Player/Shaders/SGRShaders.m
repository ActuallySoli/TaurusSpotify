// Player redesign: the Shader background, an animated Metal field behind the player, in the cover's colors,
// over the Fluid field held still (PlayerField.x keeps the field Fluid for this choice, as for the Visualiser,
// so the ⋯ menu moves between all the background styles without a restart).
//
// One fragment shader draws the built-in looks, chosen by a uniform. A local profile supplies its own source. The
// Metal source is compiled once, at the first use; until it is in, the view draws nothing and the Fluid field
// shows. What moves it is the song: SGRSpectrum's bands (fed by the audio pipeline's spectrum stage,
// SGRSpectrumInstall), read and normalized here much as the Visualiser's hills read them -- the loudest band
// of late at the top, each band eased up quickly and down slowly -- plus a bass level, an overall energy and
// a beat pulse that jumps on a bass onset and decays. Core Motion's gravity leans some of the looks as the
// phone tilts.
//
// It moves only while it is in a window, Spotify is in front, the player is not opening or closing, Low Power
// Mode is off and the song plays; a pause lets it settle and the view stops. At most 60 frames a second, 30
// behind the lyrics and 15 with Reduce Motion. MTKView paused draws nothing; a playing song brings it back
// through the player state observer.
//
// Threading: main thread but for the render, which MTKView drives, and the motion updates, on a queue of
// their own.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/Player/PlayerEvents.h"
#import "Shared/Player/PlayerState.h"
#import "Redesigned/Player/Player.h"
#import "Redesigned/Player/SGRSpectrum.h"
#import "Redesigned/Player/Shaders/SGRShaders.h"
#import "SGRShaderLibrary.h"
#import "SGRShaderCompiler.h"
#import <MetalKit/MetalKit.h>
#import <CoreMotion/CoreMotion.h>
#import <stdatomic.h>

static NSNotificationName const kShaderChangedNotification = @"spotifyglass.redesign.shaderChanged";

static NSString *const kSelectedShaderID = @"spotifyglass.redesign.shader.selectedID";
static NSUInteger const kBuiltinCount = 9;
static void selectShader(void);
static void resetShaderSelection(void);

NSArray<NSString *> *SGRShaderNames(void) {
    NSMutableArray *names = [@[@"Nebula", @"Mosaic", @"Kaleido", @"Orbit", @"Smoke", @"Aurora", @"Spectrum Bars", @"Halo", @"Glass"] mutableCopy];
    for (NSDictionary *profile in SGRShaderLibrary().profiles) [names addObject:profile[@"name"]];
    return names;
}

NSInteger SGRShaderIndex(void) {
    NSString *identifier = [NSUserDefaults.standardUserDefaults stringForKey:kSelectedShaderID];
    if (identifier.length) {
        NSArray *profiles = SGRShaderLibrary().profiles;
        NSInteger resolved = 0;
        for (NSUInteger i = 0; i < profiles.count; i++) {
            if ([profiles[i][@"id"] isEqual:identifier]) {
                resolved = [SGRShaderLibrary() isQuarantined:identifier] ? 0 : kBuiltinCount + i;
                break;
            }
        }
        if (SGInt(SGRKeyShaderStyle, 0) != resolved) SGSetInt(SGRKeyShaderStyle, resolved);
        if (!resolved) [NSUserDefaults.standardUserDefaults removeObjectForKey:kSelectedShaderID];
        return resolved;
    }
    NSInteger index = SGInt(SGRKeyShaderStyle, 0);
    // Fresh installs start on Glass, the calm look; out-of-range values fall back to the first.
    if (![NSUserDefaults.standardUserDefaults objectForKey:SGRKeyShaderStyle]) return (NSInteger)kBuiltinCount - 1;
    return index >= 0 && index < (NSInteger)kBuiltinCount ? index : 0;
}

static NSDictionary *selectedProfile(void) {
    NSInteger index = SGRShaderIndex();
    NSArray *profiles = SGRShaderLibrary().profiles;
    return index >= (NSInteger)kBuiltinCount && index - kBuiltinCount < profiles.count ? profiles[index - kBuiltinCount] : nil;
}

void SGRSetShaderIndex(NSInteger index) {
    NSArray *profiles = SGRShaderLibrary().profiles;
    if (index >= (NSInteger)kBuiltinCount && index - kBuiltinCount < profiles.count)
        [NSUserDefaults.standardUserDefaults setObject:profiles[index - kBuiltinCount][@"id"] forKey:kSelectedShaderID];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:kSelectedShaderID];
    SGSetInt(SGRKeyShaderStyle, index >= 0 && index < SGRShaderNames().count ? index : 0);
    resetShaderSelection();
    selectShader();
    [NSNotificationCenter.defaultCenter postNotificationName:kShaderChangedNotification object:nil];
}

void SGRShaderLibraryDidChange(void) {
    (void)SGRShaderIndex();
    resetShaderSelection();
    selectShader();
    [NSNotificationCenter.defaultCenter postNotificationName:SGRShaderLibraryChangedNotification object:nil];
    [NSNotificationCenter.defaultCenter postNotificationName:kShaderChangedNotification object:nil];
}

#pragma mark - the shader

static NSString *const kSource = @R"METAL(
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 misc;         // time, bass, beat, energy
    float4 tilt;         // gravity x, y
    float4 opts;         // style
    float4 tints[2];     // the cover's colors
    float4 spectrum[6];  // 24 bands, low first
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// One triangle over the whole view: (0,0), (2,0), (0,2) in uv, NDC from it.
vertex VertexOut vert(uint vid [[vertex_id]]) {
    float2 p = float2((float)((vid << 1) & 2), (float)(vid & 2));
    VertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = p;
    return out;
}

static float band(constant Uniforms &u, float t) {
    float x = clamp(t, 0.0, 1.0) * 23.0;
    uint i = (uint)x, j = min(i + 1u, 23u);
    return mix(u.spectrum[i >> 2][i & 3], u.spectrum[j >> 2][j & 3], x - floor(x));
}

static float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + float2(1.0, 0.0)), w.x),
               mix(hash(i + float2(0.0, 1.0)), hash(i + float2(1.0, 1.0)), w.x), w.y);
}

static float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int k = 0; k < 4; k++) {
        v += a * noise(p);
        p = p * 2.03 + 17.1;
        a *= 0.5;
    }
    return v;
}

// Nebula: clouds adrift, thicker with the song, a few stars in them.
static float3 nebula(constant Uniforms &u, float2 uv) {
    float t = u.misc.x * 0.045;
    float2 drift = float2(t * 0.7, -t) + u.tilt.xy * 0.18;
    float n = fbm(uv * float2(2.4, 2.0) + drift);
    n = n * 0.65 + 0.35 * fbm(uv * 5.5 - drift * 1.6);
    float3 col = mix(u.tints[0].rgb, u.tints[1].rgb, smoothstep(0.15, 0.9, n));
    float stars = pow(hash(floor(uv * 240.0)), 40.0) * (0.4 + 0.6 * u.misc.y);
    return col * n * (0.35 + 0.75 * u.misc.w) + stars;
}

// Mosaic: a wall of lamps, the bass lighting the middle columns, the treble the edges.
static float3 mosaic(constant Uniforms &u, float2 uv) {
    float2 cells = float2(22.0, 14.0);
    float2 at = uv * cells;
    float2 cell = floor(at), f = fract(at) - 0.5;
    float t = 1.0 - (cell.x + cell.y * 0.6) / (cells.x + cells.y);
    float level = band(u, t);
    float flicker = 0.7 + 0.3 * sin(u.misc.x * 1.3 + dot(cell, float2(0.7, 1.3)));
    float lit = smoothstep(0.06, 0.8, level * flicker + u.misc.z * 0.2);
    float lamp = (1.0 - smoothstep(0.28, 0.46, length(f))) * (0.10 + 0.90 * lit);
    float3 col = mix(u.tints[0].rgb, u.tints[1].rgb, cell.x / cells.x);
    return col * lamp * (0.45 + 0.35 * u.misc.w);
}

// Kaleido: six folded sectors of noise, zooming with the bass, rings stepping out on the beat.
static float3 kaleido(constant Uniforms &u, float2 uv) {
    float2 p = uv - 0.5 - u.tilt.xy * 0.06;
    float r = length(p);
    float a = atan2(p.y, p.x) + u.misc.x * 0.05;
    float seg = M_PI_F / 3.0;
    a = fmod(a, seg);
    a += (a < 0.0) * seg;
    a = fabs(a - seg * 0.5);
    float zoom = 2.6 + 2.2 * u.misc.y;
    float2 q = float2(cos(a), sin(a)) * r * zoom;
    float n = fbm(q * 2.2 + u.misc.x * 0.07);
    float rings = 0.5 + 0.5 * sin(r * (22.0 + 14.0 * u.misc.z) - u.misc.x * 1.1 + n * 6.0);
    float3 col = mix(u.tints[1].rgb, u.tints[0].rgb, n);
    return col * (0.22 + 0.9 * rings) * (0.45 + 0.55 * u.misc.w) * (1.0 - smoothstep(0.15, 0.95, r));
}

// Orbit: bodies circling a core, quicker with the song, drawn out on the beat, a band lighting each ring.
static float3 orbit(constant Uniforms &u, float2 uv) {
    float2 p = uv - 0.5 - u.tilt.xy * 0.05;
    float r = length(p);
    float speed = 0.35 + 1.5 * u.misc.w;
    float3 col = float3(0.0);
    for (int k = 0; k < 5; k++) {
        float fk = (float)k;
        float radius = 0.11 + 0.085 * fk;
        float phase = u.misc.x * speed * (1.0 - 0.14 * fk) + fk * 1.9;
        float2 c = float2(cos(phase), sin(phase)) * radius * (1.0 + 0.3 * u.misc.z);
        float3 tint = mix(u.tints[0].rgb, u.tints[1].rgb, fk * 0.25);
        col += tint * (1.0 - smoothstep(0.016, 0.05, length(p - c))) * (1.0 + 2.2 * u.misc.z);
        col += tint * exp(-16.0 * fabs(r - radius)) * (0.10 + 0.30 * band(u, fk * 0.25));
    }
    col += u.tints[0].rgb * (1.0 - smoothstep(0.015, 0.09, r)) * (0.3 + 1.1 * u.misc.y);
    return col;
}

// Smoke: drifting up from the foot of the screen, thickening with the bass, leaning with the tilt.
static float3 smoke(constant Uniforms &u, float2 uv) {
    float2 p = uv * float2(1.7, 1.1);
    float rise = u.misc.x * (0.09 + 0.22 * u.misc.y);
    float n = fbm(p * 2.6 + float2(u.tilt.x * 0.8, -rise));
    n = fbm(p * 3.2 + float2(n * 1.5, -rise * 1.3) + 4.7);
    float body = smoothstep(0.38 - 0.22 * u.misc.y, 0.9, n);
    float3 col = mix(u.tints[0].rgb, u.tints[1].rgb, n);
    float foot = (1.0 - smoothstep(0.0, 0.55, uv.y));
    return col * body * (0.30 + 0.45 * u.misc.w) + u.tints[1].rgb * foot * body * 0.5;
}

// Aurora: curtains of light hanging over the field, waving with the noise, a band of the song lighting each.
static float3 aurora(constant Uniforms &u, float2 uv) {
    float t = u.misc.x * 0.12;
    float sway = u.tilt.x * 0.1;
    float curtain = fbm(float2(uv.x * 3.0 + sway, t * 0.35));
    float wave = 0.5 + 0.5 * sin(uv.x * 18.0 + curtain * 6.0 + t * 1.4);
    float hang = smoothstep(0.0, 0.55, uv.y) * (1.0 - smoothstep(0.55, 1.05, uv.y));
    float level = band(u, uv.y);
    float glow = wave * hang * (0.25 + 1.1 * level * (0.4 + 0.6 * u.misc.w));
    float3 col = mix(u.tints[0].rgb, u.tints[1].rgb, wave);
    col = mix(col, float3(0.35, 1.0, 0.65), 0.25 * u.misc.w);
    return col * glow + u.tints[1].rgb * 0.05;
}

static float3 spectrumBars(constant Uniforms &u, float2 uv) {
    float lane = floor(clamp(uv.x, 0.0, 0.999) * 24.0);
    float level = 0.025 + 0.39 * band(u, lane / 23.0);
    float above = 0.62 - uv.y;
    float below = uv.y - 0.62;
    float column = (1.0 - smoothstep(0.37, 0.43, fabs(fract(uv.x * 24.0) - 0.5)));
    float bar = step(0.0, above) * (1.0 - smoothstep(level - 0.006, level + 0.006, above));
    float reflection = step(0.0, below) * (1.0 - smoothstep(0.0, level * 0.5, below)) * 0.22;
    float3 color = mix(u.tints[0].rgb, u.tints[1].rgb, lane / 23.0);
    float floorLight = exp(-120.0 * fabs(uv.y - 0.62)) * (0.08 + u.misc.y * 0.25);
    return color * (column * (bar + reflection) * 0.8 + floorLight);
}

static float3 halo(constant Uniforms &u, float2 uv) {
    float2 p = uv - float2(0.5, 0.44) - u.tilt.xy * 0.025;
    float angle = atan2(p.y, p.x);
    float energy = band(u, fract(angle / 6.2831853 + 0.5));
    float radius = 0.23 + 0.025 * u.misc.y + 0.035 * energy;
    float ring = exp(-150.0 * fabs(length(p) - radius));
    float aura = exp(-20.0 * fabs(length(p) - radius)) * 0.16;
    float motion = 0.5 + 0.5 * sin(angle * 3.0 + u.misc.x * 0.32);
    float3 color = mix(u.tints[0].rgb, u.tints[1].rgb, motion);
    return color * (ring * (0.45 + 0.5 * u.misc.z) + aura);
}

// Glass: the calm one, no noise at all — two slow wide washes of the cover's own colors leaning with
// the phone, a bass breath in the first and a beat breath in the second, and one sheen that drifts
// the width of the screen. Nothing spots or swims; it reads as glass over the music.
static float3 glassLook(constant Uniforms &u, float2 uv) {
    float2 wash1 = uv - float2(0.50 + 0.14 * u.tilt.x, 0.34 + 0.08 * u.tilt.y);
    float2 wash2 = uv - float2(0.46 - 0.12 * u.tilt.x, 0.66 - 0.06 * u.tilt.y);
    float breathe = 0.5 + 0.5 * sin(u.misc.x * 0.09);
    float3 first = u.tints[0].rgb * (0.50 + 0.22 * u.misc.y) * exp(-2.4 * length(wash1 * float2(0.87, 1.0)));
    float3 second = u.tints[1].rgb * (0.42 + 0.20 * breathe) * exp(-2.7 * length(wash2 * float2(1.05, 1.0)));
    float sheenX = 0.5 + 0.26 * sin(u.misc.x * 0.11);
    float sheen = exp(-14.0 * fabs(uv.x - sheenX)) * (0.10 + 0.16 * u.misc.z);
    return first + second + mix(u.tints[0].rgb, u.tints[1].rgb, 0.5) * sheen;
}

fragment float4 frag(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float2 uv = in.uv;
    float3 col;
    switch ((int)u.opts.x) {
        case 0: col = nebula(u, uv); break;
        case 1: col = mosaic(u, uv); break;
        case 2: col = kaleido(u, uv); break;
        case 3: col = orbit(u, uv); break;
        case 4: col = smoke(u, uv); break;
        case 6: col = spectrumBars(u, uv); break;
        case 7: col = halo(u, uv); break;
        case 8: col = glassLook(u, uv); break;
        default: col = aurora(u, uv); break;
    }
    float2 c = uv - 0.5;
    col *= 1.0 - 0.9 * dot(c, c);   // a vignette, so the edges fall away under the text
    return float4(clamp(col, 0.0, 0.6), 1.0);
}
)METAL";

// Kept in step with the MSL's Uniforms.
typedef struct {
    vector_float4 misc, tilt, opts;
    vector_float4 tints[2];
    vector_float4 spectrum[6];
} SGRShaderUniforms;
_Static_assert(sizeof(SGRShaderUniforms) == 176, "The Metal Uniforms contract must stay 176 bytes");

NSString *SGRShaderTemplateSource(void) { return kSource; }

static id<MTLRenderPipelineState> sg_pipeline, sg_builtinPipeline;
static id<MTLCommandQueue> sg_queue;
static _Atomic BOOL sg_ready;
static dispatch_semaphore_t sg_inflight;
static _Atomic NSUInteger sg_compileGeneration;
static NSUInteger sg_pendingFrames, sg_stoppingFrames;
static NSString *sg_session, *sg_stoppingSession;
static BOOL sg_sessionFailed, sg_loading, sg_initialized;
static _Atomic BOOL sg_suspended;
static NSString *sg_loadedID;
static NSHashTable<UIView *> *sg_shaderViews;

static dispatch_queue_t shaderWorkQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("spotifyglass.redesign.shader.compiler", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static dispatch_queue_t shaderSessionQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("spotifyglass.redesign.shader.session", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static void shaderChanged(void) {
    SGRPlayerHoldField();
    [NSNotificationCenter.defaultCenter postNotificationName:kShaderChangedNotification object:nil];
}

static void finishStoppedSession(void) {
    if (sg_stoppingFrames || !sg_stoppingSession) return;
    NSString *token = sg_stoppingSession;
    sg_stoppingSession = nil;
    dispatch_async(shaderSessionQueue(), ^{ [SGRShaderLibrary() endSession:token]; });
}

static void stopCustomSession(void) {
    if (!sg_session) return;
    if (!sg_sessionFailed) { sg_stoppingSession = sg_session; sg_stoppingFrames = sg_pendingFrames; }
    sg_session = nil;
    sg_loadedID = nil;
    atomic_store(&sg_ready, false);
    finishStoppedSession();
}

static void resetShaderSelection(void) {
    ++sg_compileGeneration;
    sg_loading = NO;
    stopCustomSession();
}

static void failShader(NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!atomic_exchange(&sg_ready, false)) return;
        sg_sessionFailed = YES;
        SGLog(@"redesign player: shader GPU failed (%@), using Fluid for this launch", error.localizedDescription ?: @"no command buffer");
        shaderChanged();
    });
}

BOOL SGRShaderReady(void) { return atomic_load(&sg_ready); }

void SGRShaderValidateSource(NSString *source, void (^completion)(NSError *)) {
    dispatch_async(shaderWorkQueue(), ^{
        NSError *error;
        if (![source isKindOfClass:NSString.class] || ![source lengthOfBytesUsingEncoding:NSUTF8StringEncoding] || [source lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > SGRShaderSourceLimit)
            error = [NSError errorWithDomain:@"spotifyglass.redesign.shader" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Metal source must fit within 64 KiB."}];
        else if (!SGRShaderDevice()) error = [NSError errorWithDomain:@"spotifyglass.redesign.shader" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Metal is unavailable on this device."}];
        else SGRShaderBuildPipeline(source, &error);
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(error); });
    });
}

static void selectShader(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ selectShader(); }); return; }
    if (!sg_initialized) return;
    NSDictionary *profile = selectedProfile();
    if (sg_sessionFailed) return;
    if (!profile) {
        ++sg_compileGeneration;
        sg_loading = NO;
        stopCustomSession();
        sg_pipeline = sg_builtinPipeline;
        atomic_store(&sg_ready, sg_pipeline && sg_queue);
        return;
    }
    BOOL visible = NO;
    for (UIView *view in sg_shaderViews) if (view.window) { visible = YES; break; }
    if (!visible) {
        ++sg_compileGeneration;
        sg_loading = NO;
        stopCustomSession();
        return;
    }
    if (sg_suspended || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if ([sg_loadedID isEqual:profile[@"id"]] && sg_session) return;
    if (sg_loading) return;
    stopCustomSession();
    if (sg_pendingFrames) return;
    NSUInteger generation = ++sg_compileGeneration;
    sg_loading = YES;
    atomic_store(&sg_ready, false);
    dispatch_async(shaderWorkQueue(), ^{
        NSError *error;
        id<MTLRenderPipelineState> pipeline = SGRShaderBuildPipeline(profile[@"source"], &error);
        if (!pipeline) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != sg_compileGeneration) return;
                sg_loading = NO;
                SGLog(@"redesign player: custom shader unavailable (%@)", [error.localizedDescription substringToIndex:MIN(error.localizedDescription.length, 400)] ?: @"pipeline unavailable");
            });
            return;
        }
        dispatch_async(shaderSessionQueue(), ^{
            if (generation != atomic_load(&sg_compileGeneration) || atomic_load(&sg_suspended)) return;
            NSString *token = [SGRShaderLibrary() beginSession:profile[@"id"]];
            if (generation != atomic_load(&sg_compileGeneration) || atomic_load(&sg_suspended)) {
                if (token) [SGRShaderLibrary() endSession:token];
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != sg_compileGeneration || sg_suspended || ![selectedProfile() isEqual:profile] || sg_sessionFailed) {
                    if (token) dispatch_async(shaderSessionQueue(), ^{ [SGRShaderLibrary() endSession:token]; });
                    if (generation == sg_compileGeneration) sg_loading = NO;
                    return;
                }
                sg_loading = NO;
                if (!token || pipeline.device != SGRShaderDevice()) return;
                sg_pipeline = pipeline;
                sg_session = token;
                sg_loadedID = profile[@"id"];
                atomic_store(&sg_ready, sg_queue != nil);
                shaderChanged();
            });
        });
    });
}

static void compileShader(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_initialized = YES;
        sg_shaderViews = NSHashTable.weakObjectsHashTable;
        sg_inflight = dispatch_semaphore_create(2);
        sg_queue = [SGRShaderDevice() newCommandQueue];
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            sg_suspended = YES;
            ++sg_compileGeneration;
            sg_loading = NO;
            stopCustomSession();
        }];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            sg_suspended = NO;
            selectShader();
            shaderChanged();
        }];
        dispatch_async(shaderWorkQueue(), ^{
            NSError *error;
            id<MTLRenderPipelineState> pipeline = SGRShaderBuildPipeline(kSource, &error);
            dispatch_async(dispatch_get_main_queue(), ^{
                sg_builtinPipeline = pipeline;
                selectShader();
                shaderChanged();
            });
        });
    });
    selectShader();
}

#pragma mark - the view

// The bands, as the Visualiser's hills read them: the loudest band of late at the top, eased up quickly and
// down slowly, spread so one loud band is a hill and not a spike.
static const float kRange = 40, kPeakFall = 4, kPeakFloor = -60, kTilt = 0.6, kSpread = 0.25;
static const double kStale = 0.3, kUp = 0.08, kDown = 0.4, kStill = 3;
static const float kSettled = 0.02f;

@interface SGRShaderView : MTKView <SGPlayerStateObserver, MTKViewDelegate>
- (void)setBlurred:(BOOL)blurred;
- (BOOL)blurred;
- (void)appear:(BOOL)animated;
- (void)disappear:(void (^)(void))done;
@end

@implementation SGRShaderView {
    SGRShaderUniforms _uniforms;
    CMMotionManager *_motion;
    NSOperationQueue *_motionQueue;
    CMDeviceMotionHandler _motionHandler;
    BOOL _reading, _lyricsRequested;
    float _bands[SGRSpectrumBands], _peak, _bassSlow, _beat;
    double _time;
    uint64_t _generation;
    CFTimeInterval _fresh, _last;
    NSUInteger _palette;
    _Atomic(float) _gravityX, _gravityY;
    atomic_bool _drawQueued;
}

- (instancetype)initWithFrame:(CGRect)frame {
    compileShader();
    if (!(self = [super initWithFrame:frame device:SGRShaderDevice()])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.enableSetNeedsDisplay = NO;
    self.autoResizeDrawable = NO;
    self.paused = YES;
    self.hidden = !SGRShaderReady();
    self.framebufferOnly = YES;
    self.clearColor = MTLClearColorMake(0, 0, 0, 0);
    self.preferredFramesPerSecond = 60;
    self.delegate = self;
    _peak = kPeakFloor;
    [self applyColors:@[UIColor.darkGrayColor, UIColor.darkGrayColor, UIColor.darkGrayColor]];

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification, UIApplicationWillResignActiveNotification,
                                      NSProcessInfoPowerStateDidChangeNotification, UIAccessibilityReduceMotionStatusDidChangeNotification]) {
        [center addObserver:self selector:@selector(updateMotionSoon) name:name object:nil];
    }
    [center addObserver:self selector:@selector(artworkChanged) name:SGRNowPlayingArtworkDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(shaderChanged) name:kShaderChangedNotification object:nil];
    [self artworkChanged];
    SGRObservePlayerTransition(self, ^(id owner) { [owner updateMotion]; }, ^(id owner) { [owner updateMotion]; });
    SGAddPlayerStateObserver(self);
    [sg_shaderViews addObject:self];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_motion stopDeviceMotionUpdates];
    if (NSThread.isMainThread) SGRSpectrumSetReading(self, NO);
    else dispatch_async(dispatch_get_main_queue(), ^{ SGRSpectrumSetReading(nil, NO); });
}

#pragma mark - the cover's colors

- (void)applyColors:(NSArray<UIColor *> *)colors {
    if (colors.count < 3) return;
    SGRShaderUniforms *u = &_uniforms;
    CGFloat r, g, b, a;
    [colors[0] getRed:&r green:&g blue:&b alpha:&a];
    u->tints[0] = (vector_float4){(float)r, (float)g, (float)b, 1};
    [colors[2] getRed:&r green:&g blue:&b alpha:&a];
    u->tints[1] = (vector_float4){(float)r, (float)g, (float)b, 1};
    [self redrawIfPaused];
}

- (void)artworkChanged {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self artworkChanged]; });
        return;
    }
    UIImage *image = SGRNowPlayingArtwork(NULL, NULL);
    if (!image) return;
    NSUInteger generation = ++_palette;
    SGRPaletteRequest request = {CGSizeZero, NO, YES, YES, NO};
    __weak SGRShaderView *weakSelf = self;
    [SGRPalette paletteForImage:image request:request completion:^(SGRPalette *palette) {
        SGRShaderView *view = weakSelf;
        if (!view || !palette.flowColors || generation != view->_palette) return;
        [view applyColors:palette.flowColors];
    }];
}

#pragma mark - moving

- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self updateMotion];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self shaderChanged];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat scale = (self.window.screen ?: UIScreen.mainScreen).nativeScale * [selectedProfile()[@"scale"] ?: @0.5 doubleValue];
    CGSize size = CGSizeMake(self.bounds.size.width * scale, self.bounds.size.height * scale);
    CGFloat largest = MAX(size.width, size.height);
    if (largest > 1280) {
        size.width *= 1280 / largest;
        size.height *= 1280 / largest;
    }
    size.width = MAX(1, floor(size.width));
    size.height = MAX(1, floor(size.height));
    if (!CGSizeEqualToSize(size, self.drawableSize)) self.drawableSize = size;
}

- (void)shaderChanged {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self shaderChanged]; });
        return;
    }
    selectShader();
    [self setNeedsLayout];
    self.hidden = !SGRShaderReady();
    [self updateMotion];
    if (![self.superview isKindOfClass:SGRArtworkField.class]) {
        for (UIView *sibling in self.superview.subviews) {
            if ([sibling isKindOfClass:SGRArtworkField.class]) {
                ((SGRArtworkField *)sibling).motionHeld = SGRShaderReady() || SGPlayerState().isPaused;
            }
        }
    }
    [self redrawIfPaused];
}

- (void)redrawIfPaused {
    if (self.window && self.paused && SGRShaderReady()) [self draw];
}

// The power state is reported off the main thread.
- (void)updateMotionSoon {
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateMotion]; });
}

- (BOOL)settled {
    if (_beat > kSettled) return NO;
    for (int band = 0; band < SGRSpectrumBands; band++) if (_bands[band] > kSettled) return NO;
    return YES;
}

// Moving while it may and there is something to show: the song playing, or the field still settling after it
// stopped. While the player animates, it comes back once the animation is expected to be over.
- (void)updateMotion {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateMotion) object:nil];
    BOOL may = SGRShaderReady() && self.window && UIApplication.sharedApplication.applicationState == UIApplicationStateActive
        && !NSProcessInfo.processInfo.lowPowerModeEnabled;
    NSTimeInterval wait = SGPlayerTransitionEnds() - CACurrentMediaTime();
    if (may && (wait > 0 || SGRPlayerIsTransitioning())) {
        may = NO;
        if (wait > 0) [self performSelector:@selector(updateMotion) withObject:nil afterDelay:wait + 0.05 inModes:@[NSRunLoopCommonModes]];
    }
    BOOL playing = !SGPlayerState().isPaused;
    BOOL reading = may && playing;
    if (reading != _reading) {
        _reading = reading;
        SGRSpectrumSetReading(self, reading);
    }
    [self setMoving:may && (playing || !self.settled)];
}

- (void)setMoving:(BOOL)moving {
    self.paused = !moving;
    float most = SGRReduceMotion() ? 15 : _lyricsRequested ? 30 : 60;
    self.preferredFramesPerSecond = MIN(most, [selectedProfile()[@"fps"] ?: @60 integerValue]);
    if (moving && !SGRReduceMotion()) {
        if (!_motion) {
            _motion = [CMMotionManager new];
            _motion.deviceMotionUpdateInterval = 1.0 / 20.0;
            _motionQueue = [[NSOperationQueue alloc] init];
            _motionQueue.name = @"spotifyglass.shader.tilt";
            __weak SGRShaderView *weakSelf = self;
            _motionHandler = ^(CMDeviceMotion *motion, NSError *error) {
                SGRShaderView *view = weakSelf;
                if (!view || !motion) return;
                atomic_store(&view->_gravityX, (float)MAX(-1, MIN(1, motion.gravity.x)));
                atomic_store(&view->_gravityY, (float)MAX(-1, MIN(1, motion.gravity.y)));
            };
        }
        if (!_motion.isDeviceMotionActive) [_motion startDeviceMotionUpdatesToQueue:_motionQueue withHandler:_motionHandler];
    } else if (_motion.isDeviceMotionActive) {
        [_motion stopDeviceMotionUpdates];
    }
}

#pragma mark - the frame

// The drawable follows half the screen's native scale, capped at 1280 pixels.
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    (void)view;
    if (size.width > 0 && size.height > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self redrawIfPaused]; });
    }
}

- (void)drawInMTKView:(MTKView *)view {
    if (!NSThread.isMainThread) {
        if (!atomic_exchange(&_drawQueued, true)) {
            __weak SGRShaderView *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                SGRShaderView *owner = weakSelf;
                if (!owner) return;
                atomic_store(&owner->_drawQueued, false);
                if (owner.window) [owner draw];
            });
        }
        return;
    }
    if (!atomic_load(&sg_ready) || !self.device || sg_suspended) return;
    dispatch_semaphore_t inflight = sg_inflight;
    if (dispatch_semaphore_wait(inflight, DISPATCH_TIME_NOW)) return;
    CFTimeInterval now = CACurrentMediaTime();
    double dt = _last ? MIN(now - _last, 0.1) : 1.0 / 60.0;
    _last = now;
    _time += dt;

    float levels[SGRSpectrumBands];
    uint64_t generation = SGRSpectrumRead(levels);
    if (generation != _generation) {
        _generation = generation;
        _fresh = now;
    }
    BOOL silent = !_reading || now - _fresh > kStale;
    float loudest = kPeakFloor;
    for (int band = 0; band < SGRSpectrumBands; band++) {
        levels[band] += kTilt * band;
        loudest = fmaxf(loudest, levels[band]);
    }
    if (!silent) _peak = fmaxf(fmaxf(loudest, _peak - kPeakFall * (float)dt), kPeakFloor);
    float targets[SGRSpectrumBands];
    for (int band = 0; band < SGRSpectrumBands; band++) {
        targets[band] = silent ? 0 : fminf(1, fmaxf(0, (levels[band] - (_peak - kRange)) / kRange));
    }
    for (int pass = 0; pass < 2; pass++) {
        float before = targets[0];
        for (int band = 0; band < SGRSpectrumBands; band++) {
            float here = targets[band], next = targets[MIN(band + 1, SGRSpectrumBands - 1)];
            targets[band] = kSpread * before + (1 - 2 * kSpread) * here + kSpread * next;
            before = here;
        }
    }
    BOOL still = SGRReduceMotion();
    double tauUp = still ? kStill : kUp, tauDown = still ? kStill : kDown;
    float bass = 0, energy = 0;
    for (int band = 0; band < SGRSpectrumBands; band++) {
        double tau = targets[band] > _bands[band] ? tauUp : tauDown;
        _bands[band] += (targets[band] - _bands[band]) * (float)(1 - exp(-dt / tau));
        if (band < 6) bass += _bands[band] / 6;
        energy += _bands[band] / SGRSpectrumBands;
    }

    // A beat: a bass onset jumps the pulse, which decays over about a sixth of a second.
    if (bass > _bassSlow + 0.12 && bass > 0.25) _beat = 1;
    _beat *= (float)exp(-dt / 0.16);
    _bassSlow += (bass - _bassSlow) * (float)(1 - exp(-dt / 1.2));

    SGRShaderUniforms *u = &_uniforms;
    u->misc = (vector_float4){(float)_time, bass, _beat, energy};
    u->tilt = still ? (vector_float4){0, 0, 0, 0}
        : (vector_float4){atomic_load(&_gravityX), atomic_load(&_gravityY), 0, 0};
    u->opts = (vector_float4){(float)SGRShaderIndex(), 0, 0, 0};
    for (int band = 0; band < SGRSpectrumBands; band++) u->spectrum[band >> 2][band & 3] = _bands[band];

    id<CAMetalDrawable> drawable = view.currentDrawable;
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    if (!drawable || !pass || !sg_queue) {
        dispatch_semaphore_signal(inflight);
        return;
    }
    id<MTLRenderPipelineState> framePipeline = sg_pipeline;
    if (framePipeline.device != view.device || sg_queue.device != view.device) {
        dispatch_semaphore_signal(inflight);
        failShader(nil);
        return;
    }
    id<MTLCommandBuffer> buffer = [sg_queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    if (!buffer || !encoder) {
        dispatch_semaphore_signal(inflight);
        failShader(nil);
        return;
    }
    [encoder setRenderPipelineState:framePipeline];
    [encoder setFragmentBytes:u length:sizeof(*u) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    [buffer presentDrawable:drawable];
    ++sg_pendingFrames;
    NSString *session = sg_session;
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> finished) {
        dispatch_semaphore_signal(inflight);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (sg_pendingFrames) --sg_pendingFrames;
            if (session && [session isEqual:sg_stoppingSession] && sg_stoppingFrames) --sg_stoppingFrames;
            if (finished.status == MTLCommandBufferStatusError) {
                sg_sessionFailed = YES;
                if (session) sg_stoppingSession = nil;
                atomic_store(&sg_ready, false);
                SGLog(@"redesign player: shader GPU failed (%@), using Fluid", finished.error.localizedDescription ?: @"unknown");
                shaderChanged();
            } else {
                finishStoppedSession();
                if (!sg_sessionFailed && selectedProfile() && !sg_session) selectShader();
            }
        });
    }];
    [buffer commit];

    BOOL idle = silent && self.settled;
    if (idle) {
        memset(_bands, 0, sizeof _bands);
        _beat = 0;
        [self updateMotion];   // a settled field stops the view
    }
}

#pragma mark - showing

- (void)setBlurred:(BOOL)blurred {
    _lyricsRequested = blurred;
    [self updateMotion];
}

- (BOOL)blurred {
    return _lyricsRequested;
}

- (void)appear:(BOOL)animated {
    self.alpha = 0;
    if (animated) SGRAnimate(SGRMotionFade, ^{ self.alpha = 1; }, nil);
    else self.alpha = 1;
    [self updateMotion];
}

- (void)disappear:(void (^)(void))done {
    SGRAnimate(SGRMotionFade, ^{
        self.alpha = 0;
    }, ^(BOOL finished) {
        self.paused = YES;
        [self stopDeviceMotion];
        done();
    });
}

- (void)stopDeviceMotion {
    if (_motion.isDeviceMotionActive) [_motion stopDeviceMotionUpdates];
}

@end

#pragma mark - in the player

static SGRShaderView *sg_view;

BOOL SGRPlayerShaderShowing(void) {
    SGRPlayerBackgroundKind background = SGRPlayerBackground();
    return background == SGRPlayerBackgroundShader
        || (background == SGRPlayerBackgroundAnimated && SGRPlayerAnimatedFallback() == SGRPlayerBackgroundShader);
}

UIView *SGRPlayerShaderPreview(void) {
    static SGRShaderView *view;
    if (!view) view = [[SGRShaderView alloc] initWithFrame:CGRectZero];
    return view;
}

// The whole field, down through its bleed, as the Visualiser's hills stand on.
static void layOut(SGRArtworkField *field) {
    if (sg_view.superview != field) [field addSubview:sg_view];
    else if (field.subviews.lastObject != sg_view) [field bringSubviewToFront:sg_view];
    CGSize size = field.bounds.size;
    CGFloat screen = field.window.bounds.size.height ?: size.height;
    CGRect frame = CGRectMake(0, 0, size.width, MAX(size.height, screen) + field.bleed.bottom);
    if (!CGRectEqualToRect(sg_view.frame, frame)) sg_view.frame = frame;
}

// Runs on every layout pass of the field's plane, as the Visualiser's update does: the blur follows the
// lyrics, and the view comes and goes with the choice.
void SGRPlayerShaderUpdate(void) {
    SGRArtworkField *field = SGRPlayerField();
    BOOL wanted = SGRPlayerShaderShowing() && field && !SGRPlayerMotionShowing();
    if (!wanted) {
        SGRShaderView *old = sg_view;
        sg_view = nil;
        if (!old) return;
        if (old.window) [old disappear:^{ [old removeFromSuperview]; }];
        else [old removeFromSuperview];
        return;
    }
    BOOL made = !sg_view;
    if (made) sg_view = [[SGRShaderView alloc] initWithFrame:CGRectZero];
    layOut(field);
    if (made) {
        [sg_view setBlurred:SGRPlayerLyricsOpen()];
        [sg_view appear:field.window != nil];
        SGLog(@"redesign player: shader %@ on the field", SGRShaderNames()[SGRShaderIndex()]);
    } else {
        BOOL open = SGRPlayerLyricsOpen();
        if (open != sg_view.blurred) [sg_view setBlurred:open];
    }
}
