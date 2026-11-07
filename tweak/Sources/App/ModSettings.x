#import "Core/SGCore.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import "Settings/SGModPage.h"
#import "Settings/SGGlowSwitch.h"
#import "Native/Home/Home.h"
#import "Shared/AdBlock/AdBlock.h"
#import "Shared/Player/PlayerSettings.h"
#import "Redesigned/Album/Album.h"
#import "Redesigned/Artist/Artist.h"
#import "Redesigned/Home/Home.h"
#import "Redesigned/Library/Library.h"
#import "Redesigned/Lyrics/Sing.h"
#import "Redesigned/Playlist/Playlist.h"
#import "Redesigned/Search/Search.h"
#import "Shared/Sing/SGSingModel.h"
#import "Shared/Flags/Flags.h"
#import "Shared/AudioEffects/AudioEffectsPage.h"
#import "Shared/Ambient/Ambient.h"
#import "Shared/AutoMix/AutoMix.h"
#import "Shared/LocalFiles/LocalFiles.h"
#import "Shared/Jam/WebJam.h"
#import "Shared/LiveActivity/LiveActivity.h"
#import "Shared/HeadGestures/HeadGestures.h"
#import "Shared/Haptics/Haptics.h"
#import "Shared/Downloads/Downloads.h"
#import "Shared/ListeningStats/ListeningStats.h"
#import "App/About/About.h"
#import "Pages.h"

static const CGFloat kRowHeight = 56;
static char kRowKey, kInsetKey;

// The Misc page's switch that hides the Discord banner row in modSettingsPage below.
#define SGKeyHideDiscordBanner @"spotifyglass.hide.discordBanner"

static SGModRow *pageRow(NSString *title, NSString *symbol, UIViewController *(^page)(void)) {
    return SGWithSymbol(SGPageRow(title, page), symbol);
}

// How long the wordmark takes to carry its spectrum all the way round, matching the glow switch's turn.
static const double kRainbowSpinSeconds = 4;

static UIColor *SGRainbowTextColor(CGFloat width, CGFloat height, double phase) {
    width = MAX(1, width);
    height = MAX(1, height);
    NSArray<UIColor *> *stops = SGGlowRainbowColors();
    NSUInteger count = stops.count;
    if (count < 2) return UIColor.whiteColor;
    NSMutableArray *colors = [NSMutableArray arrayWithCapacity:count];
    for (UIColor *stop in stops) [colors addObject:(id)stop.CGColor];
    CGFloat *locations = malloc(sizeof(CGFloat) * count);
    for (NSUInteger i = 0; i < count; i++) locations[i] = (CGFloat)i / (CGFloat)(count - 1);
    CGFloat offset = (CGFloat)phase * width;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(width, height)];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, locations);
        CGContextDrawLinearGradient(context.CGContext, gradient, CGPointMake(-offset, 0), CGPointMake(width - offset, 0), 0);
        CGContextDrawLinearGradient(context.CGContext, gradient, CGPointMake(width - offset, 0), CGPointMake(2 * width - offset, 0), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
    }];
    free(locations);
    return [UIColor colorWithPatternImage:image];
}

@interface SGTaurusSettingsPage : SGModPage <UITextFieldDelegate>
- (instancetype)initWithSections:(NSArray<SGModSection *> *)sections;
@end

@implementation SGTaurusSettingsPage {
    NSArray<SGModSection *> *_allSections;
    NSArray<SGModSection *> *_indexedChildSections;
    UIView *_masthead;
    UILabel *_mastheadTitle, *_mastheadByline, *_compactTitle;
    UISearchTextField *_searchField;
    BOOL _compactTitleVisible;
    CADisplayLink *_rainbowLink;
    CFTimeInterval _rainbowLast;
    double _rainbowPhase;
}

- (instancetype)initWithSections:(NSArray<SGModSection *> *)sections {
    if (!(self = [super initWithTitle:@"taurus" intro:nil sections:sections footer:@"Contributor: @Pulse-Ice (EeveeImmersive)\nBug fixes: @darkit"])) return nil;
    _allSections = [sections copy];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _masthead = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 168)];
    _masthead.backgroundColor = SGPageBackground();
    _masthead.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _mastheadTitle = [UILabel new];
    _mastheadTitle.text = @"taurus";
    _mastheadTitle.font = [UIFont systemFontOfSize:36 weight:UIFontWeightBold];
    _mastheadTitle.textAlignment = NSTextAlignmentRight;
    [_mastheadTitle sizeToFit];
    _mastheadTitle.textColor = SGRainbowTextColor(_mastheadTitle.bounds.size.width, _mastheadTitle.bounds.size.height, 0);
    _mastheadByline = [UILabel new];
    _mastheadByline.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _mastheadByline.textColor = [UIColor colorWithWhite:1 alpha:0.72];
    _mastheadByline.textAlignment = NSTextAlignmentRight;
    _searchField = [[UISearchTextField alloc] initWithFrame:CGRectZero];
    _searchField.placeholder = @"Search settings";
    _searchField.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _searchField.returnKeyType = UIReturnKeyDone;
    _searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _searchField.delegate = self;
    [_searchField addTarget:self action:@selector(searchChanged:) forControlEvents:UIControlEventEditingChanged];
    [_masthead addSubview:_mastheadTitle];
    [_masthead addSubview:_mastheadByline];
    [_masthead addSubview:_searchField];
    self.tableView.tableHeaderView = _masthead;

    _compactTitle = [UILabel new];
    _compactTitle.text = @"taurus";
    _compactTitle.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [_compactTitle sizeToFit];
    _compactTitle.textColor = SGRainbowTextColor(_compactTitle.bounds.size.width, _compactTitle.bounds.size.height, 0);
    _compactTitle.alpha = 0;
    _compactTitle.isAccessibilityElement = YES;
    _compactTitle.accessibilityElementsHidden = YES;
    self.navigationItem.titleView = _compactTitle;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

static void collectSectionsFromPage(NSString *prefix, SGModPage *page, NSMutableArray<SGModSection *> *into, int depth) {
    if (![page isKindOfClass:SGModPage.class] || depth > 2) return;
    for (SGModSection *sec in page.sections) {
        NSString *secTitle = sec.title.length ? [NSString stringWithFormat:@"%@ › %@", prefix, sec.title] : prefix;
        [into addObject:SGSection(secTitle, sec.rows)];
        for (SGModRow *row in sec.rows) {
            if (row.page && depth < 2) {
                UIViewController *child = row.page();
                if ([child isKindOfClass:SGModPage.class]) {
                    collectSectionsFromPage([NSString stringWithFormat:@"%@ › %@", prefix, row.title], (SGModPage *)child, into, depth + 1);
                }
            }
        }
    }
}

- (NSArray<SGModSection *> *)indexedChildSections {
    if (_indexedChildSections) return _indexedChildSections;
    NSMutableArray<SGModSection *> *collected = [NSMutableArray array];
    for (SGModSection *sec in _allSections) {
        for (SGModRow *row in sec.rows) {
            if (!row.page || [row.title isEqualToString:@"All flags"]) continue;
            UIViewController *child = row.page();
            if ([child isKindOfClass:SGModPage.class]) {
                collectSectionsFromPage(row.title, (SGModPage *)child, collected, 1);
            }
        }
    }
    _indexedChildSections = [collected copy];
    return _indexedChildSections;
}

- (void)searchChanged:(UITextField *)field {
    NSString *query = [field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!query.length) {
        [self setSections:_allSections];
        return;
    }
    NSMutableArray<SGModSection *> *results = [NSMutableArray array];
    NSMutableArray<SGModRow *> *rootMatches = [NSMutableArray array];
    for (SGModSection *sec in _allSections) {
        for (SGModRow *row in sec.rows) {
            if ([row.title localizedCaseInsensitiveContainsString:query]
                || (row.subtitle && [row.subtitle localizedCaseInsensitiveContainsString:query])) {
                [rootMatches addObject:row];
            }
        }
    }
    if (rootMatches.count) [results addObject:SGSection(@"Pages", rootMatches)];
    for (SGModSection *sec in [self indexedChildSections]) {
        NSMutableArray<SGModRow *> *matchingRows = [NSMutableArray array];
        for (SGModRow *row in sec.rows) {
            if ([row.title localizedCaseInsensitiveContainsString:query]
                || (row.subtitle && [row.subtitle localizedCaseInsensitiveContainsString:query])
                || (sec.title && [sec.title localizedCaseInsensitiveContainsString:query])) {
                [matchingRows addObject:row];
            }
        }
        if (matchingRows.count) [results addObject:SGSection(sec.title, matchingRows)];
    }
    [self setSections:results];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSArray<NSString *> *bylines = @[
        @"by natasha, samj, and arnaupq.", @"by natasha, arnaupq, and samj.",
        @"by samj, natasha, and arnaupq.", @"by samj, arnaupq, and natasha.",
        @"by arnaupq, natasha, and samj.", @"by arnaupq, samj, and natasha.",
    ];
    _mastheadByline.text = bylines[arc4random_uniform((uint32_t)bylines.count)];
    [self startRainbow];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self stopRainbow];
}

- (void)startRainbow {
    if (_rainbowLink) return;
    _rainbowLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(rainbowTick:)];
    _rainbowLink.preferredFrameRateRange = CAFrameRateRangeMake(24, 30, 30);
    [_rainbowLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)stopRainbow {
    [_rainbowLink invalidate];
    _rainbowLink = nil;
    _rainbowLast = 0;
}

- (void)rainbowTick:(CADisplayLink *)link {
    CFTimeInterval step = _rainbowLast > 0 ? MIN(link.timestamp - _rainbowLast, 0.1) : 0;
    _rainbowLast = link.timestamp;
    _rainbowPhase += step / kRainbowSpinSeconds;
    _rainbowPhase -= floor(_rainbowPhase);
    [self applyRainbow];
}

- (void)applyRainbow {
    CGSize compact = _compactTitle.bounds.size;
    if (_compactTitleVisible) {
        if (compact.width >= 1)
            _compactTitle.textColor = SGRainbowTextColor(compact.width, compact.height, _rainbowPhase);
        return;
    }
    CGSize title = _mastheadTitle.bounds.size;
    if (title.width >= 1)
        _mastheadTitle.textColor = SGRainbowTextColor(title.width, title.height, _rainbowPhase);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.tableView.bounds.size.width;
    if (width > 0) {
        BOOL sizeChanged = _masthead.bounds.size.width != width || _masthead.bounds.size.height != 168;
        _masthead.frame = CGRectMake(0, 0, width, 168);
        if (sizeChanged || self.tableView.tableHeaderView != _masthead) self.tableView.tableHeaderView = _masthead;
        _masthead.backgroundColor = UIColor.blackColor;
        _mastheadByline.textColor = UIColor.whiteColor;
        CGSize title = _mastheadTitle.bounds.size;
        _mastheadTitle.frame = CGRectMake(MAX(16, width - 16 - title.width), 24 + (48 - title.height) / 2, title.width, title.height);
        _mastheadByline.frame = CGRectMake(16, 72, MAX(0, width - 32), 24);
        _searchField.frame = CGRectMake(16, 110, MAX(0, width - 32), 38);
    }
    [self updateCompactTitleForScrollView:self.tableView];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self updateCompactTitleForScrollView:scrollView];
}

- (void)updateCompactTitleForScrollView:(UIScrollView *)scrollView {
    CGFloat scrolled = scrollView.contentOffset.y + scrollView.adjustedContentInset.top;
    BOOL show = scrolled >= CGRectGetHeight(_masthead.bounds);
    if (show == _compactTitleVisible) return;
    _compactTitleVisible = show;
    if (show) {
        _compactTitle.accessibilityElementsHidden = NO;
        [UIView animateWithDuration:0.18 animations:^{ self->_compactTitle.alpha = 1; }];
    } else {
        _compactTitle.accessibilityElementsHidden = YES;
        [UIView animateWithDuration:0.18 animations:^{ self->_compactTitle.alpha = 0; }];
    }
}

@end

static UIViewController *miscSettingsPage(void) {
    SGModRow *hideSigning = SGHideRow(@"Hide the lock screen alert", @"Hide the notice that this build cannot be opened from the lock screen", SGKeyHideSigningWarning);
    SGModRow *hideDiscord = SGHideRow(@"Hide the Discord banner", @"Hide the row here that advertises the Discord server", SGKeyHideDiscordBanner);
    SGModSection *banners = SGSection(nil, @[
        SGWithSymbol(hideSigning, @"lock.slash"),
        SGWithSymbol(hideDiscord, @"bubble.left.and.bubble.right"),
    ]);
    return [[SGModPage alloc] initWithTitle:@"Misc" intro:SGRestartNote sections:@[banners] footer:nil];
}

static UIViewController *modSettingsPage(void) {
    // Opening the page is the only thing that asks; the cache keeps it to once every six hours.
    SGCheckForUpdate();
    NSMutableArray<SGModSection *> *sections = [NSMutableArray array];
    SGModRow *signing = SGSigningWarningRow();
    if (signing) signing.visible = ^BOOL { return !SGFlag(SGKeyHideSigningWarning, NO); };
    NSMutableArray<SGModRow *> *topRows = [NSMutableArray array];
    SGModRow *update = SGActionRow(@"Taurus update available", @"Tap to view the latest release", ^{
        NSString *url = SGUpdateNewestRelease().url;
        if (url.length) SGOpenURL(url);
    });
    update.symbol = @"arrow.down.circle.fill";
    update.color = SGGreen();
    update.visible = ^BOOL { return SGUpdateVersion() != nil; };
    update.refreshOn = SGUpdateCheckedNotification;
    [topRows addObject:update];
    SGModRow *discord = SGLinkRow(@"Join the Discord", @"Release pings, help and previews", SGDiscordURL);
    discord.image = SGDiscordIcon();
    discord.color = SGDiscordColor();
    discord.visible = ^BOOL { return !SGFlag(SGKeyHideDiscordBanner, NO); };
    [topRows addObject:discord];
    if (signing) [topRows addObject:signing];
    [sections addObject:SGSection(nil, topRows)];
    SGModRow *mod = pageRow(@"Mod", @"info.circle", ^UIViewController *{ return SGAboutPage(); });
    mod.value = ^NSString *{ return @(SG_VERSION); };
    // The audio effects work on the sound, so both looks have them, with what they are doing beside the chevron.
    SGModRow *audioEffects = pageRow(@"Audio effects", @"slider.vertical.3", ^UIViewController *{ return SGDSPSettingsPage(); });
    audioEffects.value = ^NSString *{ return SGDSPSummary(); };
    SGModRow *downloads = pageRow(@"Downloads", @"arrow.down.circle", ^UIViewController *{ return SGDownloadsSettingsPage(); });
    downloads.value = ^NSString *{ return SGDownloadsRowSummary(); };
    downloads.refreshOn = SGDownloadsDidChangeNotification;
    SGModRow *ambient = pageRow(@"Ambient", @"cloud.rain", ^UIViewController *{ return SGAmbientSettingsPage(); });
    ambient.value = ^NSString *{ return SGAmbientSummary(); };
    ambient.refreshOn = SGAmbientDidChangeNotification;
    // Web Jam also lives under Premium, ads & privacy → Jam; the root row makes the browser queue findable.
    SGModRow *webJam = pageRow(@"Web Jam", @"globe", ^UIViewController *{ return SGWebJamPage(); });
    webJam.value = ^NSString *{ return SGWebJamStatus(); };
    webJam.refreshOn = SGWebJamDidChangeNotification;
    NSMutableArray<SGModRow *> *parts = [NSMutableArray arrayWithArray:@[
        pageRow(@"Appearance", @"paintpalette", ^UIViewController *{ return SGAppearanceSettingsPage(); }),
        pageRow(@"Navbar", @"dock.rectangle", ^UIViewController *{ return SGNavbarPage(); }),
        pageRow(@"Player", @"play.circle", ^UIViewController *{ return SGPlayerSettingsPage(); }),
        pageRow(@"Lyrics", @"quote.bubble", ^UIViewController *{ return SGLyricsSettingsPage(); }),
        downloads,
        pageRow(@"Your files", @"folder", ^UIViewController *{ return SGLocalFilesSettingsPage(); }),
        pageRow(@"Lock Screen", @"lock.iphone", ^UIViewController *{ return SGLockScreenSettingsPage(); }),
        audioEffects,
        ambient,
        pageRow(@"AutoMix", @"waveform.path", ^UIViewController *{ return SGAutoMixSettingsPage(); }),
        webJam,
        pageRow(@"Vibrations", @"iphone.radiowaves.left.and.right", ^UIViewController *{ return SGVibrationsSettingsPage(); }),
    ]];
    if (@available(iOS 17.0, *)) {
        SGModRow *liveActivity = pageRow(@"Live Activity", @"platter.filled.top.iphone", ^UIViewController *{ return SGLiveActivitySettingsPage(); });
        liveActivity.value = ^NSString *{ return SGLiveActivitySummary(); };
        [parts addObject:liveActivity];
    }
    [parts addObjectsFromArray:@[
        pageRow(@"AirPods gestures", @"airpods.pro", ^UIViewController *{ return SGHeadGesturesSettingsPage(); }),
        pageRow(@"Listening stats", @"chart.bar", ^UIViewController *{ return SGListeningStatsPage(); }),
    ]];
    if (SGRedesignedUIStored()) {
        [parts addObject:pageRow(@"Home", @"house", ^UIViewController *{ return SGRHomeSettingsPage(); })];
        [parts addObject:pageRow(@"Search", @"magnifyingglass", ^UIViewController *{ return SGRSearchSettingsPage(); })];
        [parts addObject:pageRow(@"Library", @"books.vertical", ^UIViewController *{ return SGRLibrarySettingsPage(); })];
        [parts addObject:pageRow(@"Playlists", @"music.note.list", ^UIViewController *{ return SGRPlaylistSettingsPage(); })];
        [parts addObject:pageRow(@"Albums", @"square.stack", ^UIViewController *{ return SGRAlbumSettingsPage(); })];
        [parts addObject:pageRow(@"Artists", @"person.2", ^UIViewController *{ return SGRArtistSettingsPage(); })];
    }
    else [parts addObject:pageRow(@"Home & Library", @"house", ^UIViewController *{ return SGHomeSettingsPage(); })];
    [parts addObject:pageRow(@"Misc", @"ellipsis.circle", ^UIViewController *{ return miscSettingsPage(); })];
    // Sing's microphone is the redesigned player's, so Karaoke is the redesign's; its row follows a download.
    if (SGRedesignedUIStored()) {
        SGModRow *karaoke = pageRow(@"Karaoke", @"music.mic", ^UIViewController *{ return SGRKaraokeSettingsPage(); });
        karaoke.value = ^NSString *{ return SGRKaraokeSummary(); };
        karaoke.refreshOn = SGSingModelDidChangeNotification;
        [sections addObject:SGSection(nil, @[karaoke])];
    }
    [sections addObjectsFromArray:@[
        SGSection(nil, parts),
        SGSection(nil, @[
            pageRow(@"Premium, ads & privacy", @"crown", ^UIViewController *{ return SGAdsSettingsPage(); }),
            pageRow(@"Labs", @"testtube.2", ^UIViewController *{ return SGLabsPage(); }),
        ]),
        SGSection(nil, @[
            pageRow(@"All flags", @"flag", ^UIViewController *{ return SGAllFlagsPage(); }),
            mod,
        ]),
    ]];
    return [[SGTaurusSettingsPage alloc] initWithSections:sections];
}

#pragma mark - row in the settings list

@interface SGModSettingsRow : UIControl
@property (nonatomic) BOOL drawer;
@end

@implementation SGModSettingsRow {
    UIImageView *_icon;
    UILabel *_title;
    UIImageView *_chevron;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _icon = SGSymbolView(@"slider.horizontal.3", 20, UIImageSymbolWeightRegular, 24);
    _title = [UILabel new];
    _title.text = @"taurus settings";
    _title.textColor = UIColor.whiteColor;
    _chevron = SGSymbolView(@"chevron.right", 11, UIImageSymbolWeightSemibold, 12);
    for (UIView *v in @[_icon, _title, _chevron]) [self addSubview:v];
    [self addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _title.font = SGTitleFont();
    CGFloat width = self.bounds.size.width, height = self.bounds.size.height, lead = self.drawer ? 4 : 0;
    _icon.frame = CGRectMake(12 + lead, (height - 24) / 2, 24, 24);
    _title.frame = CGRectMake(48 + lead, 0, width - 96, height);
    _chevron.frame = CGRectMake(width - 24, (height - 12) / 2, 12, 12);
    _chevron.hidden = self.drawer;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.5 : 1;
}

static UINavigationController *navigationIn(UIViewController *page) {
    if ([page isKindOfClass:UINavigationController.class]) return (UINavigationController *)page;
    for (UIViewController *child in page.childViewControllers) {
        UINavigationController *found = navigationIn(child);
        if (found) return found;
    }
    return nil;
}

- (void)open {
    UIViewController *owner = nil;
    for (UIResponder *r = self; r && !owner; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) owner = (UIViewController *)r;
    }
    UIViewController *presenting = self.drawer ? owner.presentingViewController : nil;
    if (presenting) {
        [presenting dismissViewControllerAnimated:YES completion:^{
            SGShowPage(navigationIn(presenting).topViewController ?: presenting, modSettingsPage());
        }];
        return;
    }
    SGShowPage(owner, modSettingsPage());
}

@end

// The tab bar's controller holds no stack itself; the selected tab's sits among its parent's children.
void SGOpenModSettings(UIView *source) {
    UIViewController *owner = nil;
    for (UIResponder *r = source; r && !owner; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) owner = (UIViewController *)r;
    }
    UINavigationController *nav = nil;
    for (UIViewController *page = owner; page && !nav; page = page.parentViewController) nav = navigationIn(page);
    SGShowPage(nav.topViewController ?: SGTopController(), modSettingsPage());
}

static void placeRow(UICollectionView *list, SGModSettingsRow *row) {
    SGAdoptFonts(list, row);
    CGFloat bottom = list.contentSize.height;
    row.hidden = !row.drawer && bottom <= 0;
    row.frame = CGRectMake(0, row.drawer ? -kRowHeight : bottom, list.bounds.size.width, kRowHeight);

    UIEdgeInsets inset = list.contentInset;
    NSValue *applied = objc_getAssociatedObject(list, &kInsetKey);
    if (applied && UIEdgeInsetsEqualToEdgeInsets(inset, applied.UIEdgeInsetsValue)) return;
    if (row.drawer) inset.top += kRowHeight;
    else inset.bottom += kRowHeight;
    objc_setAssociatedObject(list, &kInsetKey, [NSValue valueWithUIEdgeInsets:inset], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    list.contentInset = inset;
}

static SGModSettingsRow *ensureDrawerRow(UICollectionView *list) {
    SGModSettingsRow *row = objc_getAssociatedObject(list, &kRowKey);
    if (!row) {
        row = [[SGModSettingsRow alloc] initWithFrame:CGRectZero];
        row.drawer = YES;
        objc_setAssociatedObject(list, &kRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (row.superview != list) [list addSubview:row];
    return row;
}

static UIViewController *settingsListIn(UIViewController *page, Class kind) {
    if ([page isKindOfClass:kind]) return page;
    for (UIViewController *child in page.childViewControllers) {
        UIViewController *found = settingsListIn(child, kind);
        if (found) return found;
    }
    return nil;
}

static BOOL isSettingsRoot(UIViewController *list) {
    for (UIViewController *page in list.navigationController.viewControllers) {
        UIViewController *found = settingsListIn(page, list.class);
        if (found) return found == list;
    }
    return YES;
}

%hook _TtC21Settings_PlatformImpl26SettingsListViewController
- (void)viewDidLayoutSubviews {
    %orig;
    BOOL root = isSettingsRoot((UIViewController *)self);
    for (UIView *sub in ((UIViewController *)self).view.subviews) {
        if (![sub isKindOfClass:UICollectionView.class]) continue;
        SGModSettingsRow *row = objc_getAssociatedObject(sub, &kRowKey);
        if (!root) {
            [row removeFromSuperview];
            objc_setAssociatedObject(sub, &kRowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            continue;
        }
        if (row) continue;
        row = [[SGModSettingsRow alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(sub, &kRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sub addSubview:row];
    }
}
%end

static UIColor *planBadgeColor(void) {
    if (!SGRedesignedUI()) return SGGreen();
    NSInteger rgb = SGInt(@"spotifyglass.redesign.accent", 0x37F200);
    if (rgb < 0 || rgb > 0xFFFFFF) return SGGreen();
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0 alpha:1];
}

static __weak UIView *sg_drawerRoot;
static char kPlanBadgeLabelKey;

static NSString *sidebarBadgeText(void) {
    NSString *text = [NSUserDefaults.standardUserDefaults stringForKey:SGKeySidebarBadgeText];
    return text.length ? text : @"Taurus";
}

static BOOL isSidebarBadgeText(NSString *text) {
    return [text isEqualToString:@"Spotify Free"] || [text isEqualToString:@"Taurine"]
        || [text isEqualToString:@"Taurus"] || [text isEqualToString:sidebarBadgeText()];
}

static BOOL isDrawerBadgeLabel(UILabel *label) {
    for (UIView *view = label; view; view = view.superview) {
        if (view == sg_drawerRoot ||
            [NSStringFromClass(view.class) containsString:@"SideDrawerListCollectionView"]) return YES;
    }
    return NO;
}

static BOOL isPlanBadgeLabel(UILabel *label) {
    return objc_getAssociatedObject(label, &kPlanBadgeLabelKey) != nil || isSidebarBadgeText(label.text);
}

static void stylePlanBadgeLabel(UILabel *label) {
    UIColor *color = planBadgeColor();
    CGFloat red = 0, green = 0, blue = 0, alpha = 0;
    [color getRed:&red green:&green blue:&blue alpha:&alpha];
    NSString *text = sidebarBadgeText();
    if (![label.text isEqualToString:text]) label.text = text;
    label.textColor = (0.2126 * red + 0.7152 * green + 0.0722 * blue) > 0.55 ? UIColor.blackColor : UIColor.whiteColor;
    label.backgroundColor = color;
    label.layer.backgroundColor = color.CGColor;
    label.layer.cornerRadius = MIN(8, CGRectGetHeight(label.bounds) / 2);
    label.clipsToBounds = YES;
    objc_setAssociatedObject(label, &kPlanBadgeLabelKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CGRect labelBounds = label.bounds;
    for (UIView *badge = label.superview; badge && badge != sg_drawerRoot; badge = badge.superview) {
        CGRect labelFrame = [label convertRect:labelBounds toView:badge];
        if (badge.bounds.size.width > CGRectGetWidth(labelFrame) + 80 ||
            badge.bounds.size.height > CGRectGetHeight(labelFrame) + 32) break;
        badge.backgroundColor = color;
        badge.layer.backgroundColor = color.CGColor;
        badge.layer.cornerRadius = MIN(8, CGRectGetHeight(badge.bounds) / 2);
        badge.layer.masksToBounds = YES;
    }
}

static void updatePlanBadge(UIView *root) {
    SGForEachView(root, ^(UIView *view) {
        if (![view isKindOfClass:UILabel.class]) return;
        UILabel *label = (UILabel *)view;
        if (!isPlanBadgeLabel(label)) return;
        stylePlanBadgeLabel(label);
    });
}

%hook UILabel
- (void)setText:(NSString *)text {
    %orig;
    if (![text isEqualToString:@"Spotify Free"] && ![text isEqualToString:@"Taurine"] &&
        ![text isEqualToString:@"Taurus"]) return;
    if (!isDrawerBadgeLabel(self)) return;
    stylePlanBadgeLabel(self);
}
%end

// Keep the drawer's plan badge and the Taurus settings row current as Spotify rebuilds its view.
%hook _TtC23SideDrawer_ListPageImpl18ListViewController
- (void)viewDidLayoutSubviews {
    %orig;
    sg_drawerRoot = ((UIViewController *)self).view;
    updatePlanBadge(sg_drawerRoot);
    SGForEachView(sg_drawerRoot, ^(UIView *view) {
        if (![view isKindOfClass:UICollectionView.class] ||
            ![NSStringFromClass(view.class) containsString:@"SideDrawerListCollectionView"]) return;
        ensureDrawerRow((UICollectionView *)view);
    });
}
%end

// The lists lay out after their controllers and again whenever their content changes.
%hook UICollectionView
- (void)layoutSubviews {
    %orig;
    SGModSettingsRow *row = objc_getAssociatedObject(self, &kRowKey);
    BOOL drawerList = [NSStringFromClass(self.class) containsString:@"SideDrawerListCollectionView"];
    if (drawerList) updatePlanBadge(self);
    if (!row && drawerList)
        row = ensureDrawerRow(self);
    if (row && row.superview != self) [self addSubview:row];
    if (row) placeRow(self, row);
}
%end

%ctor {
    %init;
    [NSNotificationCenter.defaultCenter addObserverForName:SGSidebarBadgeTextDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
        if (sg_drawerRoot) updatePlanBadge(sg_drawerRoot);
    }];
    SGRequireClasses(@[@"_TtC21Settings_PlatformImpl26SettingsListViewController", @"_TtC23SideDrawer_ListPageImpl18ListViewController"]);
    SGRegisterPages();
    SGCheckSigningOnce();
}
