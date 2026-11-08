#import "Core/SGCore.h"
#import "Navbar.h"

static NSHashTable<UIView *> *sg_faces;
static char kSlotKey;

@interface SGRProfileSlot : NSObject
@property (nonatomic, weak) UIView *view;
@property (nonatomic) CGAffineTransform original;
@end
@implementation SGRProfileSlot @end

UIView *SGRNavbarProfilePhotoIn(UIView *header) {
    __block UIView *face = nil, *button = nil;
    Class faceClass = NSClassFromString(@"_TtC29ListeningActivity_ElementsKit21AdaptiveFaceContainer");
    SGForEachView(header, ^(UIView *view) {
        if (!face && faceClass && [view isKindOfClass:faceClass]) face = view;
        if (!button && [view.accessibilityIdentifier isEqualToString:@"Components.UI.SideDrawerButton"]) button = view;
    });
    return face ?: button;
}

void SGRNavbarSetProfilePhotoVisible(UIView *face) {
    if (!face) return;
    if (!sg_faces) sg_faces = NSHashTable.weakObjectsHashTable;
    [sg_faces addObject:face];
    BOOL visible = SGFlag(SGRKeyNavbarProfilePhoto, YES);
    face.alpha = visible ? 1 : 0;
    face.userInteractionEnabled = visible;
    face.accessibilityElementsHidden = !visible;
}

void SGRNavbarPlaceProfilePhoto(UIView *face, UIView *header, CGFloat inset) {
    if (!face || face.bounds.size.width <= 1 || header.bounds.size.width <= 1) return;
    UIView *slot = face, *outer = face;
    BOOL arranged = NO;
    for (UIView *view = face; view && view != header; view = view.superview) {
        outer = view;
        if ([view.superview isKindOfClass:UIStackView.class]
            && [((UIStackView *)view.superview).arrangedSubviews containsObject:view]) {
            slot = view;
            arranged = YES;
        }
    }
    if (!arranged) slot = outer;
    SGRProfileSlot *state = objc_getAssociatedObject(face, &kSlotKey);
    if (state.view != slot) {
        if (state.view) state.view.transform = state.original;
        if (!state) {
            state = [SGRProfileSlot new];
            objc_setAssociatedObject(face, &kSlotKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        state.view = slot;
        state.original = slot.transform;
    }
    CGRect frame = [face convertRect:face.bounds toView:header];
    CGFloat left = CGRectGetMinX(header.bounds) + inset;
    CGAffineTransform move = CGAffineTransformMakeTranslation(left - CGRectGetMinX(frame) + slot.transform.tx, 0);
    if (!CGAffineTransformEqualToTransform(slot.transform, move)) slot.transform = move;
}

void SGRNavbarRefreshProfilePhotos(void) {
    for (UIView *face in sg_faces.allObjects) {
        SGRNavbarSetProfilePhotoVisible(face);
        [face.superview setNeedsLayout];
    }
}
