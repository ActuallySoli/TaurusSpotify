#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Shared/Gestures/Gestures.h"
#import "KeyCommands.h"

SGModRow *SGKeyboardShortcutsRow(void) {
    return SGSwitchRow(@"Keyboard shortcuts",
                       @"Space plays or pauses, the arrows skip, L toggles lyrics, Escape closes a sheet and ⌘1–⌘3 switch tabs",
                       SGKeyKeyboardShortcuts);
}

static UIWindow *activeWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
        }
    }
    return nil;
}

static UIResponder *firstResponderIn(UIView *view) {
    if (view.isFirstResponder) return view;
    for (UIView *sub in view.subviews) {
        UIResponder *found = firstResponderIn(sub);
        if (found) return found;
    }
    return nil;
}

static BOOL isEditingText(void) {
    UIWindow *window = activeWindow();
    UIResponder *responder = window ? firstResponderIn(window) : nil;
    if (!responder) return NO;
    if ([responder isKindOfClass:UITextField.class] || [responder isKindOfClass:UITextView.class] || [responder isKindOfClass:UISearchBar.class]) {
        return YES;
    }
    return [responder conformsToProtocol:@protocol(UITextInput)];
}

static UIControl *findControlWithIdentifier(UIView *root, NSString *identifier) {
    if (!root || root.hidden || root.alpha < 0.01) return nil;
    if ([root isKindOfClass:UIControl.class] && [root.accessibilityIdentifier isEqualToString:identifier]) {
        return (UIControl *)root;
    }
    for (UIView *sub in root.subviews) {
        UIControl *found = findControlWithIdentifier(sub, identifier);
        if (found) return found;
    }
    return nil;
}

static void selectTabAtIndex(NSUInteger index) {
    UIWindow *window = activeWindow();
    if (!window) return;
    __block UITabBar *tabBar = nil;
    SGForEachView(window, ^(UIView *v) {
        if (!tabBar && [v isKindOfClass:UITabBar.class] && !v.hidden) tabBar = (UITabBar *)v;
    });
    if (tabBar && index < tabBar.items.count) {
        UITabBarItem *item = tabBar.items[index];
        if ([tabBar.delegate respondsToSelector:@selector(tabBar:didSelectItem:)]) {
            [tabBar.delegate tabBar:tabBar didSelectItem:item];
            return;
        }
    }
    NSMutableArray<UIControl *> *tabButtons = [NSMutableArray array];
    SGForEachView(window, ^(UIView *v) {
        if ([v isKindOfClass:UIControl.class] && [v.accessibilityIdentifier hasPrefix:@"TabBarItem."]) {
            [tabButtons addObject:(UIControl *)v];
        }
    });
    [tabButtons sortUsingComparator:^NSComparisonResult(UIControl *a, UIControl *b) {
        CGFloat ax = [a convertPoint:CGPointZero toView:window].x;
        CGFloat bx = [b convertPoint:CGPointZero toView:window].x;
        return ax < bx ? NSOrderedAscending : (ax > bx ? NSOrderedDescending : NSOrderedSame);
    }];
    if (index < tabButtons.count) {
        [tabButtons[index] sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
}

%hook UIApplication

- (NSArray<UIKeyCommand *> *)keyCommands {
    NSArray<UIKeyCommand *> *orig = %orig;
    if (!SGFlag(SGKeyKeyboardShortcuts, YES)) return orig;

    NSMutableArray<UIKeyCommand *> *commands = orig ? [orig mutableCopy] : [NSMutableArray array];
    if (!isEditingText()) {
        UIKeyCommand *space = [UIKeyCommand keyCommandWithInput:@" " modifierFlags:0 action:@selector(sg_keyPlayPause:)];
        space.discoverabilityTitle = @"Play / Pause";
        if (@available(iOS 15.0, *)) space.wantsPriorityOverSystemBehavior = YES;
        [commands addObject:space];

        UIKeyCommand *right = [UIKeyCommand keyCommandWithInput:UIKeyInputRightArrow modifierFlags:0 action:@selector(sg_keyNext:)];
        right.discoverabilityTitle = @"Next Track";
        if (@available(iOS 15.0, *)) right.wantsPriorityOverSystemBehavior = YES;
        [commands addObject:right];

        UIKeyCommand *left = [UIKeyCommand keyCommandWithInput:UIKeyInputLeftArrow modifierFlags:0 action:@selector(sg_keyPrevious:)];
        left.discoverabilityTitle = @"Previous Track";
        if (@available(iOS 15.0, *)) left.wantsPriorityOverSystemBehavior = YES;
        [commands addObject:left];

        UIKeyCommand *lyrics = [UIKeyCommand keyCommandWithInput:@"l" modifierFlags:0 action:@selector(sg_keyLyrics:)];
        lyrics.discoverabilityTitle = @"Lyrics";
        [commands addObject:lyrics];
    }

    UIKeyCommand *esc = [UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(sg_keyClose:)];
    esc.discoverabilityTitle = @"Close";
    [commands addObject:esc];

    UIKeyCommand *home = [UIKeyCommand keyCommandWithInput:@"1" modifierFlags:UIKeyModifierCommand action:@selector(sg_keyHome:)];
    home.discoverabilityTitle = @"Home";
    [commands addObject:home];

    UIKeyCommand *search = [UIKeyCommand keyCommandWithInput:@"2" modifierFlags:UIKeyModifierCommand action:@selector(sg_keySearch:)];
    search.discoverabilityTitle = @"Search";
    [commands addObject:search];

    UIKeyCommand *library = [UIKeyCommand keyCommandWithInput:@"3" modifierFlags:UIKeyModifierCommand action:@selector(sg_keyLibrary:)];
    library.discoverabilityTitle = @"Your Library";
    [commands addObject:library];

    UIKeyCommand *find = [UIKeyCommand keyCommandWithInput:@"f" modifierFlags:UIKeyModifierCommand action:@selector(sg_keyFind:)];
    find.discoverabilityTitle = @"Search";
    [commands addObject:find];

    return commands;
}

%new
- (void)sg_keyPlayPause:(UIKeyCommand *)command {
    SGPerformGestureAction(SGGesturePlayPause);
}

%new
- (void)sg_keyNext:(UIKeyCommand *)command {
    SGPerformGestureAction(SGGestureNextTrack);
}

%new
- (void)sg_keyPrevious:(UIKeyCommand *)command {
    SGPerformGestureAction(SGGesturePreviousTrack);
}

%new
- (void)sg_keyLyrics:(UIKeyCommand *)command {
    UIWindow *window = activeWindow();
    if (!window) return;
    UIControl *btn = findControlWithIdentifier(window, @"NowPlaying.ReadAlongButton");
    if (btn) [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
}

%new
- (void)sg_keyClose:(UIKeyCommand *)command {
    UIWindow *window = activeWindow();
    if (!window) return;
    UIControl *closeBtn = findControlWithIdentifier(window, @"NowPlaying_ScrollView_CloseButton");
    if (closeBtn) {
        [closeBtn sendActionsForControlEvents:UIControlEventTouchUpInside];
        return;
    }
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if (top != window.rootViewController) {
        [top dismissViewControllerAnimated:YES completion:nil];
    }
}

%new
- (void)sg_keyHome:(UIKeyCommand *)command {
    selectTabAtIndex(0);
}

%new
- (void)sg_keySearch:(UIKeyCommand *)command {
    selectTabAtIndex(1);
}

%new
- (void)sg_keyLibrary:(UIKeyCommand *)command {
    selectTabAtIndex(2);
}

%new
- (void)sg_keyFind:(UIKeyCommand *)command {
    selectTabAtIndex(1);
}

%end

%ctor {
    %init;
}
