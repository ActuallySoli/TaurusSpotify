#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Ambient.h"

@interface SGAmbientHeroView : UIView
- (void)reloadState;
@end

@implementation SGAmbientHeroView {
    CAGradientLayer *_gradient;
    UIImageView *_icon;
    UILabel *_title, *_subtitle;
    UIButton *_playButton;
    UIScrollView *_sceneStrip;
    NSMutableArray<UIButton *> *_scenePills;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.tag = 100;
    card.clipsToBounds = YES;
    card.layer.cornerRadius = 22;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:card];

    _gradient = [CAGradientLayer layer];
    _gradient.startPoint = CGPointMake(0, 0);
    _gradient.endPoint = CGPointMake(1, 1);
    [card.layer addSublayer:_gradient];

    _icon = [UIImageView new];
    _icon.tintColor = UIColor.whiteColor;
    _icon.contentMode = UIViewContentModeScaleAspectFit;
    [card addSubview:_icon];

    _title = [UILabel new];
    _title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    _title.textColor = UIColor.whiteColor;
    [card addSubview:_title];

    _subtitle = [UILabel new];
    _subtitle.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _subtitle.textColor = [UIColor colorWithWhite:1 alpha:0.78];
    _subtitle.numberOfLines = 2;
    [card addSubview:_subtitle];

    _playButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _playButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.2];
    _playButton.tintColor = UIColor.whiteColor;
    _playButton.layer.cornerRadius = 22;
    _playButton.layer.cornerCurve = kCACornerCurveContinuous;
    [_playButton addTarget:self action:@selector(togglePlay) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:_playButton];

    _sceneStrip = [UIScrollView new];
    _sceneStrip.showsHorizontalScrollIndicator = NO;
    [self addSubview:_sceneStrip];

    _scenePills = [NSMutableArray array];
    NSArray<SGAmbientScene *> *scenes = SGAmbientAllScenes();
    for (NSUInteger i = 0; i < scenes.count; i++) {
        SGAmbientScene *s = scenes[i];
        UIButton *pill = [UIButton buttonWithType:UIButtonTypeSystem];
        pill.tag = (NSInteger)i;
        [pill setTitle:[NSString stringWithFormat:@"  %@", s.name] forState:UIControlStateNormal];
        UIImage *img = [UIImage systemImageNamed:s.symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]];
        [pill setImage:img forState:UIControlStateNormal];
        pill.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        pill.layer.cornerRadius = 18;
        pill.layer.cornerCurve = kCACornerCurveContinuous;
        [pill addTarget:self action:@selector(scenePicked:) forControlEvents:UIControlEventTouchUpInside];
        [_sceneStrip addSubview:pill];
        [_scenePills addObject:pill];
    }

    [self reloadState];
    return self;
}

- (void)togglePlay {
    SGAmbientTogglePlaying();
    [self reloadState];
}

- (void)scenePicked:(UIButton *)sender {
    NSArray<SGAmbientScene *> *scenes = SGAmbientAllScenes();
    if ((NSUInteger)sender.tag < scenes.count) {
        SGAmbientApplyScene(scenes[(NSUInteger)sender.tag].key);
        if (!SGAmbientIsEnabled()) SGAmbientSetPlaying(YES);
        [self reloadState];
    }
}

- (void)reloadState {
    SGAmbientScene *scene = SGAmbientActiveScene();
    BOOL playing = SGAmbientIsPlaying();
    BOOL enabled = SGAmbientIsEnabled();
    NSUInteger rgb = scene.tintRGB;
    UIColor *top = [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                                   green:((rgb >> 8) & 0xFF) / 255.0
                                    blue:(rgb & 0xFF) / 255.0
                                   alpha:playing ? 0.85 : 0.42];
    UIColor *bottom = [UIColor colorWithRed:0.06 green:0.07 blue:0.10 alpha:1.0];
    _gradient.colors = @[(id)top.CGColor, (id)bottom.CGColor];
    _icon.image = [UIImage systemImageNamed:scene.symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:28 weight:UIImageSymbolWeightSemibold]];
    _title.text = scene.name;
    _subtitle.text = playing || (!enabled && [SGAmbientSummary() isEqualToString:@"Off"])
        ? scene.subtitle : SGAmbientSummary();
    NSString *playSym = enabled ? @"stop.fill" : @"play.fill";
    [_playButton setImage:[UIImage systemImageNamed:playSym withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    _playButton.accessibilityLabel = enabled ? @"Stop ambient" : @"Play ambient";

    NSArray<SGAmbientScene *> *scenes = SGAmbientAllScenes();
    for (NSUInteger i = 0; i < _scenePills.count && i < scenes.count; i++) {
        UIButton *pill = _scenePills[i];
        BOOL active = [scenes[i].key isEqualToString:scene.key];
        pill.backgroundColor = active ? [UIColor colorWithWhite:1 alpha:0.22] : [UIColor colorWithWhite:1 alpha:0.08];
        pill.tintColor = active ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.7];
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat inset = 16;
    UIView *card = [self viewWithTag:100];
    card.frame = CGRectMake(inset, 12, MAX(0, w - 2 * inset), 118);
    _gradient.frame = card.bounds;

    _icon.frame = CGRectMake(18, 20, 34, 34);
    _playButton.frame = CGRectMake(card.bounds.size.width - 18 - 44, (card.bounds.size.height - 44) / 2, 44, 44);
    CGFloat textX = CGRectGetMaxX(_icon.frame) + 14;
    CGFloat textW = MAX(0, CGRectGetMinX(_playButton.frame) - textX - 12);
    _title.frame = CGRectMake(textX, 20, textW, 26);
    _subtitle.frame = CGRectMake(textX, 48, textW, 42);

    _sceneStrip.frame = CGRectMake(0, CGRectGetMaxY(card.frame) + 12, w, 40);
    CGFloat x = inset;
    for (UIButton *pill in _scenePills) {
        [pill sizeToFit];
        CGFloat pw = pill.bounds.size.width + 28;
        pill.frame = CGRectMake(x, 2, pw, 36);
        x += pw + 8;
    }
    _sceneStrip.contentSize = CGSizeMake(x + inset, 40);
}

@end

static NSArray<SGModSection *> *ambientSoundSections(void) {
    SGModRow *master = SGSliderRow(@"Ambient volume", nil, 0, 100, 5,
                                   ^double { return round(SGAmbientMasterVolume() * 100.0); },
                                   ^(double value) { SGAmbientSetMasterVolume((float)(value / 100.0)); },
                                   ^NSString *(double value) { return [NSString stringWithFormat:@"%.0f%%", value]; });
    NSMutableArray<SGModRow *> *soundRows = [NSMutableArray array];
    for (SGAmbientSound *sound in SGAmbientAllSounds()) {
        NSString *key = sound.key;
        SGModRow *row = SGSliderRow(sound.name, nil, 0, 100, 5,
                                    ^double { return round(SGAmbientLevelForSound(key) * 100.0); },
                                    ^(double value) { SGAmbientSetLevelForSound(key, (float)(value / 100.0)); },
                                    ^NSString *(double value) { return [NSString stringWithFormat:@"%.0f%%", value]; });
        row.symbol = sound.symbol;
        row.refreshOn = SGAmbientDidChangeNotification;
        [soundRows addObject:row];
    }
    SGModRow *sleepTimer = SGMenuRow(@"Sleep timer fade", @[@"Off", @"15 minutes", @"30 minutes", @"60 minutes"],
                                     ^NSString *{ return @"Set timer"; },
                                     ^(NSInteger index) {
                                         if (index == 0) SGAmbientStartSleepFade(0);
                                         else if (index == 1) SGAmbientStartSleepFade(15 * 60);
                                         else if (index == 2) SGAmbientStartSleepFade(30 * 60);
                                         else if (index == 3) SGAmbientStartSleepFade(60 * 60);
                                     });
    return @[
        SGSection(@"Master", @[master, sleepTimer]),
        SGSection(@"Sounds", soundRows),
    ];
}

@interface SGAmbientPageController : SGModPage
@property (nonatomic, strong) SGAmbientHeroView *hero;
@end

@implementation SGAmbientPageController
- (void)viewDidLoad {
    [super viewDidLoad];
    _hero = [[SGAmbientHeroView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 190)];
    self.tableView.tableHeaderView = _hero;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(ambientChanged) name:SGAmbientDidChangeNotification object:nil];
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (void)ambientChanged {
    [_hero reloadState];
    [self.tableView reloadData];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (_hero.bounds.size.width != self.tableView.bounds.size.width) {
        _hero.frame = CGRectMake(0, 0, self.tableView.bounds.size.width, 190);
        self.tableView.tableHeaderView = _hero;
    }
}
@end

UIViewController *SGAmbientMixerSheet(void) {
    SGAmbientPageController *page = [[SGAmbientPageController alloc] initWithTitle:@"Ambient"
                                                                             intro:nil
                                                                          sections:ambientSoundSections()
                                                                            footer:@"Ambient mixes rain, fire, the sea and more into what you hear, beside your music or instead of it."];
    return page;
}

void SGAmbientPresentSheet(void) {
    UIViewController *top = SGTopController();
    if (!top) return;
    UIViewController *sheet = SGAmbientMixerSheet();
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:sheet];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    sheet.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                            target:sheet
                                                                                            action:@selector(sg_dismissAmbientSheet)];
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *pres = nav.sheetPresentationController;
        if (pres) {
            pres.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
            pres.prefersGrabberVisible = YES;
        }
    }
    [top presentViewController:nav animated:YES completion:nil];
}

@implementation UIViewController (SGAmbientSheetDismiss)
- (void)sg_dismissAmbientSheet {
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

UIViewController *SGAmbientSettingsPage(void) {
    NSMutableArray<SGModSection *> *sections = [NSMutableArray arrayWithArray:ambientSoundSections()];
    SGModRow *playerSwitch = SGOptionRow(@"Show switch in player", @"Quick Ambient pill in the player header", SGKeyAmbientPlayerSwitch);
    SGModRow *homeCard = SGOptionRow(@"Home card", @"Show the Ambient bar at the top of Home", SGKeyAmbientHomeCard);
    SGModRow *duck = SGSwitchRow(@"Lower during loud music", @"Softly lower Ambient volume while a song is playing", SGKeyAmbientDuck);
    SGModRow *podcastPause = SGSwitchRow(@"Pause for podcasts", @"Automatically pause Ambient while listening to an episode", SGKeyAmbientPodcastPause);
    SGModRow *timerFade = SGSwitchRow(@"Sleep timer fade", @"Fade Ambient out smoothly when the sleep timer ends", SGKeyAmbientTimerFade);
    [sections addObject:SGNotedSection(@"Options", @[playerSwitch, homeCard, duck, podcastPause, timerFade],
                                       @"Ambient mixes rain, fire, the sea and more into what you hear, beside your music or instead of it, from the player, a card on Home, or right here.")];
    return [[SGAmbientPageController alloc] initWithTitle:@"Ambient" intro:nil sections:sections footer:nil];
}
