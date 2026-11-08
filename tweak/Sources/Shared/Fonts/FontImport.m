// A font family of the user's own for Fonts.x: the .ttf, .otf, .ttc or .otc files of one family picked together in
// Files are copied into Application Support, registered with Core Text for this process and named by the
// family name read from them. Like every other font choice it takes over when Spotify starts again, and
// Fonts.x registers the files again on each launch.
#import <CoreText/CoreText.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Fonts/Fonts.h"
#import "Shared/Fonts/FontCatalog.h"

static NSURL *fontFolder(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [[support URLByAppendingPathComponent:@"spoti.pw" isDirectory:YES] URLByAppendingPathComponent:@"Fonts" isDirectory:YES];
}

// The family name of every face in the file, "" for a face without one; empty when Core Text finds no font. A
// collection gives one per face.
static NSArray<NSString *> *familiesIn(NSURL *url) {
    NSArray *faces = CFBridgingRelease(CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url));
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id face in faces) {
        NSString *name = CFBridgingRelease(CTFontDescriptorCopyAttribute((__bridge CTFontDescriptorRef)face, kCTFontFamilyNameAttribute));
        [names addObject:name ?: @""];
    }
    return names;
}

// The one family name all the faces share, or nil when they differ, one has none, or there are no faces.
NSString *SGFontSingleFamily(NSArray<NSString *> *names) {
    NSSet<NSString *> *distinct = [NSSet setWithArray:names];
    return distinct.count == 1 && distinct.anyObject.length ? distinct.anyObject : nil;
}

// An import from before families is one file under SGKeyAppFontFile and a PostScript name under
// SGKeyAppFontName. It becomes a list of one file and its family name, on first use after the update.
static void migrate(void) {
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    NSString *file = [store stringForKey:SGKeyAppFontFile];
    if (!file.length) return;
    NSString *family = familiesIn([fontFolder() URLByAppendingPathComponent:file.lastPathComponent]).firstObject;
    if (family.length) {
        [store setObject:@[file] forKey:SGKeyAppFontFiles];
        [store setObject:family forKey:SGKeyAppFontName];
    }
    [store removeObjectForKey:SGKeyAppFontFile];
}

// The imported files still in the folder.
static NSArray<NSURL *> *storedFiles(void) {
    migrate();
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *file in [NSUserDefaults.standardUserDefaults arrayForKey:SGKeyAppFontFiles]) {
        NSURL *url = [fontFolder() URLByAppendingPathComponent:file.lastPathComponent];
        if ([NSFileManager.defaultManager fileExistsAtPath:url.path]) [urls addObject:url];
    }
    return urls;
}

static NSString *importedFamily(void) {
    return storedFiles().count ? [NSUserDefaults.standardUserDefaults stringForKey:SGKeyAppFontName] : nil;
}

// A face iOS already carries under the same name (Chalkduster, say) is refused as a duplicate and is there
// all the same, so what counts is whether the family has faces afterward. Files that are gone are skipped.
NSString *SGRegisterCustomFont(void) {
    NSString *family = importedFamily();
    for (NSURL *url in storedFiles()) {
        CFErrorRef error = NULL;
        if (!CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &error)) {
            NSError *failure = CFBridgingRelease(error);
            SGLog(@"fonts: %@ not registered: %@", url.lastPathComponent, failure.localizedDescription);
        }
    }
    return family && [UIFont fontNamesForFamilyName:family].count ? family : nil;
}

// The imported files unregistered and deleted, and the choice forgotten.
static void removeImported(void) {
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    for (NSURL *url in storedFiles()) {
        CTFontManagerUnregisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, NULL);
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    }
    NSString *license = [store dictionaryForKey:SGKeyAppFontCatalog][@"licenseFile"];
    if (license.length) [NSFileManager.defaultManager removeItemAtURL:[fontFolder() URLByAppendingPathComponent:license.lastPathComponent] error:nil];
    for (NSString *key in @[SGKeyAppFontFiles, SGKeyAppFontName, SGKeyAppFontCatalog]) [store removeObjectForKey:key];
    if (SGAppFontChosen() == SGAppFontCustom) SGSetInt(SGKeyAppFont, SGAppFontSpotify);
}

static void tell(NSString *title, NSString *message, BOOL restart) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    if (restart) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Restart now" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { SGRestartSpotify(); }]];
    } else {
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    }
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

// The files are checked and copied aside before the ones in use are touched, so files Core Text will not read,
// of more than one family, or that fail to copy change nothing.
NSString *SGImportFontFiles(NSArray<NSURL *> *picked, BOOL lyricsOnly, NSDictionary *catalogMetadata, NSError **error) {
    NSMutableArray<NSURL *> *scoped = [NSMutableArray array];
    NSMutableArray<NSString *> *families = [NSMutableArray array];
    BOOL fonts = picked.count > 0;
    for (NSURL *url in picked) {
        if ([url startAccessingSecurityScopedResource]) [scoped addObject:url];
        NSArray<NSString *> *names = familiesIn(url);
        fonts = fonts && names.count;
        [families addObjectsFromArray:names];
    }
    NSString *family = fonts ? SGFontSingleFamily(families) : nil;
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *failure = !fonts ? @"Choose valid .ttf, .otf, .ttc or .otc font files."
        : !family ? @"These files are more than one family. Pick the files of one family together." : nil;
    if (catalogMetadata && ![family isEqualToString:catalogMetadata[@"family"]]) failure = @"The downloaded file is not the expected font family.";
    NSString *prefix = NSUUID.UUID.UUIDString;
    NSMutableArray<NSURL *> *copied = [NSMutableArray array], *registered = [NSMutableArray array];
    NSURL *licenseURL = nil;
    if (!failure && ![files createDirectoryAtURL:fontFolder() withIntermediateDirectories:YES attributes:nil error:nil]) failure = @"The font folder could not be created.";
    if (!failure) {
        for (NSURL *url in picked) {
            NSURL *target = [fontFolder() URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%lu-%@", prefix, (unsigned long)copied.count, url.lastPathComponent]];
            [copied addObject:target];
            if (![files copyItemAtURL:url toURL:target error:nil]) { failure = @"The font could not be copied. Your current font was kept."; break; }
        }
    }
    for (NSURL *url in scoped) [url stopAccessingSecurityScopedResource];
    if (!failure) {
        NSMutableArray<NSString *> *copiedFamilies = [NSMutableArray array];
        for (NSURL *url in copied) {
            NSArray<NSString *> *names = familiesIn(url);
            if (!names.count) { failure = @"The copied file is not a valid font. Your current font was kept."; break; }
            [copiedFamilies addObjectsFromArray:names];
        }
        if (!failure && ![family isEqualToString:SGFontSingleFamily(copiedFamilies)]) failure = @"The font changed while it was being imported. Your current font was kept.";
    }
    if (!failure && catalogMetadata) {
        licenseURL = [fontFolder() URLByAppendingPathComponent:[prefix stringByAppendingString:@"-OFL.txt"]];
        if (![catalogMetadata[@"licenseText"] writeToURL:licenseURL atomically:YES encoding:NSUTF8StringEncoding error:nil]) failure = @"The font license could not be saved. Your current font was kept.";
    }
    if (!failure) {
        for (NSURL *url in copied) {
            CFErrorRef fontError = NULL;
            if (CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &fontError)) [registered addObject:url];
            else {
                NSError *registrationError = CFBridgingRelease(fontError);
                BOOL duplicate = [registrationError.domain isEqualToString:(__bridge NSString *)kCTFontManagerErrorDomain]
                    && (registrationError.code == kCTFontManagerErrorAlreadyRegistered || registrationError.code == kCTFontManagerErrorDuplicatedName);
                if (!duplicate) { failure = @"Core Text could not register this font. Your current font was kept."; break; }
            }
        }
        if (!failure && ![UIFont fontNamesForFamilyName:family].count) failure = @"The font has no usable styles. Your current font was kept.";
    }
    if (failure) {
        for (NSURL *url in registered) CTFontManagerUnregisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, NULL);
        for (NSURL *url in copied) [files removeItemAtURL:url error:nil];
        if (licenseURL) [files removeItemAtURL:licenseURL error:nil];
        if (error) *error = [NSError errorWithDomain:@"spoti.pw.fonts" code:2 userInfo:@{NSLocalizedDescriptionKey: failure}];
        return nil;
    }
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    NSArray<NSURL *> *previousFiles = storedFiles();
    NSString *previousLicense = [store dictionaryForKey:SGKeyAppFontCatalog][@"licenseFile"];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSURL *url in copied) [names addObject:url.lastPathComponent];
    [store setObject:names forKey:SGKeyAppFontFiles];
    [store setObject:family forKey:SGKeyAppFontName];
    if (catalogMetadata) {
        NSMutableDictionary *metadata = [catalogMetadata mutableCopy];
        metadata[@"licenseFile"] = licenseURL.lastPathComponent;
        [store setObject:metadata forKey:SGKeyAppFontCatalog];
    } else [store removeObjectForKey:SGKeyAppFontCatalog];
    if (!lyricsOnly) SGSetInt(SGKeyAppFont, SGAppFontCustom);
    for (NSURL *url in previousFiles) [files removeItemAtURL:url error:nil];
    if (previousLicense.length) [files removeItemAtURL:[fontFolder() URLByAppendingPathComponent:previousLicense.lastPathComponent] error:nil];
    return family;
}

static void importPicked(NSArray<NSURL *> *picked, BOOL lyricsOnly) {
    NSError *error = nil;
    NSString *family = SGImportFontFiles(picked, lyricsOnly, nil, &error);
    if (family) {
        if (lyricsOnly) tell(@"Font imported", [NSString stringWithFormat:@"%@ is in the lyrics' Font list.", family], NO);
        else tell(@"Font imported", [NSString stringWithFormat:@"%@ becomes the app's font when Spotify starts again.", family], YES);
    } else {
        tell(@"Font not imported", error.localizedDescription, NO);
    }
}

@interface SGFontPicker : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, copy) void (^done)(void);   // the page's refresh, once the files are in or refused
@property (nonatomic) BOOL lyricsOnly;
@end

@implementation SGFontPicker

- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    // The alert waits for the picker to be gone, or it has nothing to present over.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (urls.count) importPicked(urls, self.lyricsOnly);
        if (self.done) self.done();
    });
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)picker {
    if (self.done) self.done();
}

@end

static void pickFont(BOOL lyricsOnly, void (^done)(void)) {
    static char delegateKey;
    SGFontPicker *delegate = [SGFontPicker new];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFont] asCopy:YES];
    delegate.lyricsOnly = lyricsOnly;
    delegate.done = done;
    objc_setAssociatedObject(picker, &delegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    picker.delegate = delegate;
    picker.allowsMultipleSelection = YES;
    [SGTopController() presentViewController:picker animated:YES completion:nil];
}

// The Lyrics page's Import: the same picker and checks, without making the font the app's.
void SGPickFontForLyrics(void (^done)(void)) {
    pickFont(YES, done);
}

#pragma mark - the page

// Each choice is drawn in its own font. Core Text makes it, so the font chosen now (Fonts.x hooks UIFont) does
// not dress every row in itself.
static UIFont *previewFont(NSString *nameOrFamily, BOOL family, CGFloat size) {
    CTFontRef font = NULL;
    if (family) {
        CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)@{(id)kCTFontFamilyNameAttribute: nameOrFamily});
        font = CTFontCreateWithFontDescriptor(descriptor, size, NULL);
        CFRelease(descriptor);
    } else if (nameOrFamily) {
        font = CTFontCreateWithName((__bridge CFStringRef)nameOrFamily, size, NULL);
    }
    return font ? (__bridge_transfer UIFont *)font : nil;
}

static UIFont *builtInFont(SGAppFont choice, CGFloat size) {
    if (choice == SGAppFontSpotify) return previewFont(@"SpotifyMixUI-Regular", NO, size);
    UIFontDescriptor *system = ((__bridge_transfer UIFont *)CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, NULL)).fontDescriptor;
    UIFontDescriptorSystemDesign design = choice == SGAppFontRounded ? UIFontDescriptorSystemDesignRounded
        : choice == SGAppFontSerif ? UIFontDescriptorSystemDesignSerif
        : choice == SGAppFontMono ? UIFontDescriptorSystemDesignMonospaced : UIFontDescriptorSystemDesignDefault;
    UIFontDescriptor *descriptor = [system fontDescriptorWithDesign:design] ?: system;
    return (__bridge_transfer UIFont *)CTFontCreateWithFontDescriptor((__bridge CTFontDescriptorRef)descriptor, size, NULL);
}

static NSString *chosenLabel(void) {
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    SGAppFont font = SGAppFontChosen();
    if (font == SGAppFontCustom) return importedFamily() ?: @"Your font";
    if (font == SGAppFontFamily) return [store stringForKey:SGKeyAppFontFamily] ?: SGAppFontNames()[0];
    return SGAppFontNames()[font];
}

typedef NS_ENUM(NSInteger, SGFontSection) { SGFontBuiltIn, SGFontMore, SGFontCatalog, SGFontYours };

@interface SGFontLicensePage : SGPage
@property (nonatomic, copy) NSString *licenseText;
@end

@implementation SGFontLicensePage
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Font license";
    self.tableView.tableHeaderView = SGNote(self.licenseText);
}
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    SGFitNote(self.tableView, self.tableView.tableHeaderView, 8, 24);
}
@end

@interface SGFontPage : SGPage
@end

@implementation SGFontPage {
    NSArray<NSString *> *_families;
    UIView *_footer;
    SGFontCatalogEntry *_downloading;
}

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"Font";
    _families = SGAppFontFamilies();
    SGRegisterCustomFont();   // so the imported family can be drawn here, whichever font is chosen
    return self;
}

// A one-face import says why bold comes out regular; otherwise the note says how to bring the bold along.
- (void)refreshFooter {
    BOOL variable = [[NSUserDefaults.standardUserDefaults dictionaryForKey:SGKeyAppFontCatalog][@"variable"] boolValue];
    NSString *own = variable ? @"This imported font has variable weights: one file can include regular and bold. " : self.styleCount == 1
        ? @"A font of your own is a .ttf or .otf file from Files. This one has a single style, so bold text comes out regular. Pick all the files of a family together to keep bold. "
        : @"A font of your own comes from Files: a .ttf or .otf file, or all the files of one family picked together, so bold and italic stay. ";
    _footer = SGNote([own stringByAppendingString:@"Curated fonts download only when you choose Download and use, replacing your imported family. Each includes its SIL Open Font License. Text Spotify draws itself may keep its own font. Changes apply after you restart Spotify."]);
    self.tableView.tableFooterView = _footer;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self refreshFooter];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    SGFitNote(self.tableView, _footer, 8, 24);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
}

- (void)refresh {
    [self refreshFooter];
    [self.tableView reloadData];
}

// The imported family, while there is one, then the row that adds one.
- (NSString *)importedName {
    return importedFamily();
}

// How many faces the imported family has on this iPhone.
- (NSUInteger)styleCount {
    NSString *name = self.importedName;
    return name ? [UIFont fontNamesForFamilyName:name].count : 0;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {
    return 4;
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    if (section == SGFontBuiltIn) return (NSInteger)SGAppFontNames().count;
    if (section == SGFontMore) return (NSInteger)_families.count;
    if (section == SGFontCatalog) return (NSInteger)SGFontCatalogEntries().count;
    return self.importedName.length ? 2 : 1;
}

- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section {
    return section == SGFontBuiltIn ? nil : SGSectionHeader(table, section == SGFontMore ? @"More fonts" : section == SGFontCatalog ? @"Curated fonts" : @"Your fonts");
}

- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    return section == SGFontBuiltIn ? SGSectionGap : UITableViewAutomaticDimension;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(table, @"font");
    cell.userInteractionEnabled = !_downloading;
    cell.contentView.alpha = _downloading ? 0.45 : 1;
    cell.accessoryType = UITableViewCellAccessoryNone;
    UIAccessibilityTraits disabled = _downloading ? UIAccessibilityTraitNotEnabled : 0;
    CGFloat size = SGTitleFont().pointSize;
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    SGAppFont chosen = SGAppFontChosen();
    if (path.section == SGFontCatalog) {
        SGFontCatalogEntry *entry = SGFontCatalogEntries()[(NSUInteger)path.row];
        NSDictionary *metadata = [store dictionaryForKey:SGKeyAppFontCatalog];
        BOOL installed = [metadata[@"sha256"] isEqualToString:entry.sha256] && [self.importedName isEqualToString:entry.family];
        NSString *detail = entry == _downloading ? @"Downloading and verifying…"
            : [NSString stringWithFormat:@"%@ · %@ · %@", entry.detail,
               [NSByteCountFormatter stringFromByteCount:(int64_t)entry.byteCount countStyle:NSByteCountFormatterCountStyleFile], installed ? @"Imported" : @"Download"];
        SGFillCell(cell, entry.family, detail, nil, nil);
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (entry == _downloading) {
            cell.contentView.alpha = 1;
            cell.accessoryType = UITableViewCellAccessoryNone;
            UIActivityIndicatorView *progress = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            progress.color = SGGreen();
            progress.isAccessibilityElement = NO;
            [progress startAnimating];
            cell.accessoryView = progress;
        }
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessibilityTraits = UIAccessibilityTraitButton | disabled;
        return cell;
    }
    NSString *title, *subtitle = nil;
    UIFont *font;
    BOOL selected;
    if (path.section == SGFontBuiltIn) {
        title = SGAppFontNames()[(NSUInteger)path.row];
        font = builtInFont(path.row, size);
        selected = chosen == path.row;
    } else if (path.section == SGFontMore) {
        title = _families[(NSUInteger)path.row];
        font = previewFont(title, YES, size);
        selected = chosen == SGAppFontFamily && [title isEqualToString:[store stringForKey:SGKeyAppFontFamily]];
    } else if (path.row == 0 && self.importedName.length) {
        title = self.importedName;
        font = previewFont(title, YES, size);
        selected = chosen == SGAppFontCustom;
        subtitle = [[store dictionaryForKey:SGKeyAppFontCatalog][@"variable"] boolValue] ? @"Variable weights"
            : [NSString stringWithFormat:@"%lu style%@", (unsigned long)self.styleCount, self.styleCount == 1 ? @"" : @"s"];
    } else {
        SGFillCell(cell, @"Add a font file", nil, SGGreen(), nil);
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessibilityTraits = UIAccessibilityTraitButton | disabled;
        return cell;
    }
    SGFillCell(cell, title, subtitle, nil, nil);
    UIListContentConfiguration *content = (UIListContentConfiguration *)cell.contentConfiguration;
    if (font) content.textProperties.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:font maximumPointSize:18];
    cell.contentConfiguration = content;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    if (selected) {
        UIImageView *tick = SGSymbolView(@"checkmark", 13, UIImageSymbolWeightSemibold, 16);
        tick.tintColor = SGGreen();
        cell.accessoryView = tick;
    }
    cell.accessibilityTraits = (selected ? UIAccessibilityTraitButton | UIAccessibilityTraitSelected : UIAccessibilityTraitButton) | disabled;
    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (_downloading) return;
    if (path.section == SGFontBuiltIn) {
        SGSetInt(SGKeyAppFont, path.row);
    } else if (path.section == SGFontMore) {
        [NSUserDefaults.standardUserDefaults setObject:_families[(NSUInteger)path.row] forKey:SGKeyAppFontFamily];
        SGSetInt(SGKeyAppFont, SGAppFontFamily);
    } else if (path.section == SGFontCatalog) {
        [self showCatalogEntry:SGFontCatalogEntries()[(NSUInteger)path.row] at:path];
        return;
    } else if (path.row == 0 && self.importedName.length) {
        SGSetInt(SGKeyAppFont, SGAppFontCustom);
    } else {
        __weak SGFontPage *page = self;
        pickFont(NO, ^{ [page refresh]; });
        return;
    }
    [table reloadData];
}

- (void)showCatalogEntry:(SGFontCatalogEntry *)entry at:(NSIndexPath *)path {
    NSString *message = [NSString stringWithFormat:@"%@ · %@\nSIL Open Font License 1.1\nReplaces your imported font. Restart Spotify to apply it.", entry.detail,
        [NSByteCountFormatter stringFromByteCount:(int64_t)entry.byteCount countStyle:NSByteCountFormatterCountStyleFile]];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:entry.family message:message preferredStyle:UIAlertControllerStyleActionSheet];
    __weak SGFontPage *weakPage = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Download and use" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        SGFontPage *page = weakPage;
        if (!page || page->_downloading) return;
        page->_downloading = entry;
        [page refresh];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, [NSString stringWithFormat:@"Downloading %@.", entry.family]);
        SGDownloadCatalogFont(entry, ^(NSURL *file, NSError *error) {
            SGFontPage *current = weakPage;
            NSString *family = nil;
            if (file && current) family = SGImportFontFiles(@[file], NO, entry.metadata, &error);
            if (file) [NSFileManager.defaultManager removeItemAtURL:file.URLByDeletingLastPathComponent error:nil];
            if (!current) return;
            current->_downloading = nil;
            [current refresh];
            if (family) tell(@"Font imported", [NSString stringWithFormat:@"%@ becomes the app's font when Spotify starts again.", family], YES);
            else tell(@"Font not imported", [NSString stringWithFormat:@"%@\nChoose the font again to retry.", error.localizedDescription ?: @"Your current font was kept."], NO);
        });
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"View source on Google Fonts" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { SGOpenURL(entry.sourceURL.absoluteString); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Read license" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        SGFontLicensePage *license = [SGFontLicensePage new];
        license.licenseText = entry.licenseText;
        SGShowPage(weakPage, license);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Open license source" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { SGOpenURL(entry.licenseURL.absoluteString); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
    sheet.popoverPresentationController.sourceView = cell ?: self.tableView;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : [self.tableView rectForRowAtIndexPath:path];
    [self presentViewController:sheet animated:YES completion:nil];
}

// Swiping the imported family away deletes its files; Default comes back if it was the choice.
- (UISwipeActionsConfiguration *)tableView:(UITableView *)table trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)path {
    if (_downloading || path.section != SGFontYours || path.row != 0 || !self.importedName.length) return nil;
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete"
        handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
            removeImported();
            [self refresh];
            done(YES);
        }];
    delete.image = [UIImage systemImageNamed:@"trash"];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

@end

NSArray<SGModRow *> *SGAppFontRows(void) {
    SGModRow *font = SGPageRow(@"Font", ^UIViewController *{ return [SGFontPage new]; });
    font.value = ^NSString *{ return chosenLabel(); };
    return @[font];
}
