#import "Core/SGCore.h"
#import "AmbientSession.h"
#import "Shared/Player/PlayerState.h"
#import "Ambient.h"
#import <AVFoundation/AVFoundation.h>
#import <stdatomic.h>
#import <math.h>

NSNotificationName const SGAmbientDidChangeNotification = @"SGAmbientDidChangeNotification";
NSNotificationName const SGAmbientEngineStateDidChangeNotification = @"SGAmbientEngineStateDidChangeNotification";

typedef NS_ENUM(NSUInteger, SGAmbientSoundIndex) {
    SGAmbientSoundRain = 0,
    SGAmbientSoundThunder,
    SGAmbientSoundFire,
    SGAmbientSoundWind,
    SGAmbientSoundForest,
    SGAmbientSoundOcean,
    SGAmbientSoundCafe,
    SGAmbientSoundTrain,
    SGAmbientSoundNoise,
    SGAmbientSoundCount
};

static _Atomic float sg_targetLevels[SGAmbientSoundCount];
static _Atomic float sg_masterTarget = 0.7f;
static _Atomic float sg_duckFactor = 1.0f;
static _Atomic float sg_fadeFactor = 1.0f;
static _Atomic bool sg_engineActive = false;
static _Atomic bool sg_podcastPaused = false;

static BOOL sg_playing = NO; // the user's intent, separate from whether the engine is running
static BOOL sg_interrupted;
static BOOL sg_startFailed;
// One atomic word keeps Stop from racing a deactivation on Spotify's audio thread.
static _Atomic uint64_t sg_sessionState;
static const uint64_t kSessionHeld = 1, kSessionDeferred = 2;
static _Atomic bool sg_activatingOwnSession = false;
static BOOL sg_activatedSession;

static void keepSession(BOOL keep) {
    if (keep) atomic_fetch_or(&sg_sessionState, kSessionHeld);
    else atomic_fetch_and(&sg_sessionState, ~kSessionHeld);
}
static NSString *sg_activeSceneKey = @"rainy-night";
static NSMutableDictionary<NSString *, NSNumber *> *sg_levels;
static float sg_masterVolume = 0.7f;
static AVAudioEngine *sg_audioEngine;
static AVAudioSourceNode *sg_sourceNode;
static NSTimer *sg_fadeTimer;
static NSTimeInterval sg_fadeRemaining = 0, sg_fadeTotal = 0;

NSArray<SGAmbientSound *> *SGAmbientAllSounds(void) {
    static NSArray<SGAmbientSound *> *sounds;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sounds = @[
            [[SGAmbientSound alloc] initWithKey:@"rain" name:@"Rain" symbol:@"cloud.rain.fill" defaultLevel:0.75f],
            [[SGAmbientSound alloc] initWithKey:@"thunder" name:@"Thunder" symbol:@"cloud.bolt.rain.fill" defaultLevel:0.35f],
            [[SGAmbientSound alloc] initWithKey:@"fire" name:@"Fireplace" symbol:@"flame.fill" defaultLevel:0.0f],
            [[SGAmbientSound alloc] initWithKey:@"wind" name:@"Wind" symbol:@"wind" defaultLevel:0.20f],
            [[SGAmbientSound alloc] initWithKey:@"forest" name:@"Forest" symbol:@"tree.fill" defaultLevel:0.0f],
            [[SGAmbientSound alloc] initWithKey:@"ocean" name:@"Ocean" symbol:@"water.waves" defaultLevel:0.0f],
            [[SGAmbientSound alloc] initWithKey:@"cafe" name:@"Cafe" symbol:@"cup.and.saucer.fill" defaultLevel:0.0f],
            [[SGAmbientSound alloc] initWithKey:@"train" name:@"Train" symbol:@"tram.fill" defaultLevel:0.0f],
            [[SGAmbientSound alloc] initWithKey:@"noise" name:@"Soft noise" symbol:@"waveform" defaultLevel:0.0f],
        ];
    });
    return sounds;
}

NSArray<SGAmbientScene *> *SGAmbientAllScenes(void) {
    static NSArray<SGAmbientScene *> *scenes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        scenes = @[
            [[SGAmbientScene alloc] initWithKey:@"rainy-night" name:@"Rainy night"
                                       subtitle:@"Rain on the window, thunder far away"
                                         symbol:@"cloud.moon.rain.fill" tintRGB:0x4A78B8
                                         levels:@{@"rain": @0.75, @"thunder": @0.35, @"wind": @0.20}],
            [[SGAmbientScene alloc] initWithKey:@"fireplace" name:@"Fireplace"
                                       subtitle:@"A cabin with a warm crackling fire"
                                         symbol:@"flame.fill" tintRGB:0xE07A38
                                         levels:@{@"fire": @0.80, @"wind": @0.25, @"rain": @0.15}],
            [[SGAmbientScene alloc] initWithKey:@"forest" name:@"Forest"
                                       subtitle:@"Pines in morning mist"
                                         symbol:@"tree.fill" tintRGB:0x3C9D64
                                         levels:@{@"forest": @0.75, @"wind": @0.35}],
            [[SGAmbientScene alloc] initWithKey:@"ocean" name:@"Ocean"
                                       subtitle:@"Waves rolling onto the shore"
                                         symbol:@"water.waves" tintRGB:0x2E96B4
                                         levels:@{@"ocean": @0.80, @"wind": @0.25}],
            [[SGAmbientScene alloc] initWithKey:@"cafe" name:@"Cafe"
                                       subtitle:@"A busy bar on a rainy evening"
                                         symbol:@"cup.and.saucer.fill" tintRGB:0xB88454
                                         levels:@{@"cafe": @0.65, @"rain": @0.45, @"thunder": @0.15}],
            [[SGAmbientScene alloc] initWithKey:@"night-train" name:@"Night train"
                                       subtitle:@"Rhythmic rails through the rain"
                                         symbol:@"tram.fill" tintRGB:0x7B68C8
                                         levels:@{@"train": @0.70, @"rain": @0.40, @"noise": @0.20}],
        ];
    });
    return scenes;
}

@implementation SGAmbientSound
- (instancetype)initWithKey:(NSString *)key name:(NSString *)name symbol:(NSString *)symbol defaultLevel:(float)level {
    if (!(self = [super init])) return nil;
    _key = [key copy];
    _name = [name copy];
    _symbol = [symbol copy];
    _defaultLevel = level;
    return self;
}
@end

@implementation SGAmbientScene
- (instancetype)initWithKey:(NSString *)key name:(NSString *)name subtitle:(NSString *)subtitle symbol:(NSString *)symbol tintRGB:(NSUInteger)tintRGB levels:(NSDictionary<NSString *,NSNumber *> *)levels {
    if (!(self = [super init])) return nil;
    _key = [key copy];
    _name = [name copy];
    _subtitle = [subtitle copy];
    _symbol = [symbol copy];
    _tintRGB = tintRGB;
    _levels = [levels copy];
    return self;
}
@end

static void syncAtomics(void) {
    NSArray<SGAmbientSound *> *sounds = SGAmbientAllSounds();
    for (NSUInteger i = 0; i < sounds.count && i < SGAmbientSoundCount; i++) {
        float val = [sg_levels[sounds[i].key] floatValue];
        atomic_store_explicit(&sg_targetLevels[i], fminf(1.0f, fmaxf(0.0f, val)), memory_order_relaxed);
    }
    atomic_store_explicit(&sg_masterTarget, fminf(1.0f, fmaxf(0.0f, sg_masterVolume)), memory_order_relaxed);
}

static void saveState(void) {
    NSDictionary *state = @{
        @"scene": sg_activeSceneKey ?: @"rainy-night",
        @"master": @(sg_masterVolume),
        @"levels": [sg_levels copy] ?: @{},
    };
    [NSUserDefaults.standardUserDefaults setObject:state forKey:SGKeyAmbientState];
}

static void loadStateIfNeeded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_levels = [NSMutableDictionary dictionary];
        NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:SGKeyAmbientState];
        if ([saved isKindOfClass:NSDictionary.class]) {
            if ([saved[@"scene"] isKindOfClass:NSString.class]) sg_activeSceneKey = saved[@"scene"];
            if ([saved[@"master"] respondsToSelector:@selector(floatValue)]) sg_masterVolume = [saved[@"master"] floatValue];
            NSDictionary *lv = saved[@"levels"];
            if ([lv isKindOfClass:NSDictionary.class]) {
                for (SGAmbientSound *s in SGAmbientAllSounds()) {
                    if ([lv[s.key] respondsToSelector:@selector(floatValue)]) {
                        sg_levels[s.key] = @([lv[s.key] floatValue]);
                    }
                }
            }
        }
        if (!sg_levels.count) {
            SGAmbientScene *first = SGAmbientAllScenes().firstObject;
            for (SGAmbientSound *s in SGAmbientAllSounds()) {
                sg_levels[s.key] = first.levels[s.key] ?: @(0.0f);
            }
        }
        syncAtomics();
    });
}

static void updateDuckAndPodcastState(SPTPlayerState *state) {
    BOOL playingTrack = state && !state.isPaused && state.track != nil;
    NSString *uri = SGURIString(state.track.URI);
    BOOL isPodcast = [uri containsString:@":episode:"] || [uri containsString:@":show:"];
    BOOL pauseForPodcast = SGFlag(SGKeyAmbientPodcastPause, YES) && playingTrack && isPodcast;
    atomic_store_explicit(&sg_podcastPaused, pauseForPodcast, memory_order_relaxed);

    BOOL duck = SGFlag(SGKeyAmbientDuck, YES) && playingTrack && !isPodcast;
    atomic_store_explicit(&sg_duckFactor, duck ? 0.55f : 1.0f, memory_order_relaxed);
}

static inline float nextWhite(uint32_t *seed) {
    *seed = *seed * 1664525u + 1013904223u;
    return ((float)(*seed >> 8) / 8388608.0f) - 1.0f;
}

static BOOL ensureEngineStarted(void) {
    if (!sg_audioEngine) {
        sg_audioEngine = [[AVAudioEngine alloc] init];
        double sampleRate = 44100.0;
        AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate channels:2];

        __block uint32_t rngL = 0x13579BDFu, rngR = 0x2468ACE0u;
        __block float pinkL = 0, pinkR = 0;
        __block float brownL = 0, brownR = 0;
        __block float dropEnvL = 0, dropEnvR = 0;
        __block float thunderRumble = 0, thunderEnv = 0;
        __block float fireEmber = 0, fireCrackleL = 0, fireCrackleR = 0;
        __block float windLP1 = 0, windLP2 = 0, windPhase = 0;
        __block float oceanLP = 0, oceanPhase = 0;
        __block float forestLP = 0, birdPhase = 0, birdEnv = 0, birdFreq = 2400.0f;
        __block float cafeLP = 0, cafeClinkEnv = 0, cafeClinkPhase = 0;
        __block float trainLP = 0, trainCadence = 0, trainClackEnv = 0;
        __block float currentGain = 0;

        sg_sourceNode = [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp, AVAudioFrameCount frameCount, AudioBufferList *outputData) {
            bool active = atomic_load_explicit(&sg_engineActive, memory_order_relaxed);
            bool podPaused = atomic_load_explicit(&sg_podcastPaused, memory_order_relaxed);
            float master = atomic_load_explicit(&sg_masterTarget, memory_order_relaxed);
            float duck = atomic_load_explicit(&sg_duckFactor, memory_order_relaxed);
            float fade = atomic_load_explicit(&sg_fadeFactor, memory_order_relaxed);
            float targetGain = (active && !podPaused) ? (master * duck * fade) : 0.0f;

            float lv[SGAmbientSoundCount];
            float sumLevels = 0;
            for (int i = 0; i < SGAmbientSoundCount; i++) {
                lv[i] = atomic_load_explicit(&sg_targetLevels[i], memory_order_relaxed);
                sumLevels += lv[i];
            }

            float *outL = (float *)outputData->mBuffers[0].mData;
            float *outR = outputData->mNumberBuffers > 1 ? (float *)outputData->mBuffers[1].mData : outL;

            if (targetGain <= 0.0001f && currentGain <= 0.0001f) {
                memset(outL, 0, sizeof(float) * frameCount);
                if (outR != outL) memset(outR, 0, sizeof(float) * frameCount);
                *isSilence = YES;
                return noErr;
            }
            *isSilence = NO;

            float dt = 1.0f / 44100.0f;
            for (AVAudioFrameCount f = 0; f < frameCount; f++) {
                currentGain += (targetGain - currentGain) * 0.0005f;
                if (sumLevels <= 0.001f) {
                    outL[f] = 0;
                    outR[f] = 0;
                    continue;
                }
                float wL = nextWhite(&rngL);
                float wR = nextWhite(&rngR);
                pinkL = 0.92f * pinkL + 0.08f * wL;
                pinkR = 0.92f * pinkR + 0.08f * wR;
                brownL = fmaxf(-1.0f, fminf(1.0f, 0.985f * brownL + 0.015f * wL));
                brownR = fmaxf(-1.0f, fminf(1.0f, 0.985f * brownR + 0.015f * wR));

                float mixL = 0, mixR = 0;

                // 0: Rain
                if (lv[SGAmbientSoundRain] > 0.001f) {
                    if ((rngL & 0x3FFF) == 1) dropEnvL = 0.35f;
                    if ((rngR & 0x3FFF) == 1) dropEnvR = 0.35f;
                    dropEnvL *= 0.992f;
                    dropEnvR *= 0.992f;
                    float rL = (pinkL * 0.35f + wL * dropEnvL * 0.25f) * lv[SGAmbientSoundRain];
                    float rR = (pinkR * 0.35f + wR * dropEnvR * 0.25f) * lv[SGAmbientSoundRain];
                    mixL += rL;
                    mixR += rR;
                }
                // 1: Thunder
                if (lv[SGAmbientSoundThunder] > 0.001f) {
                    if ((rngL & 0x7FFFF) == 7 && thunderEnv < 0.05f) thunderEnv = 1.0f;
                    thunderEnv *= 0.99996f;
                    thunderRumble = 0.995f * thunderRumble + 0.005f * (brownL + brownR);
                    float th = thunderRumble * (0.25f + 1.8f * thunderEnv) * lv[SGAmbientSoundThunder];
                    mixL += th;
                    mixR += th * 0.95f;
                }
                // 2: Fireplace
                if (lv[SGAmbientSoundFire] > 0.001f) {
                    if ((rngL & 0x1FFF) == 3) fireCrackleL = 0.7f;
                    if ((rngR & 0x1FFF) == 5) fireCrackleR = 0.7f;
                    fireCrackleL *= 0.975f;
                    fireCrackleR *= 0.975f;
                    fireEmber = 0.99f * fireEmber + 0.01f * brownL;
                    mixL += (fireEmber * 0.4f + wL * fireCrackleL * 0.35f) * lv[SGAmbientSoundFire];
                    mixR += (fireEmber * 0.4f + wR * fireCrackleR * 0.35f) * lv[SGAmbientSoundFire];
                }
                // 3: Wind
                if (lv[SGAmbientSoundWind] > 0.001f) {
                    windPhase += dt * 0.18f;
                    if (windPhase > 6.283185f) windPhase -= 6.283185f;
                    float alpha = 0.012f + 0.010f * sinf(windPhase);
                    windLP1 += alpha * (pinkL - windLP1);
                    windLP2 += alpha * (pinkR - windLP2);
                    float swell = 0.55f + 0.45f * sinf(windPhase * 0.7f);
                    mixL += windLP1 * swell * 0.6f * lv[SGAmbientSoundWind];
                    mixR += windLP2 * swell * 0.6f * lv[SGAmbientSoundWind];
                }
                // 4: Forest
                if (lv[SGAmbientSoundForest] > 0.001f) {
                    forestLP = 0.96f * forestLP + 0.04f * pinkL;
                    if ((rngL & 0x1FFFF) == 11 && birdEnv < 0.01f) {
                        birdEnv = 0.22f;
                        birdFreq = 2100.0f + (float)(rngR & 0x3FF);
                    }
                    birdEnv *= 0.9994f;
                    birdPhase += dt * birdFreq * 6.283185f;
                    if (birdPhase > 6.283185f) birdPhase -= 6.283185f;
                    float bird = sinf(birdPhase) * birdEnv;
                    mixL += (forestLP * 0.28f + bird * 0.3f) * lv[SGAmbientSoundForest];
                    mixR += (forestLP * 0.28f + bird * 0.22f) * lv[SGAmbientSoundForest];
                }
                // 5: Ocean
                if (lv[SGAmbientSoundOcean] > 0.001f) {
                    oceanPhase += dt * 0.11f * 6.283185f;
                    if (oceanPhase > 6.283185f) oceanPhase -= 6.283185f;
                    float waveL = 0.35f + 0.65f * (0.5f + 0.5f * sinf(oceanPhase));
                    float waveR = 0.35f + 0.65f * (0.5f + 0.5f * sinf(oceanPhase + 0.6f));
                    oceanLP = 0.97f * oceanLP + 0.03f * (pinkL + brownR * 0.5f);
                    mixL += oceanLP * waveL * 0.55f * lv[SGAmbientSoundOcean];
                    mixR += oceanLP * waveR * 0.55f * lv[SGAmbientSoundOcean];
                }
                // 6: Cafe
                if (lv[SGAmbientSoundCafe] > 0.001f) {
                    cafeLP = 0.94f * cafeLP + 0.06f * (pinkL * 0.6f + brownR * 0.4f);
                    if ((rngR & 0x3FFFF) == 19 && cafeClinkEnv < 0.01f) cafeClinkEnv = 0.18f;
                    cafeClinkEnv *= 0.9985f;
                    cafeClinkPhase += dt * 3100.0f * 6.283185f;
                    if (cafeClinkPhase > 6.283185f) cafeClinkPhase -= 6.283185f;
                    float clink = sinf(cafeClinkPhase) * cafeClinkEnv;
                    mixL += (cafeLP * 0.35f + clink * 0.25f) * lv[SGAmbientSoundCafe];
                    mixR += (cafeLP * 0.35f + clink * 0.30f) * lv[SGAmbientSoundCafe];
                }
                // 7: Train
                if (lv[SGAmbientSoundTrain] > 0.001f) {
                    trainCadence += dt;
                    if (trainCadence >= 1.45f) {
                        trainCadence -= 1.45f;
                        trainClackEnv = 0.45f;
                    } else if (fabsf(trainCadence - 0.22f) < dt * 0.6f) {
                        trainClackEnv = 0.35f;
                    }
                    trainClackEnv *= 0.990f;
                    trainLP = 0.985f * trainLP + 0.015f * brownL;
                    float tr = (trainLP * 0.5f + pinkL * trainClackEnv * 0.4f) * lv[SGAmbientSoundTrain];
                    mixL += tr;
                    mixR += tr;
                }
                // 8: Soft noise
                if (lv[SGAmbientSoundNoise] > 0.001f) {
                    mixL += (brownL * 0.5f + pinkL * 0.2f) * lv[SGAmbientSoundNoise];
                    mixR += (brownR * 0.5f + pinkR * 0.2f) * lv[SGAmbientSoundNoise];
                }

                outL[f] = tanhf(mixL * currentGain * 0.85f);
                outR[f] = tanhf(mixR * currentGain * 0.85f);
            }
            return noErr;
        }];

        [sg_audioEngine attachNode:sg_sourceNode];
        [sg_audioEngine connect:sg_sourceNode to:sg_audioEngine.mainMixerNode format:format];
    }

    if (sg_audioEngine.isRunning) return YES;
    NSError *error = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    // Keep a playback/recording configuration Spotify already owns (including its route and mode).
    if (![session.category isEqual:AVAudioSessionCategoryPlayback]
        && ![session.category isEqual:AVAudioSessionCategoryPlayAndRecord]
        && ![session setCategory:AVAudioSessionCategoryPlayback
                    withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&error]) {
        SGLog(@"ambient: could not configure audio: %@", error);
        return NO;
    }
    atomic_store(&sg_activatingOwnSession, true);
    BOOL activated = [session setActive:YES error:&error];
    atomic_store(&sg_activatingOwnSession, false);
    if (!activated) {
        SGLog(@"ambient: could not activate audio: %@", error);
        return NO;
    }
    sg_activatedSession = YES;
    if (![sg_audioEngine startAndReturnError:&error]) {
        SGLog(@"ambient: could not start audio: %@", error);
        return NO;
    }
    return sg_audioEngine.isRunning;
}

static void reconcilePlayback(void);
static void notifyPlayback(void);
static _Atomic bool sg_reconcileScheduled = false;

static void schedulePlaybackReconcile(void) {
    if (!sg_playing || sg_interrupted) return;
    bool expected = false;
    if (!atomic_compare_exchange_strong(&sg_reconcileScheduled, &expected, true)) return;
    const double delays[] = {0.01, 0.15, 0.45, 1.0};
    for (size_t i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
        BOOL last = (i + 1 == sizeof(delays) / sizeof(delays[0]));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (last) atomic_store(&sg_reconcileScheduled, false);
            if (!sg_playing || sg_interrupted) return;
            if (!sg_audioEngine.isRunning) {
                reconcilePlayback();
                notifyPlayback();
            }
        });
    }
}

BOOL SGAmbientDeferSessionDeactivation(BOOL active, NSUInteger options) {
    if (active) {
        if (!atomic_load(&sg_activatingOwnSession)) {
            atomic_fetch_and(&sg_sessionState, kSessionHeld);
        }
        return NO;
    }
    uint64_t current = atomic_load(&sg_sessionState);
    while (current & kSessionHeld) {
        uint64_t deferred = kSessionHeld | kSessionDeferred | ((uint64_t)options << 2);
        if (atomic_compare_exchange_weak(&sg_sessionState, &current, deferred)) {
            schedulePlaybackReconcile();
            return YES;
        }
    }
    return NO;
}

static void releaseSessionIfDeferred(void) {
    uint64_t held = atomic_exchange(&sg_sessionState, 0);
    BOOL activated = sg_activatedSession;
    sg_activatedSession = NO;
    if (!(held & kSessionDeferred) && !activated) return;
    SPTPlayerState *state = SGPlayerState();
    if (state && !state.isPaused) return;
    NSUInteger options = held & kSessionDeferred ? (NSUInteger)(held >> 2)
        : AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation;
    [AVAudioSession.sharedInstance setActive:NO withOptions:options error:nil];
}

static void notifyPlayback(void) {
    static NSString *lastSummary;
    static BOOL lastEnabled, lastPlaying;
    NSString *summary = SGAmbientSummary();
    BOOL playing = SGAmbientIsPlaying();
    if ([lastSummary isEqualToString:summary] && lastEnabled == sg_playing && lastPlaying == playing) return;
    lastSummary = summary;
    lastEnabled = sg_playing;
    lastPlaying = playing;
    [NSNotificationCenter.defaultCenter postNotificationName:SGAmbientEngineStateDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter postNotificationName:SGAmbientDidChangeNotification object:nil];
}

static void reconcilePlayback(void) {
    if (!sg_playing || sg_interrupted) return;
    keepSession(YES);
    atomic_store(&sg_engineActive, true);
    if (!ensureEngineStarted()) {
        sg_startFailed = YES;
        sg_playing = NO;
        keepSession(NO);
        atomic_store(&sg_engineActive, false);
        [sg_audioEngine stop];
        [sg_fadeTimer invalidate];
        sg_fadeTimer = nil;
        releaseSessionIfDeferred();
    }
}

BOOL SGAmbientIsPlaying(void) {
    loadStateIfNeeded();
    return sg_playing && !sg_interrupted && sg_audioEngine.isRunning
        && !atomic_load(&sg_podcastPaused);
}

BOOL SGAmbientIsEnabled(void) {
    return sg_playing;
}

void SGAmbientSetPlaying(BOOL playing) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGAmbientSetPlaying(playing); });
        return;
    }
    loadStateIfNeeded();
    sg_playing = playing;
    sg_startFailed = NO;
    atomic_store_explicit(&sg_fadeFactor, 1.0f, memory_order_relaxed);
    [sg_fadeTimer invalidate];
    sg_fadeTimer = nil;
    if (playing) {
        updateDuckAndPodcastState(SGPlayerState());
        reconcilePlayback();
    } else {
        atomic_store(&sg_reconcileScheduled, false);
        keepSession(NO);
        atomic_store_explicit(&sg_engineActive, false, memory_order_relaxed);
        [sg_audioEngine stop];
        releaseSessionIfDeferred();
    }
    notifyPlayback();
}

void SGAmbientTogglePlaying(void) {
    SGAmbientSetPlaying(!SGAmbientIsEnabled());
}

NSString *SGAmbientActiveSceneKey(void) {
    loadStateIfNeeded();
    return sg_activeSceneKey;
}

SGAmbientScene *SGAmbientActiveScene(void) {
    loadStateIfNeeded();
    for (SGAmbientScene *scene in SGAmbientAllScenes()) {
        if ([scene.key isEqualToString:sg_activeSceneKey]) return scene;
    }
    return SGAmbientAllScenes().firstObject;
}

void SGAmbientApplyScene(NSString *sceneKey) {
    loadStateIfNeeded();
    SGAmbientScene *picked = nil;
    for (SGAmbientScene *s in SGAmbientAllScenes()) {
        if ([s.key isEqualToString:sceneKey]) { picked = s; break; }
    }
    if (!picked) return;
    sg_activeSceneKey = [picked.key copy];
    [sg_levels removeAllObjects];
    for (SGAmbientSound *sound in SGAmbientAllSounds()) {
        sg_levels[sound.key] = picked.levels[sound.key] ?: @(0.0f);
    }
    syncAtomics();
    saveState();
    [NSNotificationCenter.defaultCenter postNotificationName:SGAmbientDidChangeNotification object:nil];
}

float SGAmbientMasterVolume(void) {
    loadStateIfNeeded();
    return sg_masterVolume;
}

void SGAmbientSetMasterVolume(float volume) {
    loadStateIfNeeded();
    sg_masterVolume = fminf(1.0f, fmaxf(0.0f, volume));
    syncAtomics();
    saveState();
    [NSNotificationCenter.defaultCenter postNotificationName:SGAmbientDidChangeNotification object:nil];
}

float SGAmbientLevelForSound(NSString *soundKey) {
    loadStateIfNeeded();
    return [sg_levels[soundKey] floatValue];
}

void SGAmbientSetLevelForSound(NSString *soundKey, float level) {
    loadStateIfNeeded();
    if (!soundKey.length) return;
    sg_levels[soundKey] = @(fminf(1.0f, fmaxf(0.0f, level)));
    syncAtomics();
    saveState();
    [NSNotificationCenter.defaultCenter postNotificationName:SGAmbientDidChangeNotification object:nil];
}

NSString *SGAmbientSummary(void) {
    loadStateIfNeeded();
    if (sg_startFailed) return @"Unable to play — try again";
    if (!sg_playing) return @"Off";
    if (sg_interrupted) return @"Interrupted";
    if (atomic_load(&sg_podcastPaused)) return @"Paused for podcast";
    if (!sg_audioEngine.isRunning) return @"Reconnecting audio";
    return SGAmbientActiveScene().name ?: @"On";
}

void SGAmbientStartSleepFade(NSTimeInterval duration) {
    if (!sg_playing) return;
    [sg_fadeTimer invalidate];
    if (!SGFlag(SGKeyAmbientTimerFade, YES) || duration <= 1) {
        SGAmbientSetPlaying(NO);
        return;
    }
    sg_fadeTotal = duration;
    sg_fadeRemaining = duration;
    sg_fadeTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        sg_fadeRemaining -= 0.25;
        if (sg_fadeRemaining <= 0) {
            [timer invalidate];
            sg_fadeTimer = nil;
            SGAmbientSetPlaying(NO);
        } else {
            float factor = (float)(sg_fadeRemaining / MAX(1.0, sg_fadeTotal));
            atomic_store_explicit(&sg_fadeFactor, fmaxf(0.0f, factor), memory_order_relaxed);
        }
    }];
}

@interface SGAmbientPlayerWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGAmbientPlayerWatcher
- (void)playerStateDidChange:(SPTPlayerState *)state {
    updateDuckAndPodcastState(state);
    reconcilePlayback();
    notifyPlayback();
    if (!state || state.isPaused) schedulePlaybackReconcile();
}
@end

static SGAmbientPlayerWatcher *sg_watcher;

__attribute__((constructor))
static void SGAmbientInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        sg_watcher = [SGAmbientPlayerWatcher new];
        SGAddPlayerStateObserver(sg_watcher);
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:NSOperationQueue.mainQueue
                       usingBlock:^(NSNotification *note) {
            BOOL began = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan;
            sg_interrupted = began;
            if (began) {
                keepSession(NO);
                atomic_store(&sg_engineActive, false);
                [sg_audioEngine stop];
            } else if ([note.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue] & AVAudioSessionInterruptionOptionShouldResume) {
                reconcilePlayback();
            } else if (sg_playing) {
                SGAmbientSetPlaying(NO);
            }
            notifyPlayback();
        }];
        [center addObserverForName:AVAudioEngineConfigurationChangeNotification object:nil queue:NSOperationQueue.mainQueue
                       usingBlock:^(NSNotification *note) {
            if (note.object != sg_audioEngine) return;
            reconcilePlayback();
            notifyPlayback();
        }];
        [center addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil queue:NSOperationQueue.mainQueue
                       usingBlock:^(NSNotification *note) {
            atomic_store(&sg_engineActive, false);
            sg_sourceNode = nil;
            sg_audioEngine = nil;
            reconcilePlayback();
            notifyPlayback();
        }];
        [center addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                       usingBlock:^(NSNotification *note) {
            if (!sg_playing) return;
            updateDuckAndPodcastState(SGPlayerState());
            notifyPlayback();
        }];
    });
}
