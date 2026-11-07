// Web Jam's two pages: the guest page served over Wi-Fi and the Mod Settings page
// that starts the listener, shows its address and draws the QR code.
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "LocalJam.h"
#import "WebJam.h"

#pragma mark - Mod Settings

// CIQRCodeGenerator draws black on transparent; a false-colour pass puts it on
// white so it scans in a dark page, and 16× keeps the modules crisp.
static UIImage *WebJamQRCode(NSString *text) {
    CIFilter *generator = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    if (!generator || !text.length) return nil;
    [generator setValue:[text dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [generator setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *code = generator.outputImage;
    if (!code) return nil;
    CIFilter *paper = [CIFilter filterWithName:@"CIFalseColor"];
    if (paper) {
        [paper setValue:code forKey:@"inputImage"];
        [paper setValue:[CIColor colorWithRed:0 green:0 blue:0] forKey:@"inputColor0"];
        [paper setValue:[CIColor colorWithRed:1 green:1 blue:1] forKey:@"inputColor1"];
        code = paper.outputImage ?: code;
    }
    code = [code imageByApplyingTransform:CGAffineTransformMakeScale(16, 16)];
    static CIContext *context;
    if (!context) context = [CIContext contextWithOptions:nil];
    CGImageRef cg = [context createCGImage:code fromRect:code.extent];
    if (!cg) return nil;
    UIImage *image = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return image;
}

@interface SGWebJamCodeHeader : UIView
@end

@implementation SGWebJamCodeHeader {
    UIView *_card;
    UIImageView *_code;
    UILabel *_link;
}

- (instancetype)initWithURL:(NSString *)url {
    if (!(self = [super initWithFrame:CGRectMake(0, 0, 320, 262)])) return nil;
    self.backgroundColor = UIColor.clearColor;
    _card = [UIView new];
    _card.backgroundColor = UIColor.whiteColor;
    _card.layer.cornerRadius = 18;
    _card.layer.masksToBounds = YES;
    [self addSubview:_card];
    _code = [[UIImageView alloc] initWithImage:WebJamQRCode(url)];
    _code.contentMode = UIViewContentModeScaleAspectFit;
    _code.layer.magnificationFilter = kCAFilterNearest;
    _code.isAccessibilityElement = YES;
    _code.accessibilityLabel = [NSString stringWithFormat:@"QR code for %@", url];
    [_card addSubview:_code];
    _link = [UILabel new];
    _link.text = url;
    _link.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
    _link.textColor = SGGrey();
    _link.textAlignment = NSTextAlignmentCenter;
    _link.adjustsFontSizeToFitWidth = YES;
    _link.minimumScaleFactor = 0.7;
    _link.numberOfLines = 1;
    [self addSubview:_link];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    CGFloat side = MIN(210, MAX(120, width - 96));
    _card.frame = CGRectMake((width - side) / 2, 10, side, side);
    _code.frame = CGRectInset(_card.bounds, 14, 14);
    _link.frame = CGRectMake(20, CGRectGetMaxY(_card.frame) + 10, width - 40, 18);
}

@end

@interface SGWebJamSettingsPage : SGModPage
@end

@implementation SGWebJamSettingsPage {
    NSString *_shownURL;
    NSTimer *_addressTimer;
}

- (instancetype)init {
    SGModRow *toggle = SGOptionRow(@"Web Jam",
        @"Serve a page on this Wi-Fi while Spotify is open; the switch starts and stops it now",
        SGKeyWebJam);
    SGModRow *status = SGStatRow(@"Status", ^NSString *{ return SGWebJamStatus(); });
    status.refreshOn = SGWebJamDidChangeNotification;
    SGModRow *address = SGStatRow(@"Join at", ^NSString *{
        return SGWebJamJoinURL() ?: (SGWebJamEnabled() ? @"Waiting for Wi-Fi and the listener" : @"Turn on Web Jam first");
    });
    address.refreshOn = SGWebJamDidChangeNotification;
    SGModRow *queue = SGStatRow(@"Queue", ^NSString *{
        NSUInteger count = SGLocalJamHubShared().queue.count;
        if (!count) return @"Empty";
        return [NSString stringWithFormat:@"%lu %@", (unsigned long)count,
            count == 1 ? @"request" : @"requests"];
    });
    queue.refreshOn = SGLocalJamDidChangeNotification;
    SGModRow *copy = SGWithSymbol(SGActionRow(@"Copy link", nil, ^{
        NSString *link = SGWebJamJoinURL();
        if (link) UIPasteboard.generalPasteboard.string = link;
    }), @"link");
    SGModRow *share = SGWithSymbol(SGActionRow(@"Share link", @"For guests on this Wi-Fi", ^{
        NSString *link = SGWebJamJoinURL();
        UIViewController *top = SGTopController();
        if (!link || !top) return;
        UIActivityViewController *sheet = [[UIActivityViewController alloc]
            initWithActivityItems:@[[NSURL URLWithString:link]] applicationActivities:nil];
        sheet.popoverPresentationController.sourceView = top.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 1, 1);
        [top presentViewController:sheet animated:YES completion:nil];
    }), @"square.and.arrow.up");
    SGModRow *open = SGWithSymbol(SGActionRow(@"Open in browser", nil, ^{
        NSString *link = SGWebJamJoinURL();
        if (link) SGOpenURL(link);
    }), @"safari");
    for (SGModRow *row in @[copy, share, open]) row.visible = ^BOOL { return SGWebJamJoinURL() != nil; };
    if (!(self = [super initWithTitle:@"Web Jam" intro:nil sections:@[
        SGNotedSection(@"Guests", @[toggle],
            @"Guests can listen and request songs or playlists in a browser on this Wi-Fi. The switch starts Local Jam "
            @"hosting on this iPhone so their requests reach the party queue."),
        SGNotedSection(@"Address", @[status, address, copy, share, open, queue],
            @"Scan the code or open the address in any browser on this Wi-Fi. Requests are added "
            @"with a guest name and play as the current song ends. Playlist requests start that playlist; later requests take priority at a song boundary."),
    ] footer:@"Anyone on this Wi-Fi with the address can listen to this iPhone’s audio, see the room and request songs or playlists; no guest account is needed. "
              @"Song titles and covers load from Spotify over the internet. Guests tap Start listening and hear a short delay. Play on this iPhone and keep Spotify and the guest tab open. Audio is kept only in a short memory buffer. "
              @"Turning Web Jam off closes the listener and ends hosting it started; an existing Local Jam stays running."])) return nil;

    toggle.changed = ^(BOOL on) { SGWebJamSetEnabled(on); };
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(listenerChanged)
        name:SGWebJamDidChangeNotification object:nil];
    __weak SGWebJamSettingsPage *weakSelf = self;
    [_addressTimer invalidate];
    _addressTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        [weakSelf updateCode];
    }];
    [self updateCode];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [_addressTimer invalidate];
    _addressTimer = nil;
    [NSNotificationCenter.defaultCenter removeObserver:self name:SGWebJamDidChangeNotification object:nil];
}

- (void)listenerChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateCode];
        [self refreshVisibility];
    });
}

- (void)updateCode {
    NSString *url = SGWebJamJoinURL();
    if (url == _shownURL || [url isEqualToString:_shownURL]) return;
    _shownURL = [url copy];
    if (!url) { self.tableView.tableHeaderView = nil; return; }
    SGWebJamCodeHeader *header = [[SGWebJamCodeHeader alloc] initWithURL:url];
    header.frame = CGRectMake(0, 0, self.tableView.bounds.size.width, 262);
    self.tableView.tableHeaderView = header;
}

@end

UIViewController *SGWebJamPage(void) {
    return [SGWebJamSettingsPage new];
}
