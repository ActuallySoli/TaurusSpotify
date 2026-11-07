#import <UIKit/UIKit.h>

@interface SGRLyricsShaderEffect : NSObject
- (instancetype)initWithLabels:(NSArray<UILabel *> *)labels root:(UIView *)root style:(NSInteger)style intensity:(CGFloat)intensity speed:(CGFloat)speed;
- (void)showTime:(double)seconds running:(BOOL)running;
- (void)invalidate;
+ (NSUInteger)activeMaskCount;
+ (NSUInteger)activeMaskPixels;
@end
