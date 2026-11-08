// Unique runtime names avoid colliding with Apple's private macOS audio classes.
#define AVAudioSession SGAmbientTestAudioSession
#define AVAudioEngine SGAmbientTestAudioEngine
#define AVAudioSourceNode SGAmbientTestAudioSourceNode
#define AVAudioFormat SGAmbientTestAudioFormat
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
typedef UInt32 AVAudioFrameCount;
typedef NSUInteger AVAudioSessionSetActiveOptions;
static const NSUInteger AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation = 1;
static NSString *const AVAudioSessionCategoryPlayback = @"playback";
static NSString *const AVAudioSessionCategoryPlayAndRecord = @"playAndRecord";
static const NSUInteger AVAudioSessionCategoryOptionMixWithOthers = 1;
static NSString *const AVAudioSessionInterruptionNotification = @"interruption";
static NSString *const AVAudioEngineConfigurationChangeNotification = @"configuration";
static NSString *const AVAudioSessionMediaServicesWereResetNotification = @"reset";
static NSString *const AVAudioSessionInterruptionTypeKey = @"type";
static NSString *const AVAudioSessionInterruptionOptionKey = @"options";
static const NSUInteger AVAudioSessionInterruptionTypeBegan = 1;
static const NSUInteger AVAudioSessionInterruptionOptionShouldResume = 1;
@interface AVAudioFormat : NSObject
- (instancetype)initStandardFormatWithSampleRate:(double)rate channels:(UInt32)channels;
@end
typedef OSStatus (^SGTestRender)(BOOL *, const AudioTimeStamp *, AVAudioFrameCount, AudioBufferList *);
@interface AVAudioSourceNode : NSObject
@property (copy) SGTestRender render;
- (instancetype)initWithFormat:(AVAudioFormat *)format renderBlock:(SGTestRender)block;
@end
@interface AVAudioEngine : NSObject
@property BOOL isRunning;
@property (readonly) id mainMixerNode;
- (void)attachNode:(id)node;
- (void)connect:(id)node to:(id)mixer format:(AVAudioFormat *)format;
- (BOOL)startAndReturnError:(NSError **)error;
- (void)stop;
@end
@interface AVAudioSession : NSObject
@property NSString *category;
@property BOOL active;
@property BOOL failActivation;
@property BOOL failCategory;
@property BOOL failEngine;
@property NSUInteger deactivations;
@property NSUInteger lastOptions;
+ (instancetype)sharedInstance;
- (BOOL)setCategory:(NSString *)category withOptions:(NSUInteger)options error:(NSError **)error;
- (BOOL)setActive:(BOOL)active error:(NSError **)error;
- (BOOL)setActive:(BOOL)active withOptions:(NSUInteger)options error:(NSError **)error;
@end
