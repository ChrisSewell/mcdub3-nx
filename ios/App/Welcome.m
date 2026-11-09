/* The app's welcome and loading screens (ADR 0011).
 *
 * ios_welcome (from ios_boot, src/ios_host.c, on the main thread before
 * the game starts) shows the welcome screen in a window of its own: the
 * game, the disc found, Play and Settings; without a disc, how to add one
 * (checked again every two seconds). It turns the run loop until Play is
 * pressed, then leaves MC3_GAME_DIR set to the disc and puts up the
 * loading screen, a window above the game's that goes when the renderer
 * presents the title's first frame (nv2a_gl_first_frame), or after 90 s.
 *
 * MC3_AUTOPLAY=1 presses Play by itself when the disc is there
 * (unattended simulator runs).
 *
 * The disc is looked for as ios_host.c does: MC3_GAME_DIR, else
 * Documents/game-usa, game-eur, game, then any game-<edition>/ holding
 * default.xbe. */
#import <UIKit/UIKit.h>
#include <stdlib.h>

void MC3OpenMenu(UIViewController *from);      /* GameMenu.m */
BOOL MC3CloudSavesEnabled(void);                /* CloudSaves.m */

static UIWindow *s_window;                      /* welcome, then loading */
static BOOL s_play;

/* ── The disc ─────────────────────────────────────────────────────────── */

static NSString *documents(void)
{
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
}

static BOOL has_disc(NSString *dir)
{
    return [[NSFileManager defaultManager]
        isReadableFileAtPath:[dir stringByAppendingPathComponent:@"default.xbe"]];
}

static NSString *find_disc(void)
{
    const char *env = getenv("MC3_GAME_DIR");
    NSString *docs = documents();
    if (env && *env)
        return has_disc(@(env)) ? @(env) : nil;
    for (NSString *n in @[ @"game-usa", @"game-eur", @"game" ]) {
        NSString *p = [docs stringByAppendingPathComponent:n];
        if (has_disc(p))
            return p;
    }
    for (NSString *n in [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:docs error:nil]
                            sortedArrayUsingSelector:@selector(compare:)])
        if ([n hasPrefix:@"game-"] && has_disc([docs stringByAppendingPathComponent:n]))
            return [docs stringByAppendingPathComponent:n];
    return nil;
}

static NSString *edition_name(NSString *disc)
{
    NSString *n = disc.lastPathComponent.lowercaseString;
    if ([n isEqualToString:@"game-usa"]) return @"USA disc";
    if ([n isEqualToString:@"game-eur"]) return @"European disc";
    return @"Disc";
}

/* ── Look ─────────────────────────────────────────────────────────────── */

@interface MC3NightView : UIView
@end

@implementation MC3NightView

+ (Class)layerClass
{
    return [CAGradientLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        CAGradientLayer *g = (CAGradientLayer *)self.layer;
        g.colors = @[ (id)[UIColor colorWithRed:0.07 green:0.09 blue:0.20 alpha:1].CGColor,
                      (id)[UIColor colorWithRed:0.02 green:0.02 blue:0.05 alpha:1].CGColor ];
        g.startPoint = CGPointMake(0.5, 0);
        g.endPoint = CGPointMake(0.5, 1);
    }
    return self;
}

@end

static UILabel *label(NSString *text, UIFont *font, UIColor *color)
{
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = font;
    l.textColor = color;
    l.textAlignment = NSTextAlignmentCenter;
    l.numberOfLines = 0;
    l.adjustsFontForContentSizeCategory = YES;
    return l;
}

static UIFont *title_font(CGFloat size)
{
    UIFont *f = [UIFont systemFontOfSize:size weight:UIFontWeightBlack];
    UIFontDescriptor *d = [f.fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitItalic];
    return d ? [UIFont fontWithDescriptor:d size:size] : f;
}

/* The game's name: the app's display name, "Midnight Club 3 Remix". */
static NSArray<NSString *> *title_lines(void)
{
    NSString *name = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"]
                         ?: @"Midnight Club 3";
    if ([name hasPrefix:@"Midnight Club 3"])
        return @[ @"MIDNIGHT CLUB 3",
                  [name containsString:@"Remix"] ? @"DUB Edition Remix" : @"DUB Edition" ];
    return @[ name.uppercaseString, @"" ];
}

static UIView *accent_line(void)
{
    UIView *v = [[UIView alloc] init];
    CAGradientLayer *g = [CAGradientLayer layer];
    g.colors = @[ (id)UIColor.clearColor.CGColor, (id)UIColor.systemRedColor.CGColor,
                  (id)UIColor.systemOrangeColor.CGColor, (id)UIColor.clearColor.CGColor ];
    g.startPoint = CGPointMake(0, 0.5);
    g.endPoint = CGPointMake(1, 0.5);
    g.frame = CGRectMake(0, 0, 260, 3);
    [v.layer addSublayer:g];
    [v.widthAnchor constraintEqualToConstant:260].active = YES;
    [v.heightAnchor constraintEqualToConstant:3].active = YES;
    return v;
}

/* ── Welcome ──────────────────────────────────────────────────────────── */

@interface MC3WelcomeController : UIViewController
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UIView *ready, *missing;
@property (nonatomic, strong) UILabel *discLabel;
@property (nonatomic, strong) NSTimer *poll;
@end

@implementation MC3WelcomeController

- (void)loadView
{
    self.view = [[MC3NightView alloc] initWithFrame:UIScreen.mainScreen.bounds];
}

- (UIStatusBarStyle)preferredStatusBarStyle
{
    return UIStatusBarStyleLightContent;
}

- (BOOL)prefersHomeIndicatorAutoHidden
{
    return YES;
}

- (void)viewDidLoad
{
    UIScrollView *scroll = [[UIScrollView alloc] init];
    NSArray<NSString *> *t = title_lines();
    UILabel *title = label(t[0], title_font(38), UIColor.whiteColor);
    UILabel *sub = label(t[1], [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold],
                         [UIColor colorWithWhite:1 alpha:0.75]);
    [super viewDidLoad];
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.6;
    title.numberOfLines = 1;

    self.stack = [[UIStackView alloc] initWithArrangedSubviews:@[ title, sub, accent_line() ]];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.alignment = UIStackViewAlignmentCenter;
    self.stack.spacing = 10;
    [self.stack setCustomSpacing:28 afterView:self.stack.arrangedSubviews.lastObject];
    self.ready = [self makeReady];
    self.missing = [self makeMissing];
    [self.stack addArrangedSubview:self.ready];
    [self.stack addArrangedSubview:self.missing];

    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = NO;
    [self.view addSubview:scroll];
    [scroll addSubview:self.stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.stack.centerXAnchor constraintEqualToAnchor:scroll.centerXAnchor],
        [self.stack.widthAnchor constraintLessThanOrEqualToConstant:560],
        [self.stack.widthAnchor constraintLessThanOrEqualToAnchor:scroll.widthAnchor constant:-40],
        [self.stack.topAnchor constraintGreaterThanOrEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [self.stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
    ]];
    {
        /* centred while it fits, scrolling when it does not */
        NSLayoutConstraint *mid = [self.stack.centerYAnchor constraintEqualToAnchor:scroll.centerYAnchor];
        mid.priority = UILayoutPriorityDefaultLow;
        mid.active = YES;
        [self.stack.heightAnchor constraintLessThanOrEqualToAnchor:scroll.heightAnchor
                                                          constant:-40].priority = UILayoutPriorityDefaultLow;
    }
    [self refresh];
    self.poll = [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(refresh)
                                               userInfo:nil repeats:YES];
}

- (UIView *)makeReady
{
    UIButtonConfiguration *pc = [UIButtonConfiguration filledButtonConfiguration];
    UIButtonConfiguration *sc = [UIButtonConfiguration plainButtonConfiguration];
    UIButton *play, *settings;
    UIStackView *s;
    NSBundle *b = [NSBundle mainBundle];
    UILabel *foot;

    self.discLabel = label(@"", [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline],
                           [UIColor colorWithWhite:1 alpha:0.7]);

    pc.title = @"Play";
    pc.image = [UIImage systemImageNamed:@"play.fill"];
    pc.imagePadding = 10;
    pc.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    pc.baseBackgroundColor = UIColor.systemRedColor;
    pc.buttonSize = UIButtonConfigurationSizeLarge;
    pc.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *a) {
        NSMutableDictionary *m = [a mutableCopy];
        m[NSFontAttributeName] = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
        return m;
    };
    play = [UIButton buttonWithConfiguration:pc primaryAction:
        [UIAction actionWithHandler:^(UIAction *a) { s_play = YES; }]];
    [play.widthAnchor constraintEqualToConstant:240].active = YES;
    [play.heightAnchor constraintEqualToConstant:58].active = YES;

    sc.title = @"Settings";
    sc.image = [UIImage systemImageNamed:@"gearshape"];
    sc.imagePadding = 6;
    sc.baseForegroundColor = [UIColor colorWithWhite:1 alpha:0.85];
    settings = [UIButton buttonWithConfiguration:sc primaryAction:
        [UIAction actionWithHandler:^(UIAction *a) { MC3OpenMenu(self); }]];

    foot = label([NSString stringWithFormat:@"Version %@ · iCloud saves %@",
                  [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
                  MC3CloudSavesEnabled() ? @"on" : @"off"],
                 [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote],
                 [UIColor colorWithWhite:1 alpha:0.45]);

    s = [[UIStackView alloc] initWithArrangedSubviews:@[ self.discLabel, play, settings, foot ]];
    s.axis = UILayoutConstraintAxisVertical;
    s.alignment = UIStackViewAlignmentCenter;
    s.spacing = 14;
    return s;
}

- (UIView *)makeMissing
{
    UIView *card = [[UIView alloc] init];
    UILabel *head = label(@"Add your game disc", [UIFont systemFontOfSize:20 weight:UIFontWeightBold],
                          UIColor.whiteColor);
    UILabel *body = label(
        @"1. Extract your Xbox disc: the folder of files holding default.xbe, not the .iso.\n"
        @"2. Name the folder game-usa (USA disc) or game-eur (European disc).\n"
        @"3. Copy it into this app: on a Mac, Finder › your iPhone › Files; on the iPhone, "
        @"Files › On My iPhone, then the app's folder.\n\n"
        @"This screen notices the disc by itself.",
        [UIFont preferredFontForTextStyle:UIFontTextStyleBody], [UIColor colorWithWhite:1 alpha:0.8]);
    UIButtonConfiguration *cc = [UIButtonConfiguration tintedButtonConfiguration];
    UIButton *again;
    UIStackView *s;
    body.textAlignment = NSTextAlignmentNatural;
    cc.title = @"Check again";
    cc.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    again = [UIButton buttonWithConfiguration:cc primaryAction:
        [UIAction actionWithHandler:^(UIAction *a) { [self refresh]; }]];
    s = [[UIStackView alloc] initWithArrangedSubviews:@[ head, body, again ]];
    s.axis = UILayoutConstraintAxisVertical;
    s.alignment = UIStackViewAlignmentCenter;
    s.spacing = 14;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    card.layer.cornerRadius = 20;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    [card addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [s.topAnchor constraintEqualToAnchor:card.topAnchor constant:20],
        [s.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-20],
        [s.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [s.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
    ]];
    return card;
}

- (void)refresh
{
    NSString *disc = find_disc();
    self.ready.hidden = disc == nil;
    self.missing.hidden = disc != nil;
    if (disc)
        self.discLabel.text = [NSString stringWithFormat:@"%@ ready", edition_name(disc)];
}

@end

/* ── Loading ──────────────────────────────────────────────────────────── */

@interface MC3LoadingController : UIViewController
@end

@implementation MC3LoadingController

- (void)loadView
{
    self.view = [[MC3NightView alloc] initWithFrame:UIScreen.mainScreen.bounds];
}

- (BOOL)prefersHomeIndicatorAutoHidden
{
    return YES;
}

- (void)viewDidLoad
{
    NSArray<NSString *> *t = title_lines();
    UIActivityIndicatorView *spin =
        [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    UILabel *title = label(t[0], title_font(26), UIColor.whiteColor);
    UILabel *loading = label(@"Loading…", [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline],
                             [UIColor colorWithWhite:1 alpha:0.85]);
    UILabel *tip = label(@"Tip: hold your phone upright to put the game above the controls. "
                         @"The menu is the button in the top right corner.",
                         [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote],
                         [UIColor colorWithWhite:1 alpha:0.5]);
    UIStackView *s;
    [super viewDidLoad];
    spin.color = UIColor.whiteColor;
    [spin startAnimating];
    s = [[UIStackView alloc] initWithArrangedSubviews:@[ title, accent_line(), spin, loading, tip ]];
    s.axis = UILayoutConstraintAxisVertical;
    s.alignment = UIStackViewAlignmentCenter;
    s.spacing = 16;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [s.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [s.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [s.widthAnchor constraintLessThanOrEqualToConstant:460],
        [s.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-48],
    ]];
}

@end

static void loading_done(void)
{
    UIWindow *w = s_window;
    if (!w)
        return;
    s_window = nil;
    for (UIWindow *x in w.windowScene.windows)         /* the game's window takes the keys */
        if ([NSStringFromClass([x.rootViewController class]) hasPrefix:@"SDL"])
            [x makeKeyWindow];
    [UIView animateWithDuration:0.4 animations:^{ w.alpha = 0; }
                     completion:^(BOOL f) { w.hidden = YES; }];
}

/* The renderer's thread, as the title's first frame goes up. */
void nv2a_gl_first_frame(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{ loading_done(); });
}

/* ── From ios_boot ────────────────────────────────────────────────────── */

static UIWindowScene *window_scene(void)
{
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState != UISceneActivationStateUnattached)
            return (UIWindowScene *)s;
    return nil;
}

static void spin_until(BOOL (^done)(void))
{
    while (!done())
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
}

void ios_welcome(void)
{
    __block UIWindowScene *scene = nil;
    NSString *disc;
    MC3WelcomeController *wc;
    spin_until(^BOOL { return (scene = window_scene()) != nil; });

    wc = [[MC3WelcomeController alloc] init];
    s_window = [[UIWindow alloc] initWithWindowScene:scene];
    s_window.windowLevel = UIWindowLevelNormal + 2;
    s_window.rootViewController = wc;
    s_window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [s_window makeKeyAndVisible];

    if (getenv("MC3_AUTOPLAY") && *getenv("MC3_AUTOPLAY") == '1' && find_disc())
        s_play = YES;                                   /* unattended runs */
    spin_until(^BOOL { return s_play && find_disc() != nil; });
    [wc.poll invalidate];
    disc = find_disc();
    setenv("MC3_GAME_DIR", disc.fileSystemRepresentation, 1);
    fprintf(stderr, "[ios] welcome: Play (%s)\n", disc.fileSystemRepresentation);

    /* the loading screen, in the same window, until the first frame */
    s_window.rootViewController = [[MC3LoadingController alloc] init];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC), dispatch_get_main_queue(),
                   ^{ loading_done(); });
}
