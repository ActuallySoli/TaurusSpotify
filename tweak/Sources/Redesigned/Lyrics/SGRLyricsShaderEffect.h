#import <UIKit/UIKit.h>

@interface SGRLyricsShaderEffect : NSObject
+ (void)prepare;
#if SGR_LYRICS_SHADER_TESTING
+ (void)setTestingRenderDelay:(NSTimeInterval)delay;
#endif
- (instancetype)initWithLabels:(NSArray<UILabel *> *)labels root:(UIView *)root style:(NSInteger)style intensity:(CGFloat)intensity speed:(CGFloat)speed;
- (void)showTime:(double)seconds running:(BOOL)running;
- (void)invalidate;
+ (NSUInteger)activeMaskCount;
+ (NSUInteger)activeMaskPixels;
@end
