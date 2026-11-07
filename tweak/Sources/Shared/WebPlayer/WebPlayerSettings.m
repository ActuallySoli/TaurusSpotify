#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "Settings/SGModPage.h"
#import "Shared/Jam/WebJam.h"
#import "WebPlayer.h"

// The same QR card as Web Jam's page (Shared/Jam/WebJamPage.m), kept as this page's own copy: black
// modules on a white card so it scans on the dark page, scaled 16x with nearest filtering to stay crisp.
static UIImage *WebPlayerQRCode(NSString *text) {
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

@interface SGWebPlayerCodeHeader : UIView
- (instancetype)initWithURL:(NSString *)url;
@end

@implementation SGWebPlayerCodeHeader {
    UIView *_card;
    UIImageView *_code;
    UILabel *_hint;
}

- (instancetype)initWithURL:(NSString *)url {
    if (!(self = [super initWithFrame:CGRectMake(0, 0, 320, 262)])) return nil;
    self.backgroundColor = UIColor.clearColor;
    _card = [UIView new];
    _card.backgroundColor = UIColor.whiteColor;
    _card.layer.cornerRadius = 18;
    _card.layer.masksToBounds = YES;
    [self addSubview:_card];
    _code = [[UIImageView alloc] initWithImage:WebPlayerQRCode(url)];
    _code.contentMode = UIViewContentModeScaleAspectFit;
    _code.layer.magnificationFilter = kCAFilterNearest;
    _code.isAccessibilityElement = YES;
    _code.accessibilityLabel = @"QR code for the Browser player link";
    [_card addSubview:_code];
    // The link carries the session key, so the label names the action rather than printing it.
    _hint = [UILabel new];
    _hint.text = @"Scan on a device on this Wi-Fi";
    _hint.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _hint.textColor = SGGrey();
    _hint.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_hint];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    CGFloat side = MIN(210, MAX(120, width - 96));
    _card.frame = CGRectMake((width - side) / 2, 10, side, side);
    _code.frame = CGRectInset(_card.bounds, 14, 14);
    _hint.frame = CGRectMake(20, CGRectGetMaxY(_card.frame) + 10, width - 40, 18);
}

@end

// The QR card follows the listener: it appears with a link and leaves when Stop revokes it.
@interface SGWebPlayerSettingsController : SGModPage
@end

@implementation SGWebPlayerSettingsController {
    NSString *_shownLink;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(listenerChanged)
        name:SGWebPlayerDidChangeNotification object:nil];
    _shownLink = nil;
    [self updateCode];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [NSNotificationCenter.defaultCenter removeObserver:self name:SGWebPlayerDidChangeNotification object:nil];
}

- (void)listenerChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateCode];
        [self refreshVisibility];
    });
}

- (void)updateCode {
    NSString *link = SGWebPlayerLink();
    if (link == _shownLink || [link isEqualToString:_shownLink]) return;
    _shownLink = [link copy];
    if (!link) { self.tableView.tableHeaderView = nil; return; }
    SGWebPlayerCodeHeader *header = [[SGWebPlayerCodeHeader alloc] initWithURL:link];
    header.frame = CGRectMake(0, 0, self.tableView.bounds.size.width, 262);
    self.tableView.tableHeaderView = header;
}

@end

static UIViewController *SGWebPlayerSettings(void) {
    SGModRow *listener = SGWithSymbol(SGStatActionRow(@"Listener",
        @"Starts the local network mirror · tap again to stop it",
        ^NSString * { return SGWebPlayerStatus(); },
        ^{ if (SGWebPlayerRunning()) SGWebPlayerStop(); else SGWebPlayerStart(); }), @"safari");
    listener.info = @"Turns the listener on for this session only: closing Spotify or restarting it takes it down, and the link is new each time.";
    listener.refreshOn = SGWebPlayerDidChangeNotification;

    SGModRow *copy = SGWithSymbol(SGActionRow(@"Copy link",
        @"The link carries the key · same Wi-Fi only", ^{
            NSString *link = SGWebPlayerLink();
            if (link) UIPasteboard.generalPasteboard.string = link;
        }), @"link");
    copy.visible = ^BOOL { return SGWebPlayerLink() != nil; };

    SGModRow *open = SGWithSymbol(SGActionRow(@"Open in browser",
        @"Opens the link on this iPhone", ^{
            NSString *link = SGWebPlayerLink();
            if (link) SGOpenURL(link);
        }), @"arrow.up.forward.app");
    open.visible = ^BOOL { return SGWebPlayerLink() != nil; };

    SGModRow *share = SGWithSymbol(SGActionRow(@"Share link", @"Only share with people you trust on this Wi-Fi", ^{
        NSString *link = SGWebPlayerLink();
        UIViewController *top = SGTopController();
        if (!link || !top) return;
        UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL URLWithString:link]] applicationActivities:nil];
        sheet.popoverPresentationController.sourceView = top.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 1, 1);
        [top presentViewController:sheet animated:YES completion:nil];
    }), @"square.and.arrow.up");
    share.visible = ^BOOL { return SGWebPlayerLink() != nil; };

    SGModRow *motion = SGWithSymbol(SGOptionRow(@"Moving artwork", @"Canvas or animated album cover · off by default", SGKeyWebPlayerMotion), @"photo.on.rectangle.angled");
    motion.info = @"Uses your artwork source order once per song, while this mirror is running. Cached clips up to 16 MiB are copied to the browser over this Wi-Fi. Larger or unsupported clips fall back to the static cover. No sound plays in the browser.";

    SGModRow *controls = SGWithSymbol(SGOptionRow(@"Browser controls",
        @"Pause, play and skip from the browser tab · off by default", SGKeyWebPlayerControls),
        @"slider.horizontal.3");
    controls.info = @"The tab only ever offers controls while this is on, and the iPhone refuses any control call even if a page's buttons are forced on.";

    // Guests who want to add songs rather than watch are after Web Jam, which has its own QR page.
    SGModRow *webJam = SGWithSymbol(SGPageRow(@"Web Jam", ^UIViewController *{ return SGWebJamPage(); }), @"globe");
    webJam.subtitle = @"Let guests add songs to your queue from their browser";

    return [[SGWebPlayerSettingsController alloc] initWithTitle:@"Browser player" intro:nil sections:@[
        SGNotedSection(@"Mirror", @[listener, copy, share, open],
            @"Open the link in a browser on a device of the same Wi-Fi. The sound keeps playing on this iPhone; the browser shows the track, artwork and lyrics as they are sung."),
        SGSection(@"Artwork", @[motion]),
        SGSection(@"Controls", @[controls]),
        SGSection(@"Party queue", @[webJam]),
    ] footer:@"Your track, lyrics, upcoming queue and enabled motion clips travel over local HTTP. Cover images load directly from Spotify’s public image CDN without account credentials. Anyone with the link can view them; enable browser controls only on a trusted Wi-Fi network. Keep Spotify open. Each launch starts with the listener off; Stop revokes the link."];
}

UIViewController *SGWebPlayerSettingsPage(void) {
    return SGWebPlayerSettings();
}
