/* The app's own menu (ADR 0011): a button in the top right corner over the
 * game opens it. Control style, the on-screen pad's look, the screen
 * layout (the split screen in portrait), the saves in iCloud.
 *
 * Settings are kept in NSUserDefaults. At launch they become the runtime's
 * switches (RECOMP_TOUCH_PAD*, RECOMP_SCREEN_SPLIT) before the game reads
 * them, without overwriting any already set, and the settings file in
 * Documents (<app>_env.txt, src/ios_host.c) still has the last word; a
 * change in the menu applies at once (xbox_touchpad_configure,
 * xbox_screen_split_mode).
 *
 * MC3_MENU_OPEN=1 opens the menu by itself once the button is up, and
 * MC3_ORIENTATION=portrait turns the app upright (for screenshots of a
 * simulator nobody taps or turns).
 *
 * The same file reports the hinge of a foldable to the runtime
 * (UIHingeInteraction, iOS 27.1; xboxrecomp/src/input/screen_split.c). */
#import <UIKit/UIKit.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

void xbox_touchpad_configure(int mode, int stick_pedals, int swap_ab, float alpha, float scale);
void xbox_screen_split_mode(int mode);
void xbox_screen_hinge(int status);
/* CloudSaves.m */
NSString *MC3CloudStatus(void);
BOOL MC3CloudSavesEnabled(void);
void MC3CloudSavesSetEnabled(BOOL on);
void MC3CloudSyncNow(void);

/* ── Settings ─────────────────────────────────────────────────────────── */

typedef NS_ENUM(NSInteger, MC3ControlStyle) {
    MC3ControlPad = 0,          /* the on-screen pad; the stick's up/down also gas/brake */
    MC3ControlPadTriggers = 1,  /* the on-screen pad; gas and brake on RT/LT only */
    MC3ControlController = 2,   /* no on-screen pad */
};

typedef NS_ENUM(NSInteger, MC3Layout) {
    MC3LayoutAuto = 0,          /* split in portrait */
    MC3LayoutSplit = 1,
    MC3LayoutOverlay = 2,
};

static NSString *const kStyle = @"controlStyle", *const kSwapAB = @"swapAB",
                *const kOpacity = @"padOpacity", *const kSize = @"padSize",
                *const kLayout = @"screenLayout";

static NSUserDefaults *defaults(void)
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d registerDefaults:@{ kStyle: @(MC3ControlPad), kSwapAB: @NO, kOpacity: @0.55,
                           kSize: @1.0, kLayout: @(MC3LayoutAuto) }];
    return d;
}

/* What the runtime does with the settings, at once. */
static void apply_settings(void)
{
    NSUserDefaults *d = defaults();
    NSInteger style = [d integerForKey:kStyle], layout = [d integerForKey:kLayout];
    xbox_touchpad_configure(style == MC3ControlController ? 0 : -1,
                            style == MC3ControlPad, [d boolForKey:kSwapAB],
                            [d floatForKey:kOpacity], [d floatForKey:kSize]);
    xbox_screen_split_mode(layout == MC3LayoutSplit ? 1 : layout == MC3LayoutOverlay ? 0 : -1);
}

/* The same, as the switches the runtime reads at boot (none overwritten). */
static void settings_to_env(void)
{
    NSUserDefaults *d = defaults();
    NSInteger style = [d integerForKey:kStyle], layout = [d integerForKey:kLayout];
    if (style == MC3ControlController)
        setenv("RECOMP_TOUCH_PAD", "0", 0);
    setenv("RECOMP_TOUCH_PAD_STICK_PEDALS", style == MC3ControlPad ? "1" : "0", 0);
    setenv("RECOMP_TOUCH_PAD_SWAP_AB", [d boolForKey:kSwapAB] ? "1" : "0", 0);
    setenv("RECOMP_TOUCH_PAD_ALPHA", [NSString stringWithFormat:@"%.2f", [d floatForKey:kOpacity]].UTF8String, 0);
    setenv("RECOMP_TOUCH_PAD_SCALE", [NSString stringWithFormat:@"%.2f", [d floatForKey:kSize]].UTF8String, 0);
    if (layout != MC3LayoutAuto)
        setenv("RECOMP_SCREEN_SPLIT", layout == MC3LayoutSplit ? "1" : "0", 0);
}

/* ── A list to pick one from ──────────────────────────────────────────── */

@interface MC3PickController : UITableViewController
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSArray<NSString *> *choices;
@property (nonatomic, copy) NSArray<NSString *> *notes;
@end

@implementation MC3PickController

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)self.choices.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip
{
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                reuseIdentifier:nil];
    c.textLabel.text = self.choices[(NSUInteger)ip.row];
    c.detailTextLabel.text = self.notes[(NSUInteger)ip.row];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.detailTextLabel.numberOfLines = 0;
    c.accessoryType = [defaults() integerForKey:self.key] == ip.row
                          ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip
{
    [defaults() setInteger:ip.row forKey:self.key];
    apply_settings();
    [tv reloadData];
    [self.navigationController popViewControllerAnimated:YES];
}

@end

/* ── The menu ─────────────────────────────────────────────────────────── */

enum { SecControls, SecScreen, SecSaves, SecAbout, SecCount };

@interface MC3MenuController : UITableViewController
@end

@implementation MC3MenuController

static NSArray<NSString *> *style_names(void)
{
    return @[ @"On-screen pad", @"On-screen pad, triggers only", @"Hide on-screen pad" ];
}

static NSArray<NSString *> *layout_names(void)
{
    return @[ @"Automatic", @"Split", @"Full screen" ];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Menu";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(done)];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)done
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv
{
    return SecCount;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s
{
    return @[ @"Controls", @"Screen", @"Saves", @"About" ][(NSUInteger)s];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s
{
    if (s == SecControls)
        return @"As on the Xbox: RT gas, LT brake, A handbrake, B weight transfer, X nitrous, "
               @"Y look back, LS (the stick's click) special move, WHITE headlights, BLACK camera.";
    if (s == SecScreen)
        return @"Split puts the game in the top half and the controls in the bottom half, "
               @"for a foldable held half folded. Automatic splits whenever the phone is upright.";
    if (s == SecSaves)
        return @"Your career profiles go to iCloud as the game saves them, and come back on "
               @"any iPhone or iPad signed in to the same account, the next time the game starts. "
               @"The newest copy wins; the one it replaces is kept in Files › save-backup.";
    return nil;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s
{
    switch (s) {
    case SecControls: return 4;
    case SecScreen:   return 1;
    case SecSaves:    return 3;
    default:          return 2;
    }
}

- (UITableViewCell *)valueCell:(NSString *)title value:(NSString *)value
{
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                                reuseIdentifier:nil];
    c.textLabel.text = title;
    c.detailTextLabel.text = value;
    return c;
}

- (UITableViewCell *)sliderCell:(NSString *)title key:(NSString *)key
                            min:(float)lo max:(float)hi tag:(NSInteger)tag
{
    UITableViewCell *c = [self valueCell:title value:nil];
    UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 180, 30)];
    sl.minimumValue = lo;
    sl.maximumValue = hi;
    sl.value = [defaults() floatForKey:key];
    sl.tag = tag;
    [sl addTarget:self action:@selector(slid:) forControlEvents:UIControlEventValueChanged];
    c.accessoryView = sl;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip
{
    NSUserDefaults *d = defaults();
    UITableViewCell *c;
    if (ip.section == SecControls) {
        switch (ip.row) {
        case 0:
            c = [self valueCell:@"Control style"
                          value:style_names()[(NSUInteger)[d integerForKey:kStyle]]];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        case 1: {
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [d boolForKey:kSwapAB];
            [sw addTarget:self action:@selector(swapped:) forControlEvents:UIControlEventValueChanged];
            c = [self valueCell:@"Swap A and B" value:nil];
            c.accessoryView = sw;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            return c;
        }
        case 2:
            return [self sliderCell:@"Pad opacity" key:kOpacity min:0.15f max:1.0f tag:0];
        default:
            return [self sliderCell:@"Pad size" key:kSize min:0.6f max:1.6f tag:1];
        }
    }
    if (ip.section == SecScreen) {
        c = [self valueCell:@"Layout" value:layout_names()[(NSUInteger)[d integerForKey:kLayout]]];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    if (ip.section == SecSaves) {
        if (ip.row == 0) {
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = MC3CloudSavesEnabled();
            [sw addTarget:self action:@selector(cloudSwitched:) forControlEvents:UIControlEventValueChanged];
            c = [self valueCell:@"iCloud saves" value:nil];
            c.accessoryView = sw;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (ip.row == 1) {
            c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
            c.textLabel.text = @"Status";
            c.detailTextLabel.text = MC3CloudStatus();
            c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
            c.detailTextLabel.numberOfLines = 0;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            c = [self valueCell:@"Sync now" value:nil];
            c.textLabel.textColor = MC3CloudSavesEnabled() ? self.view.tintColor : UIColor.secondaryLabelColor;
        }
        return c;
    }
    {
        NSBundle *b = [NSBundle mainBundle];
        if (ip.row == 0)
            c = [self valueCell:@"Version"
                          value:[NSString stringWithFormat:@"%@ (%@)",
                                 [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
                                 [b objectForInfoDictionaryKey:@"CFBundleVersion"]]];
        else
            c = [self valueCell:@"Game files" value:@"Files › On My iPhone"];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip
{
    MC3PickController *p;
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == SecControls && ip.row == 0) {
        p = [[MC3PickController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        p.title = @"Control style";
        p.key = kStyle;
        p.choices = style_names();
        p.notes = @[ @"Stick and d-pad, buttons, LT/RT/LS. The stick's up and down also work as gas and brake.",
                     @"The same pad; gas and brake on RT and LT only, the stick only steers.",
                     @"Hides the on-screen pad." ];
    } else if (ip.section == SecSaves && ip.row == 2 && MC3CloudSavesEnabled()) {
        MC3CloudSyncNow();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [tv reloadSections:[NSIndexSet indexSetWithIndex:SecSaves]
              withRowAnimation:UITableViewRowAnimationNone];
        });
        return;
    } else if (ip.section == SecScreen) {
        p = [[MC3PickController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        p.title = @"Layout";
        p.key = kLayout;
        p.choices = layout_names();
        p.notes = @[ @"Split when the phone is upright, full screen in landscape.",
                     @"Always the game in the top half, the controls in the bottom half.",
                     @"Always the whole screen, the controls over the game." ];
    } else {
        return;
    }
    [self.navigationController pushViewController:p animated:YES];
}

- (void)cloudSwitched:(UISwitch *)sw
{
    MC3CloudSavesSetEnabled(sw.on);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:SecSaves]
                      withRowAnimation:UITableViewRowAnimationNone];
    });
}

- (void)swapped:(UISwitch *)sw
{
    [defaults() setBool:sw.on forKey:kSwapAB];
    apply_settings();
}

- (void)slid:(UISlider *)sl
{
    [defaults() setFloat:sl.value forKey:sl.tag == 0 ? kOpacity : kSize];
    apply_settings();
}

@end

/* The menu over a view controller (the game's, or the welcome screen's). */
void MC3OpenMenu(UIViewController *from)
{
    UINavigationController *nav;
    if (!from || from.presentedViewController)
        return;
    nav = [[UINavigationController alloc] initWithRootViewController:
              [[MC3MenuController alloc] initWithStyle:UITableViewStyleInsetGrouped]];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [from presentViewController:nav animated:YES completion:nil];
}

/* ── The button, the hinge ────────────────────────────────────────────── */

@interface MC3GameMenu : NSObject
@end

@implementation MC3GameMenu

static UIButton *s_button;

+ (void)load
{
    settings_to_env();
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sceneActive:)
                                                 name:UISceneDidActivateNotification object:nil];
}

/* The button goes on SDL's view once it is there (the game's window comes
 * after the scene and the welcome screen), and again whenever that view is
 * replaced. */
+ (void)sceneActive:(NSNotification *)n
{
    static BOOL started;
    if (started)
        return;
    started = YES;
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        UIWindowScene *scene = [n.object isKindOfClass:[UIWindowScene class]] ? n.object : nil;
        UIWindow *w = nil;
        UIView *v;
        for (UIWindow *x in scene.windows)            /* the game's: SDL's window */
            if ([NSStringFromClass([x.rootViewController class]) hasPrefix:@"SDL"])
                w = x;
        v = w.rootViewController.view;
        if (!v || s_button.superview == v)
            return;
        [self attachTo:v window:w];
    }];
}

+ (void)attachTo:(UIView *)v window:(UIWindow *)w
{
    if (!s_button) {
        UIButtonConfiguration *cfg = [UIButtonConfiguration grayButtonConfiguration];
        cfg.image = [UIImage systemImageNamed:@"line.3.horizontal"];
        cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        s_button = [UIButton buttonWithConfiguration:cfg primaryAction:
            [UIAction actionWithHandler:^(UIAction *a) { [MC3GameMenu open]; }]];
        s_button.alpha = 0.45;
        s_button.accessibilityLabel = @"Menu";
        s_button.translatesAutoresizingMaskIntoConstraints = NO;
    }
    [s_button removeFromSuperview];
    [v addSubview:s_button];
    [NSLayoutConstraint activateConstraints:@[
        [s_button.topAnchor constraintEqualToAnchor:v.safeAreaLayoutGuide.topAnchor constant:8],
        [s_button.trailingAnchor constraintEqualToAnchor:v.safeAreaLayoutGuide.trailingAnchor constant:-8],
        [s_button.widthAnchor constraintEqualToConstant:44],
        [s_button.heightAnchor constraintEqualToConstant:44],
    ]];
    [self watchHinge:w];
    if (getenv("MC3_ORIENTATION") && !strcmp(getenv("MC3_ORIENTATION"), "portrait")) {
        UIWindowSceneGeometryPreferencesIOS *g = [[UIWindowSceneGeometryPreferencesIOS alloc]
            initWithInterfaceOrientations:UIInterfaceOrientationMaskPortrait];
        [w.windowScene requestGeometryUpdateWithPreferences:g errorHandler:^(NSError *e) {
            fprintf(stderr, "[ios] portrait: %s\n", e.localizedDescription.UTF8String);
        }];
    }
    if (getenv("MC3_MENU_OPEN") && *getenv("MC3_MENU_OPEN") == '1')
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ [MC3GameMenu open]; });
}

+ (void)open
{
    MC3OpenMenu(s_button.window.rootViewController);
}

+ (void)watchHinge:(UIWindow *)w
{
    static BOOL watching;
    if (watching || !w)
        return;
    watching = YES;
    if (@available(iOS 27.1, *)) {
        UIHingeInteraction *hi = [[UIHingeInteraction alloc] initWithUpdateHandler:
            ^(UIHingeInteraction *i, UIHingeInteractionUpdate *u) {
                int st = u.hinge ? (int)u.hinge.status : 0;
                xbox_screen_hinge(st);
                fprintf(stderr, "[ios] hinge: status %d, angle %.0f deg\n", st,
                        u.hinge ? u.hinge.angle * 180.0 / M_PI : 0.0);
            }];
        [w addInteraction:hi];
    }
}

@end
