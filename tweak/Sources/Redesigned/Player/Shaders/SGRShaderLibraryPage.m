#import "SGRShaders.h"
#import "SGRShaderLibrary.h"
#import "Settings/SGPage.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *boundedError(NSError *error) {
    NSString *message = error.localizedDescription ?: @"The shader could not be saved.";
    return [message substringToIndex:MIN(message.length, 1200)];
}
static void alert(UIViewController *owner, NSString *title, NSString *message) {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [sheet addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [owner presentViewController:sheet animated:YES completion:nil];
}
static void exportProfile(UIViewController *owner, NSDictionary *profile) {
    NSError *error;
    NSData *data = [NSJSONSerialization dataWithJSONObject:profile options:NSJSONWritingPrettyPrinted error:&error];
    NSURL *url = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:[NSString stringWithFormat:@"shader-%@.json", NSUUID.UUID.UUIDString]];
    if (!data || ![data writeToURL:url options:NSDataWritingAtomic error:&error]) { alert(owner, @"Export failed", boundedError(error)); return; }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.sourceView = owner.view;
    share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(owner.view.bounds), CGRectGetMidY(owner.view.bounds), 1, 1);
    share.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *activityError) {
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    };
    [owner presentViewController:share animated:YES completion:nil];
}

@interface SGRShaderEditor : SGPage <UITextViewDelegate>
- (instancetype)initWithProfile:(NSDictionary *)profile;
@end
@implementation SGRShaderEditor {
    NSDictionary *_profile;
    UITextField *_name;
    UITextView *_source;
    UILabel *_status;
    BOOL _saving;
}
- (instancetype)initWithProfile:(NSDictionary *)profile {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _profile = profile;
    self.title = @"Shader source";
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    _name = [UITextField new];
    _name.text = _profile[@"name"];
    _name.placeholder = @"Shader name";
    _name.accessibilityLabel = @"Shader name";
    _name.textColor = UIColor.labelColor;
    _name.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _name.adjustsFontForContentSizeCategory = YES;
    _name.clearButtonMode = UITextFieldViewModeWhileEditing;
    _source = [UITextView new];
    _source.text = _profile[@"source"];
    _source.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:[UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular]];
    _source.adjustsFontForContentSizeCategory = YES;
    _source.textColor = UIColor.labelColor;
    _source.backgroundColor = UIColor.clearColor;
    _source.accessibilityLabel = @"Metal shader source";
    _source.keyboardAppearance = UIKeyboardAppearanceDark;
    _source.autocorrectionType = UITextAutocorrectionTypeNo;
    _source.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _source.spellCheckingType = UITextSpellCheckingTypeNo;
    _source.smartQuotesType = UITextSmartQuotesTypeNo;
    _source.smartDashesType = UITextSmartDashesTypeNo;
    _source.delegate = self;
    _source.textContainerInset = UIEdgeInsetsMake(12, 8, 12, 8);
    _status = [UILabel new];
    _status.numberOfLines = 0;
    _status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _status.adjustsFontForContentSizeCategory = YES;
    _status.textColor = UIColor.secondaryLabelColor;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Compile & save" style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardChanged:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [self updateStatus:@"Edit Metal source, then compile and save. The saved shader runs only when selected in the library."];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)keyboardChanged:(NSNotification *)note {
    CGRect keyboard = [self.view convertRect:[note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue] fromView:nil];
    CGFloat overlap = MAX(0, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(keyboard) - self.view.safeAreaInsets.bottom);
    _source.contentInset = UIEdgeInsetsMake(0, 0, overlap, 0);
    _source.scrollIndicatorInsets = _source.contentInset;
    [_source scrollRangeToVisible:_source.selectedRange];
}
- (void)updateStatus:(NSString *)message {
    _status.text = message;
    [self.tableView beginUpdates];
    [self.tableView endUpdates];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 3; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return 1; }
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section { return @[@"Name", @"Metal source", @"Compiler"] [section]; }
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (section != 1) return nil;
    return @"The template supplies vertex vert, fragment frag, and Uniforms at buffer(0): misc = time/bass/beat/energy; tilt = gravity; opts.x = selected style; tints[2] = cover colors; spectrum[6] = 24 low-to-high bands. Keep the struct and function signatures unchanged. Profiles use 30 fps and half native scale by default; limits are 60 fps, half scale and 1280 pixels.";
}
- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    return path.section == 1 ? MAX(240, self.view.bounds.size.height * 0.5) : UITableViewAutomaticDimension;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIView *content = path.section == 0 ? _name : path.section == 1 ? _source : _status;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12],
        [content.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-12],
        [content.heightAnchor constraintGreaterThanOrEqualToConstant:28]
    ]];
    return cell;
}
- (BOOL)textView:(UITextView *)view shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text {
    NSString *candidate = [view.text stringByReplacingCharactersInRange:range withString:text];
    if ([candidate lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= SGRShaderSourceLimit) return YES;
    [self updateStatus:@"Source is limited to 64 KiB. The extra text was not inserted."];
    return NO;
}
- (void)save {
    if (_saving) return;
    NSMutableDictionary *candidate = [_profile mutableCopy];
    candidate[@"name"] = _name.text ?: @"";
    candidate[@"source"] = _source.text ?: @"";
    NSError *error;
    NSDictionary *valid = [SGRShaderLibrary() validatedProfile:candidate error:&error];
    if (!valid) { [self updateStatus:boundedError(error)]; UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, _status.text); return; }
    _saving = YES;
    _name.enabled = NO;
    _source.editable = NO;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    [self updateStatus:@"Compiling…"];
    SGRShaderValidateSource(valid[@"source"], ^(NSError *compileError) {
        if (compileError) { [self finishedSave:nil error:compileError]; return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSError *saveError;
            BOOL saved = [SGRShaderLibrary() saveProfile:valid error:&saveError];
            dispatch_async(dispatch_get_main_queue(), ^{ [self finishedSave:saved ? valid : nil error:saveError]; });
        });
    });
}
- (void)finishedSave:(NSDictionary *)profile error:(NSError *)error {
    _saving = NO;
    _name.enabled = YES;
    _source.editable = YES;
    self.navigationItem.rightBarButtonItem.enabled = YES;
    if (profile) { _profile = profile; SGRShaderLibraryDidChange(); }
    [self updateStatus:profile ? @"Compiled and saved. Choose this shader in the library to use it." : boundedError(error)];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, _status.text);
}
@end

@interface SGRShaderLibraryPage : SGPage <UIDocumentPickerDelegate>
@end
@implementation SGRShaderLibraryPage
- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"Shader library";
    return self;
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.tableView reloadData]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 2; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return section == 0 ? 3 : SGRShaderLibrary().profiles.count; }
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section { return section ? @"Your shaders" : @"Local shaders"; }
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (section) return SGRShaderLibrary().loadError ?: @"Tap a shader for its source, selection and export. Files stay on this device until you share them. Up to 16 shaders, 64 KiB of Metal source each. Imported code runs on your GPU; frame and resolution limits cannot bound an arbitrary shader's execution time.";
    return @"Create from the original built-in Metal template or import a shader profile JSON file. Source is compiled before saving. The Shader player background must be selected to see it.";
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessibilityTraits |= UIAccessibilityTraitButton;
    if (path.section == 0) cell.textLabel.text = @[@"Create shader", @"Import shader profile", @"Export Metal template"][path.row];
    else {
        NSDictionary *profile = SGRShaderLibrary().profiles[path.row];
        cell.textLabel.text = profile[@"name"];
        BOOL held = [SGRShaderLibrary() isQuarantined:profile[@"id"]];
        cell.detailTextLabel.text = held ? @"Previous session ended unexpectedly · tap to edit or retry" : [NSString stringWithFormat:@"%@ fps · %.0f%% native scale", profile[@"fps"], [profile[@"scale"] doubleValue] * 100];
        cell.accessoryType = SGRShaderIndex() == 8 + path.row ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
- (NSDictionary *)templateProfile {
    return @{@"version": @1, @"id": NSUUID.UUID.UUIDString, @"name": @"My shader", @"source": SGRShaderTemplateSource(), @"fps": @30, @"scale": @0.5};
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section == 0) {
        if (path.row == 0) SGShowPage(self, [[SGRShaderEditor alloc] initWithProfile:[self templateProfile]]);
        else if (path.row == 2) exportProfile(self, [self templateProfile]);
        else {
            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON] asCopy:YES];
            picker.delegate = self;
            [self presentViewController:picker animated:YES completion:nil];
        }
        return;
    }
    NSDictionary *profile = SGRShaderLibrary().profiles[path.row];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:profile[@"name"] message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    BOOL held = [SGRShaderLibrary() isQuarantined:profile[@"id"]];
    [sheet addAction:[UIAlertAction actionWithTitle:held ? @"Retry shader" : @"Use shader" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [SGRShaderLibrary() retryProfile:profile[@"id"]];
        SGRSetShaderIndex(8 + path.row);
        [self.tableView reloadData];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Edit source" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { SGShowPage(self, [[SGRShaderEditor alloc] initWithProfile:profile]); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Export profile" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { exportProfile(self, profile); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete shader" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSError *error;
        if (![SGRShaderLibrary() deleteProfile:profile[@"id"] error:&error]) alert(self, @"Delete failed", boundedError(error));
        else SGRShaderLibraryDidChange();
        [self.tableView reloadData];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = [table cellForRowAtIndexPath:path];
    sheet.popoverPresentationController.sourceRect = [table cellForRowAtIndexPath:path].bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSError *error;
        NSNumber *size;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:&error];
        NSData *data = !error && [size isKindOfClass:NSNumber.class] && size.unsignedLongLongValue <= 512 * 1024 ? [NSData dataWithContentsOfURL:url options:0 error:&error] : nil;
        id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
        // Imported identity never overwrites an existing local shader.
        if ([value isKindOfClass:NSDictionary.class]) { value = [value mutableCopy]; value[@"id"] = NSUUID.UUID.UUIDString; }
        NSDictionary *profile = value ? [SGRShaderLibrary() validatedProfile:value error:&error] : nil;
        if (scoped) [url stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (profile) SGShowPage(self, [[SGRShaderEditor alloc] initWithProfile:profile]);
            else alert(self, @"Import failed", error ? boundedError(error) : @"Choose a shader profile JSON file smaller than 512 KiB.");
        });
    });
}
@end

UIViewController *SGRShaderLibrarySettingsPage(void) { return [SGRShaderLibraryPage new]; }
