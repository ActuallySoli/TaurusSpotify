#import <UIKit/UIKit.h>

@class SGModSection;
@class SGModRow;

#define SGKeyAmbient @"spotifyglass.ambient"
#define SGKeyAmbientState @"spotifyglass.ambient.state"
#define SGKeyAmbientPlayerSwitch @"spotifyglass.ambient.playerSwitch"
#define SGKeyAmbientHomeCard @"spotifyglass.ambient.homeCard"
#define SGKeyAmbientDuck @"spotifyglass.ambient.duck"
#define SGKeyAmbientPodcastPause @"spotifyglass.ambient.podcastPause"
#define SGKeyAmbientTimerFade @"spotifyglass.ambient.timerFade"

extern NSNotificationName const SGAmbientDidChangeNotification;
extern NSNotificationName const SGAmbientEngineStateDidChangeNotification;

@interface SGAmbientSound : NSObject
@property (nonatomic, copy, readonly) NSString *key;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *symbol;
@property (nonatomic, readonly) float defaultLevel;
- (instancetype)initWithKey:(NSString *)key name:(NSString *)name symbol:(NSString *)symbol defaultLevel:(float)level;
@end

@interface SGAmbientScene : NSObject
@property (nonatomic, copy, readonly) NSString *key;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *subtitle;
@property (nonatomic, copy, readonly) NSString *symbol;
@property (nonatomic, readonly) NSUInteger tintRGB;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSNumber *> *levels;
- (instancetype)initWithKey:(NSString *)key name:(NSString *)name subtitle:(NSString *)subtitle symbol:(NSString *)symbol tintRGB:(NSUInteger)tintRGB levels:(NSDictionary<NSString *, NSNumber *> *)levels;
@end

NSArray<SGAmbientSound *> *SGAmbientAllSounds(void);
NSArray<SGAmbientScene *> *SGAmbientAllScenes(void);

BOOL SGAmbientIsPlaying(void);
BOOL SGAmbientIsEnabled(void); // remains enabled through a temporary system/podcast interruption
void SGAmbientSetPlaying(BOOL playing);
void SGAmbientTogglePlaying(void);

NSString *SGAmbientActiveSceneKey(void);
SGAmbientScene *SGAmbientActiveScene(void);
void SGAmbientApplyScene(NSString *sceneKey);

float SGAmbientMasterVolume(void);
void SGAmbientSetMasterVolume(float volume);

float SGAmbientLevelForSound(NSString *soundKey);
void SGAmbientSetLevelForSound(NSString *soundKey, float level);

NSString *SGAmbientSummary(void);
void SGAmbientStartSleepFade(NSTimeInterval duration);
void SGAmbientPresentSheet(void);

UIViewController *SGAmbientMixerSheet(void);
UIViewController *SGAmbientSettingsPage(void);
