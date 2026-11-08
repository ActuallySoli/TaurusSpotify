#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/Ambient/Ambient.h"

static char kAmbientChipKey;

@interface SGRAmbientChip : UIControl
- (void)reloadState;
@end

@implementation SGRAmbientChip {
    UIView *_glass;
    UIImageView *_icon;
    UILabel *_label;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _glass = SGGlassFor(self, &kAmbientChipKey);
    SGShapeGlass(_glass, 15, YES);
    _glass.userInteractionEnabled = NO;

    _icon = [UIImageView new];
    _icon.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:_icon];

    _label = [UILabel new];
    _label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [self addSubview:_label];

    [self addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(held:)];
    [self addGestureRecognizer:hold];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadState) name:SGAmbientDidChangeNotification object:nil];
    [self reloadState];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)tapped {
    SGAmbientPresentSheet();
}

- (void)held:(UILongPressGestureRecognizer *)hold {
    if (hold.state == UIGestureRecognizerStateBegan) {
        SGAmbientTogglePlaying();
    }
}

- (void)reloadState {
    BOOL playing = SGAmbientIsPlaying();
    SGAmbientScene *scene = SGAmbientActiveScene();
    NSString *sym = playing ? scene.symbol : @"cloud.rain";
    _icon.image = [UIImage systemImageNamed:sym withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold]];
    _icon.tintColor = playing ? SGRAccentColor() ?: UIColor.whiteColor : SGRSecondary();
    _label.text = playing ? scene.name : @"Ambient";
    _label.textColor = playing ? SGRPrimary() : SGRSecondary();
    self.accessibilityLabel = [NSString stringWithFormat:@"Ambient, %@", SGAmbientSummary()];
    [self setNeedsLayout];
}

- (CGSize)sizeThatFits:(CGSize)size {
    [_label sizeToFit];
    return CGSizeMake(10 + 14 + 5 + ceil(_label.bounds.size.width) + 10, 30);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _glass.frame = self.bounds;
    _icon.frame = CGRectMake(10, (self.bounds.size.height - 14) / 2, 14, 14);
    [_label sizeToFit];
    _label.frame = CGRectMake(29, (self.bounds.size.height - _label.bounds.size.height) / 2, _label.bounds.size.width, _label.bounds.size.height);
}

@end

static void placeAmbientChipInHeader(UIViewController *unit) {
    UIView *bar = unit.viewIfLoaded;
    if (!bar || bar.bounds.size.width < 200) return;
    SGRAmbientChip *chip = objc_getAssociatedObject(bar, &kAmbientChipKey);
    if (!SGFlag(SGKeyAmbientPlayerSwitch, NO)) {
        chip.alpha = 0;
        chip.userInteractionEnabled = NO;
        return;
    }
    if (!chip) {
        chip = [[SGRAmbientChip alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(bar, &kAmbientChipKey, chip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [bar addSubview:chip];
    }
    chip.alpha = 1;
    chip.userInteractionEnabled = YES;
    CGSize sz = [chip sizeThatFits:bar.bounds.size];
    chip.frame = CGRectMake(round((bar.bounds.size.width - sz.width) / 2), bar.bounds.size.height - sz.height - 2, sz.width, sz.height);
}

%hook _TtC21NowPlaying_ScrollImpl28NPVHeaderUnitViewController
- (void)viewDidLayoutSubviews {
    %orig;
    placeAmbientChipInHeader((UIViewController *)self);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
}
