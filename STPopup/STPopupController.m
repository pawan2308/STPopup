//
//  STPopupController.m
//  STPopup
//
//  Created by Kevin Lin on 11/9/15.
//  Copyright (c) 2015 Sth4Me. All rights reserved.
//

#import "STPopupController.h"
#import "STPopupLeftBarItem.h"
#import "STPopupNavigationBar.h"
#import "STPopupPopoverArrowView.h"
#import "UIViewController+STPopup.h"
#import "UIResponder+STPopup.h"

CGFloat const STPopupBottomSheetExtraHeight = 80;
CGFloat const STPopupPopoverMargin = 10;

static NSMutableSet *_retainedPopupControllers;

@protocol STPopupNavigationTouchEventDelegate <NSObject>

- (void)popupNavigationBar:(STPopupNavigationBar *)navigationBar touchDidMoveWithOffset:(CGFloat)offset;
- (void)popupNavigationBar:(STPopupNavigationBar *)navigationBar touchDidEndWithOffset:(CGFloat)offset;

@end

@interface STPopupNavigationBar (STInternal)

@property (nonatomic, weak) id<STPopupNavigationTouchEventDelegate> touchEventDelegate;

@end

@interface UIViewController (STInternal)

@property (nonatomic, weak) STPopupController *popupController;

@end

@interface STPopupContainerViewController : UIViewController

@end

@implementation STPopupContainerViewController

- (UIStatusBarStyle)preferredStatusBarStyle
{
    if (self.childViewControllers.count || !self.presentingViewController) {
        return [super preferredStatusBarStyle];
    }
    return [self.presentingViewController preferredStatusBarStyle];
}

- (UIViewController *)childViewControllerForStatusBarHidden
{
    return self.childViewControllers.lastObject;
}

- (UIViewController *)childViewControllerForStatusBarStyle
{
    return self.childViewControllers.lastObject;
}

- (void)showViewController:(UIViewController *)vc sender:(id)sender
{
    if (!CGSizeEqualToSize(vc.contentSizeInPopup, CGSizeZero) ||
        !CGSizeEqualToSize(vc.landscapeContentSizeInPopup, CGSizeZero)) {
        UIViewController *childViewController = self.childViewControllers.lastObject;
        [childViewController.popupController pushViewController:vc animated:YES];
    }
    else {
        [self presentViewController:vc animated:YES completion:nil];
    }
}

- (void)showDetailViewController:(UIViewController *)vc sender:(id)sender
{
    if (!CGSizeEqualToSize(vc.contentSizeInPopup, CGSizeZero) ||
        !CGSizeEqualToSize(vc.landscapeContentSizeInPopup, CGSizeZero)) {
        UIViewController *childViewController = self.childViewControllers.lastObject;
        [childViewController.popupController pushViewController:vc animated:YES];
    }
    else {
        [self presentViewController:vc animated:YES completion:nil];
    }
}

@end

@interface STPopupController () <UIViewControllerTransitioningDelegate, UIViewControllerAnimatedTransitioning, STPopupNavigationTouchEventDelegate>

@end

@implementation STPopupController
{
    STPopupContainerViewController *_containerViewController;
    NSMutableArray *_viewControllers; // <UIViewController>
    UIView *_contentView;
    UILabel *_defaultTitleLabel;
    STPopupLeftBarItem *_defaultLeftBarItem;
    STPopupPopoverArrowView *_popoverArrowView;
    NSDictionary *_keyboardInfo;
    BOOL _observing;
}

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _retainedPopupControllers = [NSMutableSet new];
    });
}

- (instancetype)init
{
    if (self = [super init]) {
        [self setup];
    }
    return self;
}

- (instancetype)initWithRootViewController:(UIViewController *)rootViewController
{
    if (self = [self init]) {
        [self pushViewController:rootViewController animated:NO];
    }
    return self;
}

- (void)dealloc
{
    [self destroyObservers];
    for (UIViewController *viewController in _viewControllers) {
        viewController.popupController = nil; // Avoid crash when try to access unsafe unretained property
        [self destroyObserversOfViewController:viewController];
    }
}

- (UIViewController *)topViewController
{
  return _viewControllers.lastObject;
}

- (BOOL)presented
{
    return _containerViewController.presentingViewController != nil;
}

- (void)setBackgroundView:(UIView *)backgroundView
{
    [_backgroundView removeFromSuperview];
    _backgroundView = backgroundView;
    _backgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_backgroundView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bgViewDidTap)]];
    [_containerViewController.view insertSubview:_backgroundView atIndex:0];
}

- (void)setHidesCloseButton:(BOOL)hidesCloseButton
{
    _hidesCloseButton = hidesCloseButton;
    [self updateNavigationBarAniamted:NO];
}

#pragma mark - Observers

- (void)setupObservers
{
    if (_observing) {
        return;
    }
    _observing = YES;
    
    // Observe navigation bar
    [_navigationBar addObserver:self forKeyPath:NSStringFromSelector(@selector(tintColor)) options:NSKeyValueObservingOptionNew context:nil];
    [_navigationBar addObserver:self forKeyPath:NSStringFromSelector(@selector(titleTextAttributes)) options:NSKeyValueObservingOptionNew context:nil];
    
    // Observe orientation change
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(orientationDidChange) name:UIApplicationDidChangeStatusBarOrientationNotification object:nil];
    
    // Observe keyboard
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    
    // Observe responder change
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(firstResponderDidChange) name:STPopupFirstResponderDidChangeNotification object:nil];
}

- (void)destroyObservers
{
    if (!_observing) {
        return;
    }
    _observing = NO;
    
    [_navigationBar removeObserver:self forKeyPath:NSStringFromSelector(@selector(tintColor))];
    [_navigationBar removeObserver:self forKeyPath:NSStringFromSelector(@selector(titleTextAttributes))];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupObserversForViewController:(UIViewController *)viewController
{
    [viewController addObserver:self forKeyPath:NSStringFromSelector(@selector(contentSizeInPopup)) options:NSKeyValueObservingOptionNew context:nil];
    [viewController addObserver:self forKeyPath:NSStringFromSelector(@selector(landscapeContentSizeInPopup)) options:NSKeyValueObservingOptionNew context:nil];
    [viewController.navigationItem addObserver:self forKeyPath:NSStringFromSelector(@selector(title)) options:NSKeyValueObservingOptionNew context:nil];
    [viewController.navigationItem addObserver:self forKeyPath:NSStringFromSelector(@selector(titleView)) options:NSKeyValueObservingOptionNew context:nil];
    [viewController.navigationItem addObserver:self forKeyPath:NSStringFromSelector(@selector(leftBarButtonItem)) options:NSKeyValueObservingOptionNew context:nil];
    [viewController.navigationItem addObserver:self forKeyPath:NSStringFromSelector(@selector(leftBarButtonItems)) options:NSKeyValueObservingOptionNew context:nil];
    [viewController.navigationItem addObserver:self forKeyPath:NSStringFromSelector(@selector(rightBarButtonItem)) options:NSKeyValueObservingOptionNew context:nil];
    [viewController.navigationItem addObserver:self forKeyPath:NSStringFromSelector(@selector(rightBarButtonItems)) options:NSKeyValueObservingOptionNew context:nil];
    [viewController.navigationItem addObserver:self forKeyPath:NSStringFromSelector(@selector(hidesBackButton)) options:NSKeyValueObservingOptionNew context:nil];
}

- (void)destroyObserversOfViewController:(UIViewController *)viewController
{
    [viewController removeObserver:self forKeyPath:NSStringFromSelector(@selector(contentSizeInPopup))];
    [viewController removeObserver:self forKeyPath:NSStringFromSelector(@selector(landscapeContentSizeInPopup))];
    [viewController.navigationItem removeObserver:self forKeyPath:NSStringFromSelector(@selector(title))];
    [viewController.navigationItem removeObserver:self forKeyPath:NSStringFromSelector(@selector(titleView))];
    [viewController.navigationItem removeObserver:self forKeyPath:NSStringFromSelector(@selector(leftBarButtonItem))];
    [viewController.navigationItem removeObserver:self forKeyPath:NSStringFromSelector(@selector(leftBarButtonItems))];
    [viewController.navigationItem removeObserver:self forKeyPath:NSStringFromSelector(@selector(rightBarButtonItem))];
    [viewController.navigationItem removeObserver:self forKeyPath:NSStringFromSelector(@selector(rightBarButtonItems))];
    [viewController.navigationItem removeObserver:self forKeyPath:NSStringFromSelector(@selector(hidesBackButton))];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    UIViewController *topViewController = self.topViewController;
    if (object == _navigationBar || object == topViewController.navigationItem) {
        if (topViewController.isViewLoaded && topViewController.view.superview) {
            [self updateNavigationBarAniamted:NO];
        }
    }
    else if (object == topViewController) {
        if (topViewController.isViewLoaded && topViewController.view.superview) {
            [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:1 initialSpringVelocity:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                [self layoutContainerView];
            } completion:nil];
        }
    }
}

#pragma mark - STPopupController present & dismiss & push & pop

- (void)presentInViewController:(UIViewController *)viewController
{
    [self presentInViewController:viewController completion:nil];
}

- (void)presentInViewController:(UIViewController *)viewController completion:(void (^)(void))completion
{
    if (self.presented) {
        return;
    }
    
    [self setupObservers];
    
    [_retainedPopupControllers addObject:self];
    [viewController presentViewController:_containerViewController animated:YES completion:completion];
}

- (void)dismiss
{
    [self dismissWithCompletion:nil];
}

- (void)dismissWithCompletion:(void (^)(void))completion
{
    if (!self.presented) {
        return;
    }
    
    [self destroyObservers];
    
    [_containerViewController dismissViewControllerAnimated:YES completion:^{
        [_retainedPopupControllers removeObject:self];
        if (completion) {
            completion();
        }
    }];
}

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated
{
    if (!_viewControllers) {
        _viewControllers = [NSMutableArray new];
    }
    
    UIViewController *topViewController = self.topViewController;
    viewController.popupController = self;
    [_viewControllers addObject:viewController];
    
    if (self.presented) {
        [self transitFromViewController:topViewController toViewController:viewController animated:animated];
    }
    [self setupObserversForViewController:viewController];
}

- (void)popViewControllerAnimated:(BOOL)animated
{
    if (_viewControllers.count <= 1) {
        [self dismiss];
        return;
    }
    
    UIViewController *topViewController = self.topViewController;
    [self destroyObserversOfViewController:topViewController];
    [_viewControllers removeObject:topViewController];
    
    if (self.presented) {
        [self transitFromViewController:topViewController toViewController:self.topViewController animated:animated];
    }
    
    topViewController.popupController = nil;
}

- (void)transitFromViewController:(UIViewController *)fromViewController toViewController:(UIViewController *)toViewController animated:(BOOL)animated
{
    [fromViewController beginAppearanceTransition:NO animated:animated];
    [toViewController beginAppearanceTransition:YES animated:animated];
    
    [fromViewController willMoveToParentViewController:nil];
    [_containerViewController addChildViewController:toViewController];
    
    if (animated) {
        // Capture view in "fromViewController" to avoid "viewWillAppear" and "viewDidAppear" being called.
        UIGraphicsBeginImageContextWithOptions(fromViewController.view.bounds.size, NO, [UIScreen mainScreen].scale);
        [fromViewController.view drawViewHierarchyInRect:fromViewController.view.bounds afterScreenUpdates:NO];

        UIImageView *capturedView = [[UIImageView alloc] initWithImage:UIGraphicsGetImageFromCurrentImageContext()];
        
        UIGraphicsEndImageContext();
        
        capturedView.frame = CGRectMake(_contentView.frame.origin.x, _contentView.frame.origin.y, fromViewController.view.bounds.size.width, fromViewController.view.bounds.size.height);
        [_containerView insertSubview:capturedView atIndex:0];
        
        [fromViewController.view removeFromSuperview];
        
        _containerView.userInteractionEnabled = NO;
        toViewController.view.alpha = 0;
        [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:1 initialSpringVelocity:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            [self layoutContainerView];
            [_contentView addSubview:toViewController.view];
            capturedView.alpha = 0;
            toViewController.view.alpha = 1;
            [_containerViewController setNeedsStatusBarAppearanceUpdate];
        } completion:^(BOOL finished) {
            [capturedView removeFromSuperview];
            [fromViewController removeFromParentViewController];
            
            _containerView.userInteractionEnabled = YES;
            [toViewController didMoveToParentViewController:_containerViewController];
            
            [fromViewController endAppearanceTransition];
            [toViewController endAppearanceTransition];
        }];
        [self updateNavigationBarAniamted:animated];
    }
    else {
        [self layoutContainerView];
        [_contentView addSubview:toViewController.view];
        [_containerViewController setNeedsStatusBarAppearanceUpdate];
        [self updateNavigationBarAniamted:animated];
        
        [fromViewController.view removeFromSuperview];
        [fromViewController removeFromParentViewController];
        
        [toViewController didMoveToParentViewController:_containerViewController];
        
        [fromViewController endAppearanceTransition];
        [toViewController endAppearanceTransition];
    }
}

- (void)updateNavigationBarAniamted:(BOOL)animated
{
    BOOL shouldAnimateDefaultLeftBarItem = animated && _navigationBar.topItem.leftBarButtonItem == _defaultLeftBarItem;
    
    UIViewController *topViewController = self.topViewController;
    UIView *lastTitleView = _navigationBar.topItem.titleView;
    _navigationBar.items = @[ [UINavigationItem new] ];
    _navigationBar.topItem.leftBarButtonItems = topViewController.navigationItem.leftBarButtonItems ? : (topViewController.navigationItem.hidesBackButton ? nil : @[ _defaultLeftBarItem ]);
    _navigationBar.topItem.rightBarButtonItems = topViewController.navigationItem.rightBarButtonItems;
    if (self.hidesCloseButton && topViewController == _viewControllers.firstObject &&
        _navigationBar.topItem.leftBarButtonItem == _defaultLeftBarItem) {
        _navigationBar.topItem.leftBarButtonItems = nil;
    }
    
    if (animated) {
        UIView *fromTitleView, *toTitleView;
        if (lastTitleView == _defaultTitleLabel)    {
            UILabel *tempLabel = [[UILabel alloc] initWithFrame:_defaultTitleLabel.frame];
            tempLabel.textColor = _defaultTitleLabel.textColor;
            tempLabel.font = _defaultTitleLabel.font;
            tempLabel.attributedText = [[NSAttributedString alloc] initWithString:_defaultTitleLabel.text ? : @""
                                                                       attributes:_navigationBar.titleTextAttributes];
            fromTitleView = tempLabel;
        }
        else {
            fromTitleView = lastTitleView;
        }
        
        if (topViewController.navigationItem.titleView) {
            toTitleView = topViewController.navigationItem.titleView;
        }
        else {
            NSString *title = (topViewController.title ? : topViewController.navigationItem.title) ? : @"";
            _defaultTitleLabel = [UILabel new];
            _defaultTitleLabel.attributedText = [[NSAttributedString alloc] initWithString:title
                                                                                attributes:_navigationBar.titleTextAttributes];
            [_defaultTitleLabel sizeToFit];
            toTitleView = _defaultTitleLabel;
        }
        
        [_navigationBar addSubview:fromTitleView];
        _navigationBar.topItem.titleView = toTitleView;
        toTitleView.alpha = 0;
        
        [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:1 initialSpringVelocity:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            fromTitleView.alpha = 0;
            toTitleView.alpha = 1;
        } completion:^(BOOL finished) {
            [fromTitleView removeFromSuperview];
        }];
    }
    else {
        if (topViewController.navigationItem.titleView) {
            _navigationBar.topItem.titleView = topViewController.navigationItem.titleView;
        }
        else {
            NSString *title = (topViewController.title ? : topViewController.navigationItem.title) ? : @"";
            _defaultTitleLabel = [UILabel new];
            _defaultTitleLabel.attributedText = [[NSAttributedString alloc] initWithString:title
                                                                                attributes:_navigationBar.titleTextAttributes];
            [_defaultTitleLabel sizeToFit];
            _navigationBar.topItem.titleView = _defaultTitleLabel;
        }
    }
    _defaultLeftBarItem.tintColor = _navigationBar.tintColor;
    [_defaultLeftBarItem setType:_viewControllers.count > 1 ? STPopupLeftBarItemTypeArrow : STPopupLeftBarItemTypeCross
                        animated:shouldAnimateDefaultLeftBarItem];
}

- (void)setNavigationBarHidden:(BOOL)navigationBarHidden
{
    [self setNavigationBarHidden:navigationBarHidden animated:NO];
}

- (void)setNavigationBarHidden:(BOOL)navigationBarHidden animated:(BOOL)animated
{
    _navigationBarHidden = navigationBarHidden;
    _navigationBar.alpha = navigationBarHidden ? 1 : 0;
    
    if (!animated) {
        [self layoutContainerView];
        _navigationBar.hidden = navigationBarHidden;
        return;
    }
    
    if (!navigationBarHidden) {
        _navigationBar.hidden = navigationBarHidden;
    }
    [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:1 initialSpringVelocity:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        _navigationBar.alpha = navigationBarHidden ? 0 : 1;
        [self layoutContainerView];
    } completion:^(BOOL finished) {
        _navigationBar.hidden = navigationBarHidden;
    }];
}

#pragma mark - UI layout

- (void)layoutContainerView
{
    _backgroundView.frame = _containerViewController.view.bounds;
 
    CGFloat preferredNavigationBarHeight = [self preferredNavigationBarHeight];
    CGFloat navigationBarHeight = _navigationBarHidden ? 0 : preferredNavigationBarHeight;
    CGSize contentSizeOfTopView = [self contentSizeOfTopView];
    CGFloat containerViewWidth = contentSizeOfTopView.width;
    CGFloat containerViewHeight = contentSizeOfTopView.height + navigationBarHeight;
    CGFloat containerViewX = (_containerViewController.view.bounds.size.width - containerViewWidth) / 2;
    CGFloat containerViewY = 0;
    
    switch (self.style) {
        case STPopupStyleFormSheet: {
            containerViewY = (_containerViewController.view.bounds.size.height - containerViewHeight) / 2;
        }
            break;
        case STPopupStyleBottomSheet: {
            containerViewY = _containerViewController.view.bounds.size.height - containerViewHeight;
            containerViewHeight += STPopupBottomSheetExtraHeight;
        }
            break;
        case STPopupStylePopover: {
            CGPoint popoverOrigin = [self popoverOriginForContainerSize:CGSizeMake(containerViewWidth, containerViewHeight)];
            containerViewX = popoverOrigin.x;
            containerViewY = popoverOrigin.y;
        }
            break;
        default:
            break;
    }
    
    if (self.style == STPopupStylePopover) {
        [self layoutPopoverArrow];
        CGRect popoverArrowRect = _popoverArrowView.frame;
        CGSize offsetSize = CGSizeMake(popoverArrowRect.origin.x + popoverArrowRect.size.width / 2 - containerViewX,
                                       popoverArrowRect.origin.y + popoverArrowRect.size.height / 2 - containerViewY);
        switch (self.popoverArrowDirection) {
            case STPopupPopoverArrowDirectionUp:
                self.containerView.layer.anchorPoint = CGPointMake(offsetSize.width / containerViewWidth, 0);
                break;
            case STPopupPopoverArrowDirectionDown:
                self.containerView.layer.anchorPoint = CGPointMake(offsetSize.width / containerViewWidth, 1);
                break;
            case STPopupPopoverArrowDirectionLeft:
                self.containerView.layer.anchorPoint = CGPointMake(0, offsetSize.height / containerViewHeight);
                break;
            case STPopupPopoverArrowDirectionRight:
                self.containerView.layer.anchorPoint = CGPointMake(1, offsetSize.height / containerViewHeight);
                break;
            default:
                break;
        }
    }
    else {
        [_popoverArrowView removeFromSuperview];
        _popoverArrowView = nil;
        self.containerView.layer.anchorPoint = CGPointMake(0.5, 0.5);
    }
    
    _containerView.frame = CGRectMake(containerViewX, containerViewY, containerViewWidth, containerViewHeight);
    _navigationBar.frame = CGRectMake(0, 0, containerViewWidth, preferredNavigationBarHeight);
    _contentView.frame = CGRectMake(0, navigationBarHeight, contentSizeOfTopView.width, contentSizeOfTopView.height);
    
    UIViewController *topViewController = self.topViewController;
    topViewController.view.frame = _contentView.bounds;
    
    if (self.style == STPopupStylePopover) {
        _popoverArrowView.backgroundColor = [self preferredPopoverArrowColor];
    }
}

- (CGSize)contentSizeOfTopView
{
    UIViewController *topViewController = self.topViewController;
    CGSize contentSize = CGSizeZero;
    switch ([UIApplication sharedApplication].statusBarOrientation) {
        case UIInterfaceOrientationLandscapeLeft:
        case UIInterfaceOrientationLandscapeRight: {
            contentSize = topViewController.landscapeContentSizeInPopup;
            if (CGSizeEqualToSize(contentSize, CGSizeZero)) {
                contentSize = topViewController.contentSizeInPopup;
            }
        }
            break;
        default: {
            contentSize = topViewController.contentSizeInPopup;
        }
            break;
    }
    
    NSAssert(!CGSizeEqualToSize(contentSize, CGSizeZero), @"contentSizeInPopup should not be size zero.");
    
    return contentSize;
}

- (CGFloat)preferredNavigationBarHeight
{
    // The preferred height of navigation bar is different between iPhone (4, 5, 6) and 6 Plus.
    // Create a navigation controller to get the preferred height of navigation bar.
    UINavigationController *navigationController = [UINavigationController new];
    return navigationController.navigationBar.bounds.size.height;
}

#pragma mark - Popover layout

- (void)layoutPopoverArrow
{
    if (!_popoverArrowView) {
        _popoverArrowView = [STPopupPopoverArrowView new];
        [_popoverArrowView sizeToFit];
        [_containerViewController.view addSubview:_popoverArrowView];
    }
    
    switch (self.popoverArrowDirection) {
        case STPopupPopoverArrowDirectionUp:
            _popoverArrowView.transform = CGAffineTransformIdentity;
            break;
        case STPopupPopoverArrowDirectionDown:
            _popoverArrowView.transform = CGAffineTransformMakeRotation(M_PI);
            break;
        case STPopupPopoverArrowDirectionLeft:
            _popoverArrowView.transform = CGAffineTransformMakeRotation(-M_PI_2);
            break;
        case STPopupPopoverArrowDirectionRight:
            _popoverArrowView.transform = CGAffineTransformMakeRotation(M_PI_2);
            break;
        default:
            break;
    }
    
    CGRect popoverArrowFrame = _popoverArrowView.frame;
    popoverArrowFrame.origin = [self popoverArrowOrigin];
    _popoverArrowView.frame = popoverArrowFrame;
}

- (CGPoint)popoverOriginForContainerSize:(CGSize)containerSize
{
    CGRect targetRect = self.popoverTargetRect;
    CGSize maxSize = _containerViewController.view.frame.size;
    CGPoint popoverOrigin = CGPointZero;
    switch (self.popoverArrowDirection) {
        case STPopupPopoverArrowDirectionUp:
            popoverOrigin = CGPointMake(targetRect.origin.x + targetRect.size.width / 2 - containerSize.width / 2,
                                        targetRect.origin.y + targetRect.size.height + STPopupPopoverArrowViewHeight);
            break;
        case STPopupPopoverArrowDirectionDown:
            popoverOrigin = CGPointMake(targetRect.origin.x + targetRect.size.width / 2 - containerSize.width / 2,
                                        targetRect.origin.y - containerSize.height - STPopupPopoverArrowViewHeight);
            break;
        case STPopupPopoverArrowDirectionLeft:
            popoverOrigin = CGPointMake(targetRect.origin.x + targetRect.size.width + STPopupPopoverArrowViewHeight,
                                        targetRect.origin.y + targetRect.size.height / 2 - containerSize.height / 2);
            break;
        case STPopupPopoverArrowDirectionRight:
            popoverOrigin = CGPointMake(targetRect.origin.x - containerSize.width - STPopupPopoverArrowViewHeight,
                                        targetRect.origin.y + targetRect.size.height / 2 - containerSize.height / 2);
            break;
    }
    
    if (self.popoverArrowDirection == STPopupPopoverArrowDirectionUp ||
        self.popoverArrowDirection == STPopupPopoverArrowDirectionDown) {
        // Adjust popover origin for horizontal space
        if (popoverOrigin.x + containerSize.width + STPopupPopoverMargin > maxSize.width) {
            popoverOrigin.x = maxSize.width - STPopupPopoverMargin - containerSize.width;
        }
        else if (popoverOrigin.x < STPopupPopoverMargin) {
            popoverOrigin.x = STPopupPopoverMargin;
        }
    }
    else {
        // Adjust popover origin for vertical space
        if (popoverOrigin.y + containerSize.height + STPopupPopoverMargin > maxSize.height) {
            popoverOrigin.y = maxSize.height - STPopupPopoverMargin - containerSize.height;
        }
        else if (popoverOrigin.y < STPopupPopoverMargin) {
            popoverOrigin.y = STPopupPopoverMargin;
        }
    }
    
    return popoverOrigin;
}

- (CGPoint)popoverArrowOrigin
{
    CGRect targetRect = self.popoverTargetRect;
    switch (self.popoverArrowDirection) {
        case STPopupPopoverArrowDirectionUp:
            return CGPointMake(targetRect.origin.x + (targetRect.size.width - STPopupPopoverArrowViewWidth) / 2,
                               targetRect.origin.y + targetRect.size.height);
        case STPopupPopoverArrowDirectionDown:
            return CGPointMake(targetRect.origin.x + (targetRect.size.width - STPopupPopoverArrowViewWidth) / 2,
                               targetRect.origin.y - STPopupPopoverArrowViewHeight);
        case STPopupPopoverArrowDirectionLeft:
            return CGPointMake(targetRect.origin.x + targetRect.size.width,
                               targetRect.origin.y + (targetRect.size.height - STPopupPopoverArrowViewWidth) / 2);
        case STPopupPopoverArrowDirectionRight:
            return CGPointMake(targetRect.origin.x - STPopupPopoverArrowViewHeight,
                               targetRect.origin.y + (targetRect.size.height - STPopupPopoverArrowViewWidth) / 2);
        default:
            break;
    }
}

- (UIColor *)preferredPopoverArrowColor
{
    CGRect popoverArrowRect = _popoverArrowView.frame;
    CGSize offsetSize = CGSizeMake(popoverArrowRect.origin.x + popoverArrowRect.size.width / 2 - _containerView.frame.origin.x,
                                   popoverArrowRect.origin.y + popoverArrowRect.size.height / 2 - _containerView.frame.origin.y);
    CGPoint capturedOrigin = CGPointZero;
    switch (self.popoverArrowDirection) {
        case STPopupPopoverArrowDirectionUp:
            capturedOrigin = CGPointMake(offsetSize.width, 0);
            break;
        case STPopupPopoverArrowDirectionDown:
            capturedOrigin = CGPointMake(offsetSize.width, _containerView.frame.size.height - 1);
            break;
        case STPopupPopoverArrowDirectionLeft:
            capturedOrigin = CGPointMake(0, offsetSize.height);
            break;
        case STPopupPopoverArrowDirectionRight:
            capturedOrigin = CGPointMake(_containerView.frame.size.width - 1, offsetSize.height);
            break;
        default:
            break;
    }
    
    unsigned char pixel[4] = {0};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, colorSpace,
                                                 kCGBitmapAlphaInfoMask & kCGImageAlphaPremultipliedLast);
    
    CGContextTranslateCTM(context, -capturedOrigin.x, -capturedOrigin.y);
    
    [_containerView.layer renderInContext:context];
    
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    
    return [UIColor colorWithRed:pixel[0]/255.0 green:pixel[1]/255.0 blue:pixel[2]/255.0 alpha:pixel[3]/255.0];
}

#pragma mark - UI setup

- (void)setup
{
    _containerViewController = [STPopupContainerViewController new];
    _containerViewController.view.backgroundColor = [UIColor clearColor];
    _containerViewController.modalPresentationStyle = UIModalPresentationCustom;
    _containerViewController.transitioningDelegate = self;
    [self setupBackgroundView];
    [self setupContainerView];
    [self setupNavigationBar];
}

- (void)setupBackgroundView
{
    UIView *backgroundView = [UIView new];
    backgroundView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    self.backgroundView = backgroundView;
}

- (void)setupContainerView
{
    _containerView = [UIView new];
    _containerView.backgroundColor = [UIColor whiteColor];
    _containerView.clipsToBounds = YES;
    [_containerViewController.view addSubview:_containerView];
    
    _contentView = [UIView new];
    [_containerView addSubview:_contentView];
}

- (void)setupNavigationBar
{
    STPopupNavigationBar *navigationBar = [STPopupNavigationBar new];
    navigationBar.touchEventDelegate = self;
    
    _navigationBar = navigationBar;
    [_containerView addSubview:_navigationBar];
    
    _defaultTitleLabel = [UILabel new];
    _defaultLeftBarItem = [[STPopupLeftBarItem alloc] initWithTarget:self action:@selector(leftBarItemDidTap)];
}

- (void)leftBarItemDidTap
{
    switch (_defaultLeftBarItem.type) {
        case STPopupLeftBarItemTypeCross:
            [self dismiss];
            break;
        case STPopupLeftBarItemTypeArrow:
            [self popViewControllerAnimated:YES];
            break;
        default:
            break;
    }
}

- (void)bgViewDidTap
{
    [_containerView endEditing:YES];
}

- (void)setCornerRadius:(CGFloat)cornerRadius
{
    _cornerRadius = cornerRadius;
    _containerView.layer.cornerRadius = self.cornerRadius;
}

#pragma mark - UIApplicationDidChangeStatusBarOrientationNotification

- (void)orientationDidChange
{
    [_containerView endEditing:YES];
    [UIView animateWithDuration:0.2 delay:0 usingSpringWithDamping:1 initialSpringVelocity:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        _containerView.alpha = 0;
    } completion:^(BOOL finished) {
        [self layoutContainerView];
        [UIView animateWithDuration:0.2 delay:0 usingSpringWithDamping:1 initialSpringVelocity:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            _containerView.alpha = 1;
        } completion:nil];
    }];
}

#pragma mark - UIKeyboardWillShowNotification & UIKeyboardWillHideNotification

- (void)keyboardWillShow:(NSNotification *)notification
{
    if (self.style == STPopupStylePopover) {
        return;
    }
    
    UIView<UIKeyInput> *currentTextInput = [self getCurrentTextInputInView:_containerView];
    if (!currentTextInput) {
        return;
    }
    
    _keyboardInfo = notification.userInfo;
    [self adjustContainerViewOrigin];
}

- (void)keyboardWillHide:(NSNotification *)notification
{
    if (self.style == STPopupStylePopover) {
        return;
    }
    
    _keyboardInfo = nil;
    
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve = [notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] intValue];
    
    [UIView beginAnimations:nil context:NULL];
    [UIView setAnimationBeginsFromCurrentState:YES];
    [UIView setAnimationCurve:curve];
    [UIView setAnimationDuration:duration];
    
    _containerView.transform = CGAffineTransformIdentity;
    
    [UIView commitAnimations];
}

- (void)adjustContainerViewOrigin
{
    if (!_keyboardInfo) {
        return;
    }
    
    UIView<UIKeyInput> *currentTextInput = [self getCurrentTextInputInView:_containerView];
    if (!currentTextInput) {
        return;
    }
    
    CGAffineTransform lastTransform = _containerView.transform;
    _containerView.transform = CGAffineTransformIdentity; // Set transform to identity for calculating a correct "minOffsetY"
    
    CGFloat textFieldBottomY = [currentTextInput convertPoint:CGPointZero toView:_containerViewController.view].y + currentTextInput.bounds.size.height;
    CGFloat keyboardHeight = [_keyboardInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue].size.height;
    // For iOS 7
    UIInterfaceOrientation orientation = [UIApplication sharedApplication].statusBarOrientation;
    if (NSFoundationVersionNumber <= NSFoundationVersionNumber_iOS_7_1 &&
        (orientation == UIInterfaceOrientationLandscapeLeft || orientation == UIInterfaceOrientationLandscapeRight)) {
        keyboardHeight = [_keyboardInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue].size.width;
    }
    
    CGFloat offsetY = 0;
    if (self.style == STPopupStyleBottomSheet) {
        offsetY = keyboardHeight;
    }
    else {
        CGFloat spacing = 5;
        offsetY = _containerView.frame.origin.y + _containerView.bounds.size.height - (_containerViewController.view.bounds.size.height - keyboardHeight - spacing);
        if (offsetY <= 0) { // _containerView can be totally shown, so no need to reposition
            return;
        }
        
        CGFloat statusBarHeight = [UIApplication sharedApplication].statusBarFrame.size.height;
        
        if (_containerView.frame.origin.y - offsetY < statusBarHeight) { // _containerView will be covered by status bar if it is repositioned with "offsetY"
            offsetY = _containerView.frame.origin.y - statusBarHeight;
            // currentTextField can not be totally shown if _containerView is going to repositioned with "offsetY"
            if (textFieldBottomY - offsetY > _containerViewController.view.bounds.size.height - keyboardHeight - spacing) {
                offsetY = textFieldBottomY - (_containerViewController.view.bounds.size.height - keyboardHeight - spacing);
            }
        }
    }
    
    NSTimeInterval duration = [_keyboardInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve = [_keyboardInfo[UIKeyboardAnimationCurveUserInfoKey] intValue];
    
    _containerView.transform = lastTransform; // Restore transform
    
    [UIView beginAnimations:nil context:NULL];
    [UIView setAnimationBeginsFromCurrentState:YES];
    [UIView setAnimationCurve:curve];
    [UIView setAnimationDuration:duration];
    
    _containerView.transform = CGAffineTransformMakeTranslation(0, -offsetY);
    
    [UIView commitAnimations];
}

- (UIView<UIKeyInput> *)getCurrentTextInputInView:(UIView *)view
{
    if ([view conformsToProtocol:@protocol(UIKeyInput)] && view.isFirstResponder) {
        return (UIView<UIKeyInput> *)view;
    }
    
    for (UIView *subview in view.subviews) {
        UIView<UIKeyInput> *view = [self getCurrentTextInputInView:subview];
        if (view) {
            return view;
        }
    }
    return nil;
}

#pragma mark - STPopupFirstResponderDidChangeNotification

- (void)firstResponderDidChange
{
    // "keyboardWillShow" won't be called if height of keyboard is not changed
    // Manually adjust container view origin according to last keyboard info
    [self adjustContainerViewOrigin];
}

#pragma mark - UIViewControllerTransitioningDelegate

- (id <UIViewControllerAnimatedTransitioning>)animationControllerForPresentedController:(UIViewController *)presented presentingController:(UIViewController *)presenting sourceController:(UIViewController *)source
{
    return self;
}

- (id<UIViewControllerAnimatedTransitioning>)animationControllerForDismissedController:(UIViewController *)dismissed
{
    return self;
}

#pragma mark - UIViewControllerAnimatedTransitioning

- (NSTimeInterval)transitionDuration:(id <UIViewControllerContextTransitioning>)transitionContext
{
    UIViewController *toViewController = [transitionContext viewControllerForKey:UITransitionContextToViewControllerKey];
    if (toViewController == _containerViewController) {
        if (self.style == STPopupStylePopover) {
            return 0.5;
        }
        return self.transitionStyle == STPopupTransitionStyleFade ? 0.25 : 0.5;
    }
    else {
        if (self.style == STPopupStylePopover) {
            return 0.15;
        }
        return self.transitionStyle == STPopupTransitionStyleFade ? 0.2 : 0.35;
    }
}

// TODO (kevin) delegate out transition logic so that it won't have so many if-else.
- (void)animateTransition:(id <UIViewControllerContextTransitioning>)transitionContext
{
    UIViewController *fromViewController = [transitionContext viewControllerForKey:UITransitionContextFromViewControllerKey];
    UIViewController *toViewController = [transitionContext viewControllerForKey:UITransitionContextToViewControllerKey];
    
    toViewController.view.frame = fromViewController.view.frame;
    
    UIViewController *topViewController = self.topViewController;
    
    if (toViewController == _containerViewController) { // Presenting
        [fromViewController beginAppearanceTransition:NO animated:YES];
        
        [[transitionContext containerView] addSubview:toViewController.view];
        
        [topViewController beginAppearanceTransition:YES animated:YES];
        [toViewController addChildViewController:topViewController];
        
        [self layoutContainerView];
        [_contentView addSubview:topViewController.view];
        [toViewController setNeedsStatusBarAppearanceUpdate];
        [self updateNavigationBarAniamted:NO];
        
        CGAffineTransform lastTransform = _containerView.transform;
        _containerView.transform = CGAffineTransformIdentity; // Set transform to identity for getting a correct origin.y
        
        CGFloat originY = _containerView.frame.origin.y;
        
        _containerView.transform = lastTransform;
        
        if (self.style != STPopupStylePopover) {
            switch (self.transitionStyle) {
                case STPopupTransitionStyleFade: {
                    _containerView.alpha = 0;
                    _containerView.transform = CGAffineTransformMakeScale(1.05, 1.05);
                }
                    break;
                case STPopupTransitionStyleSlideVertical:
                default: {
                    _containerView.alpha = 1;
                    _containerView.transform = CGAffineTransformMakeTranslation(0, _containerViewController.view.bounds.size.height - originY);
                }
                    break;
            }
        }
        else { // "transitionStyle" will be ignored if style is "STPopupStylePopover"
            _containerView.alpha = 1;
            _containerView.transform = CGAffineTransformMakeScale(0.01, 0.01);
        }
        
        CGFloat lastBackgroundViewAlpha = _backgroundView.alpha;
        _backgroundView.alpha = 0;
        _backgroundView.userInteractionEnabled = NO;
        _containerView.userInteractionEnabled = NO;
        
        void (^animationBlock)() = ^{
            _backgroundView.alpha = lastBackgroundViewAlpha;
            _containerView.alpha = 1;
            _containerView.transform = CGAffineTransformIdentity;
        };
        void (^completionBlock)(BOOL) = ^(BOOL finished){
            _backgroundView.userInteractionEnabled = YES;
            _containerView.userInteractionEnabled = YES;
            
            [transitionContext completeTransition:![transitionContext transitionWasCancelled]];
            [topViewController didMoveToParentViewController:toViewController];
            [fromViewController endAppearanceTransition];
        };
        
        switch (self.transitionStyle) {
            case STPopupTransitionStyleFade:
                [UIView animateWithDuration:[self transitionDuration:transitionContext] delay:0 options:UIViewAnimationOptionCurveEaseOut animations:animationBlock completion:completionBlock];
                break;
            case STPopupTransitionStyleSlideVertical:
                [UIView animateWithDuration:[self transitionDuration:transitionContext] delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0 options:UIViewAnimationOptionCurveEaseOut animations:animationBlock completion:completionBlock];
                break;
            default:
                break;
        }
    }
    else { // Dismissing
        [toViewController beginAppearanceTransition:YES animated:YES];
        
        [topViewController beginAppearanceTransition:NO animated:YES];
        [topViewController willMoveToParentViewController:nil];
        
        CGAffineTransform lastTransform = _containerView.transform;
        _containerView.transform = CGAffineTransformIdentity; // Set transform to identity for getting a correct origin.y
        
        CGFloat originY = _containerView.frame.origin.y;
        
        _containerView.transform = lastTransform;
        
        CGFloat lastBackgroundViewAlpha = _backgroundView.alpha;
        _backgroundView.userInteractionEnabled = NO;
        _containerView.userInteractionEnabled = NO;
        [UIView animateWithDuration:[self transitionDuration:transitionContext] delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            _backgroundView.alpha = 0;
            if (self.style != STPopupStylePopover) {
                switch (self.transitionStyle) {
                    case STPopupTransitionStyleFade: {
                        _containerView.alpha = 0;
                    }
                        break;
                    case STPopupTransitionStyleSlideVertical:
                    default: {
                        _containerView.transform = CGAffineTransformMakeTranslation(0, _containerViewController.view.bounds.size.height - originY +
                                                                                    _containerView.frame.size.height);
                    }
                        break;
                }
            }
            else {
                _containerView.transform = CGAffineTransformMakeScale(0.01, 0.01);
            }
        } completion:^(BOOL finished) {
            _backgroundView.userInteractionEnabled = YES;
            _containerView.userInteractionEnabled = YES;
            _containerView.transform = CGAffineTransformIdentity;
            [fromViewController.view removeFromSuperview];
            [transitionContext completeTransition:![transitionContext transitionWasCancelled]];
            
            [topViewController.view removeFromSuperview];
            [topViewController removeFromParentViewController];
    
            [toViewController endAppearanceTransition];
            
            _backgroundView.alpha = lastBackgroundViewAlpha;
        }];
    }
}

#pragma mark - STPopupNavigationTouchEventDelegate

- (void)popupNavigationBar:(STPopupNavigationBar *)navigationBar touchDidMoveWithOffset:(CGFloat)offset
{
    if (self.style == STPopupStylePopover) {
        return;
    }
    
    [_containerView endEditing:YES];
    if (self.style == STPopupStyleBottomSheet && offset < -STPopupBottomSheetExtraHeight) {
        return;
    }
    _containerView.transform = CGAffineTransformMakeTranslation(0, offset);
}

- (void)popupNavigationBar:(STPopupNavigationBar *)navigationBar touchDidEndWithOffset:(CGFloat)offset
{
    if (offset > 150) {
        STPopupTransitionStyle transitionStyle = self.transitionStyle;
        self.transitionStyle = STPopupTransitionStyleSlideVertical;
        [self dismissWithCompletion:^{
            self.transitionStyle = transitionStyle;
        }];
    }
    else {
        [_containerView endEditing:YES];
        [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            _containerView.transform = CGAffineTransformIdentity;
        } completion:nil];
    }
}

@end
