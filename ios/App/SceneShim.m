/* UIScene lifecycle for SDL2 (ADR 0011). Apps built with the iOS 27 SDK
 * must adopt scenes or UIKit stops them at launch (SIGTRAP in
 * _UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption). SDL2's
 * UIKit backend predates scenes: it makes its windows with initWithFrame:
 * and never gives them a windowScene, so they would not be shown.
 *
 * Info.plist (project.yml) declares one window scene with MC3SceneDelegate.
 * When the scene connects, every window made so far is moved into it, and
 * from then on every new UIWindow joins it as it is created. SDL's own code
 * is left as it is. */
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static UIWindowScene *s_scene;
static IMP s_init_with_frame;
/* Windows made before the scene connected. UIApplication.windows leaves
 * windows without a scene out, so they are kept here (weakly) instead. */
static NSHashTable<UIWindow *> *s_early;

static id mc3_window_init_with_frame(id self, SEL cmd, CGRect frame)
{
    self = ((id (*)(id, SEL, CGRect))s_init_with_frame)(self, cmd, frame);
    if (!self)
        return self;
    if (s_scene) {
        ((UIWindow *)self).windowScene = s_scene;
    } else {
        if (!s_early)
            s_early = [NSHashTable weakObjectsHashTable];
        [s_early addObject:(UIWindow *)self];
    }
    return self;
}

static void mc3_log_views(UIView *v, int depth)
{
    if (depth > 6)
        return;
    fprintf(stderr, "[ios] %*s%s %s%s alpha %.2f layer %s\n", depth * 2 + 2, "",
            class_getName([v class]), NSStringFromCGRect(v.frame).UTF8String,
            v.hidden ? " hidden" : "", v.alpha, class_getName([v.layer class]));
    for (UIView *s in v.subviews)
        mc3_log_views(s, depth + 1);
}

static void mc3_log_windows(int64_t secs)
{
    fprintf(stderr, "[ios] windows after %lld s (scene %p):\n", (long long)secs, (__bridge void *)s_scene);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
#pragma clang diagnostic pop
        fprintf(stderr, "[ios]  %s level %.0f%s%s scene %p root %s\n",
                class_getName([w class]), w.windowLevel, w.hidden ? " hidden" : "",
                w.isKeyWindow ? " key" : "", (__bridge void *)w.windowScene,
                w.rootViewController ? class_getName([w.rootViewController class]) : "-");
        mc3_log_views(w, 1);
    }
    for (UIWindow *w in s_scene.windows)
        fprintf(stderr, "[ios]  in scene: %s level %.0f%s alpha %.2f\n", class_getName([w class]),
                w.windowLevel, w.hidden ? " hidden" : "", w.alpha);
}

/* Fit every window of the scene, and SDL's GL view in it, to the scene as
 * it is now: a foldable moves the scene between its inner and outer
 * screens (other size, maybe another scale), and SDL's window was made
 * with a fixed frame for the screen it started on. The GL view's
 * layoutSubviews then has the drawable resized on the renderer's thread
 * (GLSwapFix.m). Logged, so a fold can be followed in the log. */
static void mc3_fit_windows(UIWindowScene *ws, const char *why)
{
    CGRect b = ws.coordinateSpace.bounds;
    UIScreen *scr = ws.screen;
    fprintf(stderr, "[ios] fit (%s): scene %.0fx%.0f, screen %.0fx%.0f scale %.2f native %.2f, "
            "orientation %ld\n", why, b.size.width, b.size.height, scr.bounds.size.width,
            scr.bounds.size.height, scr.scale, scr.nativeScale, (long)ws.effectiveGeometry.interfaceOrientation);
    for (UIWindow *w in ws.windows) {
        UIView *v = w.rootViewController.view;
        BOOL gl = [NSStringFromClass([v class]) isEqualToString:@"SDL_uikitopenglview"];
        CGRect wf = w.frame, vf = v.frame;
        if (!CGRectEqualToRect(w.frame, b))
            w.frame = b;
        if (v && !CGRectEqualToRect(v.frame, w.bounds))
            v.frame = w.bounds;
        if (gl && scr.nativeScale > 0 && v.contentScaleFactor != scr.nativeScale)
            v.contentScaleFactor = scr.nativeScale;
        if (gl) {
            [v endEditing:YES];             /* SDL's text field: no keyboard */
            [v setNeedsLayout];
            [v layoutIfNeeded];
        }
        fprintf(stderr, "[ios]   %s: window %.0fx%.0f at %.0f,%.0f -> %.0fx%.0f; view %.0fx%.0f -> %.0fx%.0f "
                "(x%.2f, safe area l%.0f t%.0f r%.0f b%.0f)%s\n", class_getName([w class]), wf.size.width,
                wf.size.height, wf.origin.x, wf.origin.y, w.frame.size.width, w.frame.size.height,
                vf.size.width, vf.size.height, v.frame.size.width, v.frame.size.height, v.contentScaleFactor,
                v.safeAreaInsets.left, v.safeAreaInsets.top, v.safeAreaInsets.right,
                v.safeAreaInsets.bottom, gl ? " GL" : "");
    }
}

@interface MC3SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation MC3SceneDelegate

+ (void)load
{
    Method m = class_getInstanceMethod([UIWindow class], @selector(initWithFrame:));
    s_init_with_frame = method_setImplementation(m, (IMP)mc3_window_init_with_frame);
    /* A keyboard coming up for SDL's hidden text field (iOS gives it first
     * responder back after a fold) goes straight down again: the game takes
     * no text. */
    [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillShowNotification
                                                      object:nil queue:nil
                                                  usingBlock:^(NSNotification *n) {
        for (UIWindow *w in s_scene.windows)
            if ([NSStringFromClass([w.rootViewController.view class]) isEqualToString:@"SDL_uikitopenglview"]
                    && [w.rootViewController.view endEditing:YES])
                fprintf(stderr, "[ios] keyboard for SDL's text field: dismissed\n");
    }];
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)options
{
    if (![scene isKindOfClass:[UIWindowScene class]])
        return;
    s_scene = (UIWindowScene *)scene;
    /* Windows SDL made before the scene connected: the game's window if
     * SDL_main got there first, and SDL's own launch screen
     * (SDL_uikitappdelegate.m, SDL_IPHONE_LAUNCHSCREEN): a window one level
     * above normal with a blank view, meant to fade out on the next run-loop
     * turn. Attached to the scene it covered the game for good (black screen
     * on the device with the intro movies' sound playing), so it is hidden
     * here instead; the game's window is the only one that joins the scene.
     * They come from s_early: UIApplication.windows leaves out windows
     * without a scene, so a game window made first was never attached. */
    for (UIWindow *w in s_early) {
        if (w.windowScene)
            continue;
        if (w.windowLevel > UIWindowLevelNormal) {
            w.hidden = YES;
            continue;
        }
        w.windowScene = s_scene;
    }
    s_early = nil;
    self.window = s_scene.windows.lastObject;
    /* The windows on screen, in the log: what covers the game's view, if
     * anything does. */
    for (int64_t secs = 3; secs <= 10; secs += 7)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, secs * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ mc3_log_windows(secs); });
}

/* Rotation, and a move between a foldable's screens. */
- (void)windowScene:(UIWindowScene *)ws
    didUpdateCoordinateSpace:(id<UICoordinateSpace>)previous
        interfaceOrientation:(UIInterfaceOrientation)orientation
             traitCollection:(UITraitCollection *)traits
{
    CGRect p = previous.bounds;
    char why[64];
    snprintf(why, sizeof why, "was %.0fx%.0f", p.size.width, p.size.height);
    mc3_fit_windows(ws, why);
}

- (void)sceneDidBecomeActive:(UIScene *)scene
{
    if ([scene isKindOfClass:[UIWindowScene class]])
        mc3_fit_windows((UIWindowScene *)scene, "active");
}

@end
