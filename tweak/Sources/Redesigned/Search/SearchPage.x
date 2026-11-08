#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Navbar/Navbar.h"
#import "Search.h"

// Layout passes without the header before that is logged.
static const NSUInteger kMissesLogged = 60;

static char kTitleKey, kVanishedKey, kLayoutKey, kRowWatchedKey;

static __weak UICollectionView *sg_list;
static __weak UIStackView *sg_row;
static __weak UIView *sg_scrim;

static void vanish(UIView *view) {
    if (!view) return;
    if (view.alpha != 0) view.alpha = 0;
    if (view.userInteractionEnabled) view.userInteractionEnabled = NO;
    view.accessibilityElementsHidden = YES;
}

// When the avatar is still missed, name what the row actually holds, so the device-logs page tells us the
// class or identifier to match next.
static void dumpRow(UIView *row) {
    __block NSUInteger seen = 0;
    SGForEachView(row, ^(UIView *view) {
        if (seen >= 40) return;
        seen++;
        SGLog(@"redesign search: row dump: %@ | %@ | %@", NSStringFromClass(view.class),
              view.accessibilityIdentifier.length ? view.accessibilityIdentifier : @"-", NSStringFromCGRect(view.frame));
    });
}

static UIView *childNamed(UIView *host, NSString *marker) {
    for (UIView *sub in host.subviews) {
        if ([NSStringFromClass(sub.class) containsString:marker]) return sub;
    }
    return nil;
}

// A depth first search that leaves the list out: the header and the scrim sit beside it, and its cells are hundreds of views.
static UIView *findOutsideList(UIView *view, NSString *identifier) {
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:UICollectionView.class]) continue;
        if ([sub.accessibilityIdentifier isEqualToString:identifier]) return sub;
        UIView *found = findOutsideList(sub, identifier);
        if (found) return found;
    }
    return nil;
}

static BOOL findParts(UIView *view) {
    if (sg_row && sg_list && [sg_row isDescendantOfView:view] && [sg_list isDescendantOfView:view]) return YES;
    sg_row = nil;
    sg_list = nil;
    sg_scrim = nil;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:UICollectionView.class] && [sub.accessibilityIdentifier isEqualToString:SGRSearchListIdentifier]) {
            sg_list = (UICollectionView *)sub;
        }
        UIView *scrim = childNamed(sub, @"GradientView");
        if (scrim) sg_scrim = scrim;
    }
    UIView *row = findOutsideList(view, @"SearchToolBar.Header");
    sg_row = [row isKindOfClass:UIStackView.class] ? (UIStackView *)row : nil;
    if (sg_row && sg_list) return YES;
    static NSUInteger misses;
    if (++misses == kMissesLogged) {
        SGLog(@"redesign search: page parts not found in %lu passes (toolbar row %@, list %@), the header left as Spotify's",
              (unsigned long)misses, sg_row ? @"found" : @"missing", sg_list ? @"found" : @"missing");
    }
    return NO;
}

static NSString *titleText(UIStackView *row) {
    UIView *label = nil;
    for (UIView *part in row.arrangedSubviews) {
        if ([part.accessibilityIdentifier isEqualToString:@"SearchHeaderFind.HeaderLabel"]) label = part;
    }
    for (UIView *sub in label.subviews) {
        if ([sub isKindOfClass:UILabel.class] && ((UILabel *)sub).text.length) return ((UILabel *)sub).text;
    }
    return @"Search";
}

static UILabel *titleIn(UIStackView *row) {
    UILabel *title = objc_getAssociatedObject(row, &kTitleKey);
    if (!title) {
        title = [UILabel new];
        title.textColor = SGRPrimary();
        title.accessibilityTraits = UIAccessibilityTraitHeader;
        title.adjustsFontSizeToFitWidth = YES;
        title.minimumScaleFactor = 0.6;
        title.userInteractionEnabled = NO;
        objc_setAssociatedObject(row, &kTitleKey, title, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (title.superview != row) [row addSubview:title];
    return title;
}

static void layoutHeader(UIStackView *row) {
    if ([objc_getAssociatedObject(row, &kLayoutKey) boolValue]) return;
    objc_setAssociatedObject(row, &kLayoutKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(row, &kRowWatchedKey)) {
        objc_setAssociatedObject(row, &kRowWatchedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGRObserveLayout(row, ^(UIView *view) { layoutHeader((UIStackView *)view); });
    }
    vanish(sg_scrim);

    // As on Home: lay the row out before the walk (the avatar's container is only sized after a pass),
    // match by class or identifier, and make every hide of ours reversible -- Spotify's own controls stay
    // hidden (the title spans the row and would sit under them), but a part an early pass hid that now
    // holds the avatar comes back, so a late-arriving avatar is never stuck behind our alpha.
    [row layoutIfNeeded];
    UIView *face = SGRNavbarProfilePhotoIn(row);
    for (UIView *part in row.arrangedSubviews) {
        BOOL holdsFace = face && [face isDescendantOfView:part];
        if (holdsFace) {
            if ([objc_getAssociatedObject(part, &kVanishedKey) boolValue]) {
                objc_setAssociatedObject(part, &kVanishedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                part.alpha = 1;
                part.userInteractionEnabled = YES;
                part.accessibilityElementsHidden = NO;
            }
        } else if (part.alpha != 0) {
            objc_setAssociatedObject(part, &kVanishedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            vanish(part);
        }
    }
    SGRNavbarSetProfilePhotoVisible(face);
    NSString *text = titleText(row);
    [row layoutIfNeeded];
    SGRNavbarPlaceProfilePhoto(face, row, 0);

    UILabel *title = titleIn(row);
    if (![title.text isEqualToString:text]) {
        title.text = text;
        title.accessibilityLabel = text;
    }
    UIFont *font = SGRFont(UIFontTextStyleLargeTitle, UIFontWeightBold, UIContentSizeCategoryLarge);
    if (![title.font isEqual:font]) title.font = font;

    CGFloat leading = face && SGFlag(SGRKeyNavbarProfilePhoto, YES) ? CGRectGetMaxX(SGFrameIn(face, row)) + SGRGrid : 0;
    CGFloat trailing = row.bounds.size.width;
    CGFloat height = ceil(font.lineHeight);
    CGRect frame = CGRectMake(leading, round(CGRectGetMidY(row.bounds) - height / 2), MAX(0, trailing - leading), height);
    if (!CGRectEqualToRect(title.frame, frame)) title.frame = frame;

    static BOOL logged, dumped;
    if (!dumped && row.window && row.bounds.size.width > 1 && !face) {
        dumped = YES;
        dumpRow(row);
    }
    if (!logged && row.window && CGRectGetMinX(row.frame) >= 0 && row.bounds.size.width > 0) {
        logged = YES;
        SGLog(@"redesign search: toolbar row %@, avatar %@, title %@ \"%@\", scrim %@, profile-photo %@",
              NSStringFromCGRect(row.frame), face ? NSStringFromCGRect(face.frame) : @"not found",
              NSStringFromCGRect(frame), text,
              sg_scrim ? @"found" : @"not found", SGFlag(SGRKeyNavbarProfilePhoto, YES) ? @"on" : @"OFF");
    }
    objc_setAssociatedObject(row, &kLayoutKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%hook _TtC21Browse_BrowsePageImpl24BrowsePageViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *view = ((UIViewController *)self).viewIfLoaded;
    if (!view || !findParts(view)) return;
    layoutHeader(sg_row);
    SGRSearchCloseGap(sg_list);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    %orig;
    [((UIViewController *)self).viewIfLoaded setNeedsLayout];
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC21Browse_BrowsePageImpl24BrowsePageViewController",
        @"_TtC29ListeningActivity_ElementsKit21AdaptiveFaceContainer",
    ]);
}
