#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "ListeningStats.h"
#import "SGPlayLog.h"
#import "Recap.h"

NSNotificationName const SGRecapDueDidChangeNotification = @"spotifyglass.recapDueDidChange";

@interface SGRecapData : NSObject
@property (nonatomic, copy) NSString *title, *subtitle;
@property (nonatomic) NSUInteger plays, uniqueTracks, uniqueArtists, activeDays;
@property (nonatomic) int64_t totalMs;
@property (nonatomic, copy) NSArray<SGStatEntry *> *topTracks, *topArtists, *topAlbums;
@property (nonatomic) NSUInteger morningPlays, afternoonPlays, eveningPlays, nightPlays;
@end

@implementation SGRecapData
@end

static SGRecapData *buildRecapData(NSString *title, NSString *subtitle, int64_t since, int64_t until) {
    NSArray<SGPlay *> *allPlays = SGListeningLog().plays;
    NSMutableArray<SGPlay *> *filtered = [NSMutableArray array];
    NSMutableSet<NSNumber *> *days = [NSMutableSet set];
    NSMutableSet<NSString *> *uTracks = [NSMutableSet set];
    NSMutableSet<NSString *> *uArtists = [NSMutableSet set];
    NSUInteger morning = 0, afternoon = 0, evening = 0, night = 0;

    NSCalendar *cal = NSCalendar.currentCalendar;
    for (SGPlay *play in allPlays) {
        if (play.end < since || (until > 0 && play.end >= until)) continue;
        [filtered addObject:play];
        [days addObject:@(play.end / 86400)];
        if (play.title.length) [uTracks addObject:[NSString stringWithFormat:@"%@\t%@", play.title, play.artist ?: @""]];
        if (play.artist.length) [uArtists addObject:play.artist];
        NSDate *dt = [NSDate dateWithTimeIntervalSince1970:play.end];
        NSInteger hour = [cal component:NSCalendarUnitHour fromDate:dt];
        if (hour >= 5 && hour < 12) morning++;
        else if (hour >= 12 && hour < 17) afternoon++;
        else if (hour >= 17 && hour < 22) evening++;
        else night++;
    }

    SGStats *stats = SGStatsSince(filtered, 0, 10);
    SGRecapData *recap = [SGRecapData new];
    recap.title = title;
    recap.subtitle = subtitle;
    recap.plays = stats.plays;
    recap.totalMs = stats.ms;
    recap.uniqueTracks = uTracks.count;
    recap.uniqueArtists = uArtists.count;
    recap.activeDays = days.count;
    recap.topTracks = stats.tracks ?: @[];
    recap.topArtists = stats.artists ?: @[];
    recap.topAlbums = stats.albums ?: @[];
    recap.morningPlays = morning;
    recap.afternoonPlays = afternoon;
    recap.eveningPlays = evening;
    recap.nightPlays = night;
    return recap;
}

static NSString *formatRecapMinutes(int64_t ms) {
    int64_t mins = ms / 60000;
    if (mins < 60) return [NSString stringWithFormat:@"%lld min", mins];
    return [NSString stringWithFormat:@"%lld hr %lld min", mins / 60, mins % 60];
}

@interface SGRecapStoryController : UIViewController
- (instancetype)initWithRecap:(SGRecapData *)recap;
@end

@implementation SGRecapStoryController {
    SGRecapData *_recap;
    NSInteger _slideIndex;
    NSInteger _slideCount;
    CAGradientLayer *_bgGradient;
    UIView *_progressHost;
    NSMutableArray<UIView *> *_progressFills;
    UIView *_cardContainer;
    UIView *_posterCard;
    NSTimer *_timer;
    CGFloat _slideProgress;
}

- (instancetype)initWithRecap:(SGRecapData *)recap {
    if (!(self = [super init])) return nil;
    _recap = recap;
    _slideCount = 6;
    _slideIndex = 0;
    self.modalPresentationStyle = UIModalPresentationFullScreen;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    _bgGradient = [CAGradientLayer layer];
    _bgGradient.startPoint = CGPointMake(0, 0);
    _bgGradient.endPoint = CGPointMake(1, 1);
    [self.view.layer addSublayer:_bgGradient];

    _progressHost = [UIView new];
    [self.view addSubview:_progressHost];
    _progressFills = [NSMutableArray array];
    for (NSInteger i = 0; i < _slideCount; i++) {
        UIView *track = [UIView new];
        track.tag = 200 + i;
        track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.24];
        track.layer.cornerRadius = 1.5;
        track.clipsToBounds = YES;
        UIView *fill = [UIView new];
        fill.backgroundColor = UIColor.whiteColor;
        [track addSubview:fill];
        [_progressHost addSubview:track];
        [_progressFills addObject:fill];
    }

    _cardContainer = [UIView new];
    [self.view addSubview:_cardContainer];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.tag = 901;
    [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightMedium]] forState:UIControlStateNormal];
    close.tintColor = [UIColor colorWithWhite:1 alpha:0.85];
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    UIButton *share = [UIButton buttonWithType:UIButtonTypeSystem];
    share.tag = 902;
    [share setImage:[UIImage systemImageNamed:@"square.and.arrow.up.circle.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightMedium]] forState:UIControlStateNormal];
    share.tintColor = [UIColor colorWithWhite:1 alpha:0.85];
    [share addTarget:self action:@selector(shareTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:share];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(screenTapped:)];
    [self.view addGestureRecognizer:tap];

    [self showSlide:0 animated:NO];
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_timer invalidate];
    _timer = nil;
}

- (void)closeTapped {
    [_timer invalidate];
    _timer = nil;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)shareTapped {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:_cardContainer.bounds.size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [_bgGradient renderInContext:ctx.CGContext];
        [_cardContainer drawViewHierarchyInRect:_cardContainer.bounds afterScreenUpdates:YES];
    }];
    if (!image) return;
    UIActivityViewController *act = [[UIActivityViewController alloc] initWithActivityItems:@[image] applicationActivities:nil];
    act.popoverPresentationController.sourceView = self.view;
    [self presentViewController:act animated:YES completion:nil];
}

- (void)screenTapped:(UITapGestureRecognizer *)tap {
    CGPoint pt = [tap locationInView:self.view];
    if (pt.y < 110) return;
    if (pt.x < self.view.bounds.size.width * 0.33) {
        [self showSlide:MAX(0, _slideIndex - 1) animated:YES];
    } else {
        if (_slideIndex + 1 < _slideCount) [self showSlide:_slideIndex + 1 animated:YES];
        else [self closeTapped];
    }
}

- (void)tick {
    _slideProgress += 0.05 / 6.0;
    if (_slideProgress >= 1.0) {
        if (_slideIndex + 1 < _slideCount) {
            [self showSlide:_slideIndex + 1 animated:YES];
        } else {
            _slideProgress = 1.0;
            [_timer invalidate];
            _timer = nil;
        }
    }
    [self layoutProgress];
}

- (void)layoutProgress {
    CGFloat w = _progressHost.bounds.size.width;
    if (w <= 0) return;
    CGFloat gap = 6;
    CGFloat barW = (w - gap * (_slideCount - 1)) / _slideCount;
    for (NSInteger i = 0; i < _slideCount; i++) {
        UIView *track = [_progressHost viewWithTag:200 + i];
        track.frame = CGRectMake(i * (barW + gap), 0, barW, 3);
        UIView *fill = _progressFills[(NSUInteger)i];
        CGFloat frac = i < _slideIndex ? 1.0 : (i == _slideIndex ? MIN(1.0, _slideProgress) : 0.0);
        fill.frame = CGRectMake(0, 0, barW * frac, 3);
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _bgGradient.frame = self.view.bounds;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    _progressHost.frame = CGRectMake(20, safe.top + 12, w - 40, 4);
    [self layoutProgress];
    UIView *close = [self.view viewWithTag:901];
    UIView *share = [self.view viewWithTag:902];
    close.frame = CGRectMake(w - 56, safe.top + 24, 38, 38);
    share.frame = CGRectMake(w - 100, safe.top + 24, 38, 38);
    _cardContainer.frame = CGRectMake(24, safe.top + 72, w - 48, h - safe.top - safe.bottom - 96);
    [self rebuildSlideContent];
}

- (void)showSlide:(NSInteger)index animated:(BOOL)animated {
    _slideIndex = index;
    _slideProgress = 0;
    NSArray<NSArray *> *palettes = @[
        @[(id)[UIColor colorWithRed:0.18 green:0.10 blue:0.42 alpha:1].CGColor, (id)[UIColor colorWithRed:0.05 green:0.05 blue:0.12 alpha:1].CGColor],
        @[(id)[UIColor colorWithRed:0.45 green:0.12 blue:0.28 alpha:1].CGColor, (id)[UIColor colorWithRed:0.08 green:0.04 blue:0.08 alpha:1].CGColor],
        @[(id)[UIColor colorWithRed:0.10 green:0.36 blue:0.32 alpha:1].CGColor, (id)[UIColor colorWithRed:0.04 green:0.09 blue:0.09 alpha:1].CGColor],
        @[(id)[UIColor colorWithRed:0.44 green:0.24 blue:0.08 alpha:1].CGColor, (id)[UIColor colorWithRed:0.09 green:0.06 blue:0.03 alpha:1].CGColor],
        @[(id)[UIColor colorWithRed:0.12 green:0.24 blue:0.48 alpha:1].CGColor, (id)[UIColor colorWithRed:0.04 green:0.07 blue:0.14 alpha:1].CGColor],
        @[(id)[UIColor colorWithRed:0.22 green:0.14 blue:0.38 alpha:1].CGColor, (id)[UIColor colorWithRed:0.05 green:0.04 blue:0.09 alpha:1].CGColor],
    ];
    _bgGradient.colors = palettes[(NSUInteger)(index % palettes.count)];
    [self rebuildSlideContent];
    [self layoutProgress];
}

static UILabel *makeLabel(NSString *text, CGFloat size, UIFontWeight weight, UIColor *color, CGRect frame) {
    UILabel *l = [[UILabel alloc] initWithFrame:frame];
    l.text = text;
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.numberOfLines = 0;
    return l;
}

- (void)rebuildSlideContent {
    for (UIView *sub in _cardContainer.subviews) [sub removeFromSuperview];
    CGFloat w = _cardContainer.bounds.size.width;
    if (w <= 0) return;

    [_cardContainer addSubview:makeLabel(_recap.title.uppercaseString, 13, UIFontWeightBold, [UIColor colorWithWhite:1 alpha:0.65], CGRectMake(0, 0, w, 18))];
    if (_recap.subtitle.length) {
        [_cardContainer addSubview:makeLabel(_recap.subtitle, 15, UIFontWeightMedium, [UIColor colorWithWhite:1 alpha:0.5], CGRectMake(0, 20, w, 20))];
    }

    if (_slideIndex == 0) {
        [_cardContainer addSubview:makeLabel(@"Your Listening Recap", 34, UIFontWeightHeavy, UIColor.whiteColor, CGRectMake(0, 60, w, 84))];
        [_cardContainer addSubview:makeLabel(formatRecapMinutes(_recap.totalMs), 44, UIFontWeightBlack, SGGreen(), CGRectMake(0, 170, w, 54))];
        [_cardContainer addSubview:makeLabel(@"Total listening time", 16, UIFontWeightMedium, [UIColor colorWithWhite:1 alpha:0.7], CGRectMake(0, 226, w, 22))];

        NSString *summary = [NSString stringWithFormat:@"%lu plays  •  %lu songs  •  %lu artists  •  %lu active days",
                             (unsigned long)_recap.plays, (unsigned long)_recap.uniqueTracks,
                             (unsigned long)_recap.uniqueArtists, (unsigned long)_recap.activeDays];
        [_cardContainer addSubview:makeLabel(summary, 16, UIFontWeightSemibold, [UIColor colorWithWhite:1 alpha:0.88], CGRectMake(0, 280, w, 50))];
    } else if (_slideIndex == 1) {
        SGStatEntry *top = _recap.topTracks.firstObject;
        [_cardContainer addSubview:makeLabel(@"Your #1 Song", 28, UIFontWeightBold, [UIColor colorWithWhite:1 alpha:0.8], CGRectMake(0, 60, w, 36))];
        [_cardContainer addSubview:makeLabel(top.name ?: @"No songs yet", 36, UIFontWeightHeavy, UIColor.whiteColor, CGRectMake(0, 120, w, 96))];
        [_cardContainer addSubview:makeLabel(top.detail ?: @"", 22, UIFontWeightSemibold, [UIColor colorWithWhite:1 alpha:0.75], CGRectMake(0, 224, w, 32))];
        if (top) {
            NSString *stat = [NSString stringWithFormat:@"%lu plays  •  %@", (unsigned long)top.plays, formatRecapMinutes(top.ms)];
            [_cardContainer addSubview:makeLabel(stat, 18, UIFontWeightBold, SGGreen(), CGRectMake(0, 272, w, 28))];
        }
    } else if (_slideIndex == 2) {
        [_cardContainer addSubview:makeLabel(@"Top Songs", 30, UIFontWeightHeavy, UIColor.whiteColor, CGRectMake(0, 54, w, 40))];
        CGFloat y = 112;
        NSUInteger count = MIN((NSUInteger)5, _recap.topTracks.count);
        for (NSUInteger i = 0; i < count; i++) {
            SGStatEntry *entry = _recap.topTracks[i];
            [_cardContainer addSubview:makeLabel([NSString stringWithFormat:@"%lu", (unsigned long)i + 1], 22, UIFontWeightBlack, SGGreen(), CGRectMake(0, y, 28, 28))];
            [_cardContainer addSubview:makeLabel(entry.name, 18, UIFontWeightBold, UIColor.whiteColor, CGRectMake(34, y, w - 110, 24))];
            [_cardContainer addSubview:makeLabel(entry.detail ?: @"", 14, UIFontWeightMedium, [UIColor colorWithWhite:1 alpha:0.65], CGRectMake(34, y + 24, w - 110, 18))];
            UILabel *pl = makeLabel([NSString stringWithFormat:@"%lu", (unsigned long)entry.plays], 16, UIFontWeightBold, [UIColor colorWithWhite:1 alpha:0.8], CGRectMake(w - 70, y + 8, 70, 22));
            pl.textAlignment = NSTextAlignmentRight;
            [_cardContainer addSubview:pl];
            y += 58;
        }
    } else if (_slideIndex == 3) {
        [_cardContainer addSubview:makeLabel(@"Top Artists", 30, UIFontWeightHeavy, UIColor.whiteColor, CGRectMake(0, 54, w, 40))];
        CGFloat y = 112;
        NSUInteger count = MIN((NSUInteger)5, _recap.topArtists.count);
        for (NSUInteger i = 0; i < count; i++) {
            SGStatEntry *entry = _recap.topArtists[i];
            [_cardContainer addSubview:makeLabel([NSString stringWithFormat:@"%lu", (unsigned long)i + 1], 22, UIFontWeightBlack, SGGreen(), CGRectMake(0, y, 28, 28))];
            [_cardContainer addSubview:makeLabel(entry.name, 20, UIFontWeightBold, UIColor.whiteColor, CGRectMake(34, y, w - 120, 26))];
            [_cardContainer addSubview:makeLabel(formatRecapMinutes(entry.ms), 14, UIFontWeightMedium, [UIColor colorWithWhite:1 alpha:0.65], CGRectMake(34, y + 26, w - 120, 18))];
            UILabel *pl = makeLabel([NSString stringWithFormat:@"%lu plays", (unsigned long)entry.plays], 15, UIFontWeightSemibold, [UIColor colorWithWhite:1 alpha:0.8], CGRectMake(w - 86, y + 8, 86, 22));
            pl.textAlignment = NSTextAlignmentRight;
            [_cardContainer addSubview:pl];
            y += 58;
        }
    } else if (_slideIndex == 4) {
        [_cardContainer addSubview:makeLabel(@"When You Listen", 30, UIFontWeightHeavy, UIColor.whiteColor, CGRectMake(0, 54, w, 40))];
        NSArray *slots = @[
            @[@"Morning (5am–12pm)", @(_recap.morningPlays)],
            @[@"Afternoon (12pm–5pm)", @(_recap.afternoonPlays)],
            @[@"Evening (5pm–10pm)", @(_recap.eveningPlays)],
            @[@"Late Night (10pm–5am)", @(_recap.nightPlays)],
        ];
        NSUInteger maxSlot = MAX(1u, MAX(MAX(_recap.morningPlays, _recap.afternoonPlays), MAX(_recap.eveningPlays, _recap.nightPlays)));
        CGFloat y = 120;
        for (NSArray *slot in slots) {
            NSString *label = slot[0];
            NSUInteger val = [slot[1] unsignedIntegerValue];
            [_cardContainer addSubview:makeLabel(label, 16, UIFontWeightSemibold, UIColor.whiteColor, CGRectMake(0, y, w - 80, 22))];
            UILabel *cnt = makeLabel([NSString stringWithFormat:@"%lu", (unsigned long)val], 16, UIFontWeightBold, [UIColor colorWithWhite:1 alpha:0.75], CGRectMake(w - 75, y, 75, 22));
            cnt.textAlignment = NSTextAlignmentRight;
            [_cardContainer addSubview:cnt];
            UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, y + 28, MAX(8, (w - 16) * ((CGFloat)val / maxSlot)), 10)];
            bar.backgroundColor = SGGreen();
            bar.layer.cornerRadius = 5;
            [_cardContainer addSubview:bar];
            y += 60;
        }
    } else {
        [_cardContainer addSubview:makeLabel(@"Recap Summary", 28, UIFontWeightHeavy, UIColor.whiteColor, CGRectMake(0, 50, w, 36))];
        [_cardContainer addSubview:makeLabel([NSString stringWithFormat:@"%@  •  %lu plays", formatRecapMinutes(_recap.totalMs), (unsigned long)_recap.plays],
                                             18, UIFontWeightBold, SGGreen(), CGRectMake(0, 90, w, 24))];
        CGFloat colW = (w - 16) / 2.0;
        [_cardContainer addSubview:makeLabel(@"TOP SONGS", 12, UIFontWeightBold, [UIColor colorWithWhite:1 alpha:0.6], CGRectMake(0, 132, colW, 16))];
        [_cardContainer addSubview:makeLabel(@"TOP ARTISTS", 12, UIFontWeightBold, [UIColor colorWithWhite:1 alpha:0.6], CGRectMake(colW + 16, 132, colW, 16))];
        for (NSUInteger i = 0; i < 5; i++) {
            if (i < _recap.topTracks.count) {
                NSString *line = [NSString stringWithFormat:@"%lu. %@", (unsigned long)i + 1, _recap.topTracks[i].name];
                [_cardContainer addSubview:makeLabel(line, 15, UIFontWeightSemibold, UIColor.whiteColor, CGRectMake(0, 156 + i * 34, colW, 28))];
            }
            if (i < _recap.topArtists.count) {
                NSString *line = [NSString stringWithFormat:@"%lu. %@", (unsigned long)i + 1, _recap.topArtists[i].name];
                [_cardContainer addSubview:makeLabel(line, 15, UIFontWeightSemibold, UIColor.whiteColor, CGRectMake(colW + 16, 156 + i * 34, colW, 28))];
            }
        }
    }
}

@end

void SGPolarPresentRecapForRange(NSString *title, NSString *subtitle, int64_t since, int64_t until) {
    SGRecapData *data = buildRecapData(title, subtitle, since, until);
    if (data.plays < 1) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Recap"
                                                                       message:@"No plays recorded in this period yet. Keep listening, or import your Spotify data export on the Listening stats page."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [SGTopController() presentViewController:alert animated:YES completion:nil];
        return;
    }
    SGRecapStoryController *story = [[SGRecapStoryController alloc] initWithRecap:data];
    [SGTopController() presentViewController:story animated:YES completion:nil];
}

UIViewController *SGAllRecapsPage(void) {
    int64_t now = (int64_t)time(NULL);
    int64_t kDay = 86400;
    NSArray<SGModRow *> *quick = @[
        SGWithSymbol(SGActionRow(@"Weekly Recap", @"Your past 7 days as an interactive story", ^{
            SGPolarPresentRecapForRange(@"Weekly Recap", @"Past 7 days", now - 7 * kDay, 0);
        }), @"calendar"),
        SGWithSymbol(SGActionRow(@"Monthly Recap", @"Your past 30 days as an interactive story", ^{
            SGPolarPresentRecapForRange(@"Monthly Recap", @"Past 30 days", now - 30 * kDay, 0);
        }), @"calendar.badge.clock"),
        SGWithSymbol(SGActionRow(@"Yearly Recap", @"Your past 365 days as an interactive story", ^{
            SGPolarPresentRecapForRange(@"Yearly Recap", @"Past 365 days", now - 365 * kDay, 0);
        }), @"sparkles"),
        SGWithSymbol(SGActionRow(@"All-Time Recap", @"Every play in your listening history", ^{
            SGPolarPresentRecapForRange(@"All-Time Recap", @"All recorded history", 0, 0);
        }), @"infinity"),
    ];
    return [[SGModPage alloc] initWithTitle:@"All recaps"
                                      intro:@"Weekly, monthly, yearly and all-time recaps are all unlocked and generated locally on your phone."
                                   sections:@[SGSection(@"Stories", quick)]
                                     footer:nil];
}
