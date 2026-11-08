#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import "Redesigned/Lyrics/SGRLyricsShaderEffect.h"

static void require(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL: %@", message); abort(); }
}
void SGLogMessage(NSString *message) { NSLog(@"%@", message); }

@interface Preview : UIViewController
@end
@implementation Preview {
    NSMutableArray<SGRLyricsShaderEffect *> *_effects;
    NSMutableArray<UIView *> *_roots;
    NSMutableArray<NSArray<UILabel *> *> *_labels;
    CADisplayLink *_link;
    double _start;
    BOOL _paused;
}
- (UILabel *)label:(NSString *)text frame:(CGRect)frame size:(CGFloat)size {
    UILabel *label = [[UILabel alloc] initWithFrame:frame];
    label.text = text;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:size weight:UIFontWeightBold];
    return label;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.035 alpha:1];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self.view addSubview:[self label:@"Lyrics shaders" frame:CGRectMake(28,78,340,44) size:28]];
    _roots = [NSMutableArray array];
    _labels = [NSMutableArray array];
    NSArray *names = @[@"Neon",@"Inferno",@"Hologram",@"Chrome",@"Blueprint"];
    for (NSUInteger i=0; i<names.count; i++) {
        UIView *root = [[UIView alloc] initWithFrame:CGRectMake(28,150+i*100,340,64)];
        [self.view addSubview:root];
        NSMutableArray *letters = [NSMutableArray array];
        NSString *name = names[i];
        CGFloat x = 0;
        for (NSUInteger j=0; j<name.length; j++) {
            UILabel *label = [self label:[name substringWithRange:NSMakeRange(j,1)] frame:CGRectMake(x,0,50,64) size:44];
            [label sizeToFit];
            label.frame = CGRectMake(x,0,label.bounds.size.width,64);
            x += label.bounds.size.width;
            [root addSubview:label];
            [letters addObject:label];
        }
        [_roots addObject:root];
        [_labels addObject:letters];
    }
    UILabel *arabic = [self label:@"مرحبا بالعالم" frame:CGRectMake(28,670,340,64) size:36];
    arabic.textAlignment = NSTextAlignmentRight;
    [self.view addSubview:arabic];
    [_roots addObject:arabic];
    [_labels addObject:@[arabic]];
    [self.view addSubview:[self label:@"Metal · live glyph masks" frame:CGRectMake(28,758,340,30) size:16]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stop) name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resume) name:UIApplicationDidBecomeActiveNotification object:nil];
}
- (SGRLyricsShaderEffect *)effect:(NSUInteger)i {
    return [[SGRLyricsShaderEffect alloc] initWithLabels:_labels[i] root:_roots[i] style:i<5?i+1:3 intensity:1 speed:1];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    require(SGRLyricsShaderEffect.activeMaskCount==0, @"initial masks");
    UILabel *label = _labels[0][0];
    require(![[SGRLyricsShaderEffect alloc] initWithLabels:@[label] root:_roots[0] style:0 intensity:1 speed:1], @"Classic must not allocate Metal");
    require(![[SGRLyricsShaderEffect alloc] initWithLabels:@[label] root:_roots[0] style:1 intensity:NAN speed:1], @"reject NaN");
    require(![[SGRLyricsShaderEffect alloc] initWithLabels:@[label] root:_roots[0] style:1 intensity:0 speed:1], @"zero intensity must not allocate");
    NSMutableArray *tooMany = [NSMutableArray array];
    for (int i=0;i<49;i++) [tooMany addObject:label];
    require(![[SGRLyricsShaderEffect alloc] initWithLabels:tooMany root:_roots[0] style:1 intensity:1 speed:1], @"mask budget");
    for (int i=0;i<30;i++) {
        SGRLyricsShaderEffect *effect = [self effect:0];
        require(effect != nil, @"create effect");
        [effect invalidate];
        [effect invalidate];
        require(SGRLyricsShaderEffect.activeMaskCount==0 && SGRLyricsShaderEffect.activeMaskPixels==0, @"repeated cleanup");
    }
    _effects = [NSMutableArray array];
    for (NSUInteger i=0;i<_roots.count;i++) {
        SGRLyricsShaderEffect *effect = [self effect:i];
        require(effect!=nil, @"all five effects and RTL must fit budget");
        [_effects addObject:effect];
    }
    _start = CACurrentMediaTime();
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    _link.preferredFrameRateRange = CAFrameRateRangeMake(80,120,120);
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        for (UIView *root in self->_roots) {
            CAMetalLayer *surface = (CAMetalLayer *)root.layer.sublayers.lastObject;
            require([surface isKindOfClass:CAMetalLayer.class] && !surface.hidden, @"compiled shader must be visible");
        }
        [self stop];
        for (UIView *root in self->_roots) require(root.layer.sublayers.lastObject.hidden, @"pause must hide shader");
        [self resume];
        for (SGRLyricsShaderEffect *effect in self->_effects) [effect invalidate];
        require(SGRLyricsShaderEffect.activeMaskCount==0 && SGRLyricsShaderEffect.activeMaskPixels==0, @"cleanup with frames in flight");
        [self->_effects removeAllObjects];
        for (NSUInteger i=0;i<self->_roots.count;i++) [self->_effects addObject:[self effect:i]];
        NSLog(@"PASS: validation, mask budget, repeated cleanup, five styles, RTL, pause/resume and in-flight cleanup");
        NSString *result = @"PASS: validation, mask budget, repeated cleanup, five styles, RTL, pause/resume and in-flight cleanup\n";
        [result writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/result.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    });
}
- (void)tick {
    double time = CACurrentMediaTime()-_start;
    for (NSUInteger i=0;i<_effects.count;i++) {
        if (!_paused && i<5) for (NSUInteger j=0;j<_labels[i].count;j++) _labels[i][j].transform = CGAffineTransformMakeTranslation(0,-5*sin(time*2-j*0.4));
        [_effects[i] showTime:time running:!_paused];
    }
}
- (void)stop { _paused = YES; for (SGRLyricsShaderEffect *effect in _effects) [effect showTime:0 running:NO]; }
- (void)resume { _paused = NO; }
@end

@interface Scene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic) UIWindow *window;
@end
@implementation Scene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [Preview new];
    [self.window makeKeyAndVisible];
}
@end
@interface App : UIResponder <UIApplicationDelegate>
@end
@implementation App
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Preview" sessionRole:session.role];
    configuration.delegateClass = Scene.class;
    return configuration;
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(App.class)); } }
