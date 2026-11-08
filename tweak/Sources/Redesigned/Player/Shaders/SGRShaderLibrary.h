#import <Foundation/Foundation.h>

extern NSUInteger const SGRShaderSourceLimit;
extern NSUInteger const SGRShaderProfileLimit;
extern NSNotificationName const SGRShaderLibraryChangedNotification;

@interface SGRShaderLibraryStore : NSObject
- (instancetype)initWithURL:(NSURL *)url defaults:(NSUserDefaults *)defaults;
@property (nonatomic, readonly) NSArray<NSDictionary *> *profiles;
@property (nonatomic, readonly) NSString *loadError;
- (NSDictionary *)validatedProfile:(id)value error:(NSError **)error;
- (BOOL)saveProfile:(NSDictionary *)profile error:(NSError **)error;
- (BOOL)deleteProfile:(NSString *)identifier error:(NSError **)error;
- (BOOL)isQuarantined:(NSString *)identifier;
- (void)retryProfile:(NSString *)identifier;
- (NSString *)beginSession:(NSString *)identifier;
- (void)endSession:(NSString *)token;
@end

SGRShaderLibraryStore *SGRShaderLibrary(void);
