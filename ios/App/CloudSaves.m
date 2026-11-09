/* The game's saves in iCloud (ADR 0011): the profiles it writes to
 * Documents/save (UDATA/54540079/..., src/ios_host.c) kept in the app's
 * iCloud container (iCloud Drive, hidden: <container>/save), so they follow
 * the player to another iPhone or iPad.
 *
 *   at launch   before the game reads them (ios_cloud_saves_start, from
 *               ios_boot): every file newer in iCloud is downloaded and
 *               copied in, the local copy first kept in
 *               Documents/save-backup/<date>/
 *   while it runs  every 30 s and when the app leaves the screen: every
 *               file newer here (and settled for 2 s, the game done writing
 *               it) is copied to iCloud
 *
 * The newest copy of a file wins; nothing is deleted on either side. Files
 * are compared by modification time, which a copy carries over, so a file
 * copied one way is not copied straight back. Off in the menu
 * (MC3CloudSavesSetEnabled); without an iCloud account it does nothing.
 *
 * The local folder stays the one the game uses: only the copies go through
 * the container, with NSFileCoordinator, as iCloud Drive asks. */
#import <UIKit/UIKit.h>
#include <stdio.h>

static NSString *const kCloudSaves = @"iCloudSaves";

static NSURL *s_local, *s_cloud;
static dispatch_queue_t s_q;
static NSString *s_status = @"Not started";
static NSTimer *s_timer;

static void set_status(NSString *st)
{
    dispatch_async(dispatch_get_main_queue(), ^{ s_status = st; });
    fprintf(stderr, "[cloud] %s\n", st.UTF8String);
}

static NSString *now_text(void)
{
    return [NSDateFormatter localizedStringFromDate:[NSDate date]
                                          dateStyle:NSDateFormatterNoStyle
                                          timeStyle:NSDateFormatterShortStyle];
}

static NSDate *mtime(NSURL *u)
{
    NSDate *d = nil;
    [u getResourceValue:&d forKey:NSURLContentModificationDateKey error:nil];
    return d;
}

/* Relative paths of the regular files under a folder; an iCloud placeholder
 * (".name.icloud", not downloaded yet) counts as name. */
static NSArray<NSString *> *files_under(NSURL *root, NSMutableSet<NSString *> *placeholders)
{
    NSMutableArray *out = [NSMutableArray array];
    NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtURL:root
        includingPropertiesForKeys:@[ NSURLIsRegularFileKey ] options:0 errorHandler:nil];
    NSString *base = root.path.stringByStandardizingPath;
    for (NSURL *u in en) {
        NSNumber *reg = nil;
        NSString *rel, *name = u.lastPathComponent;
        [u getResourceValue:&reg forKey:NSURLIsRegularFileKey error:nil];
        if (!reg.boolValue)
            continue;
        rel = [u.path.stringByStandardizingPath substringFromIndex:base.length + 1];
        if ([name hasPrefix:@"."] && [name hasSuffix:@".icloud"]) {
            NSString *real = [name substringWithRange:NSMakeRange(1, name.length - 8)];
            rel = [[rel stringByDeletingLastPathComponent] stringByAppendingPathComponent:real];
            [placeholders addObject:rel];
        } else if ([name hasPrefix:@"."]) {
            continue;
        }
        [out addObject:rel];
    }
    return out;
}

/* Copies a file and its modification time, through the coordinator. */
static BOOL copy_file(NSURL *from, NSURL *to, BOOL cloud_side_is_dest)
{
    NSFileCoordinator *fc = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    NSFileManager *fm = [NSFileManager defaultManager];
    __block BOOL ok = NO;
    NSError *err = nil;
    void (^work)(NSURL *, NSURL *) = ^(NSURL *src, NSURL *dst) {
        NSDate *t = mtime(src);
        NSURL *tmp = [[dst URLByDeletingLastPathComponent]
                         URLByAppendingPathComponent:[@".mc3tmp-" stringByAppendingString:dst.lastPathComponent]];
        [fm createDirectoryAtURL:[dst URLByDeletingLastPathComponent]
     withIntermediateDirectories:YES attributes:nil error:nil];
        [fm removeItemAtURL:tmp error:nil];
        if (![fm copyItemAtURL:src toURL:tmp error:nil])
            return;
        if (t)
            [fm setAttributes:@{ NSFileModificationDate: t } ofItemAtPath:tmp.path error:nil];
        ok = [fm replaceItemAtURL:dst withItemAtURL:tmp backupItemName:nil options:0
                 resultingItemURL:nil error:nil]
             || [fm moveItemAtURL:tmp toURL:dst error:nil];
        if (ok && t)
            [fm setAttributes:@{ NSFileModificationDate: t } ofItemAtPath:dst.path error:nil];
    };
    if (cloud_side_is_dest)
        [fc coordinateReadingItemAtURL:from options:0 writingItemAtURL:to
                               options:NSFileCoordinatorWritingForReplacing error:&err
                            byAccessor:^(NSURL *r, NSURL *w) { work(r, w); }];
    else
        [fc coordinateReadingItemAtURL:from options:0 error:&err
                            byAccessor:^(NSURL *r) { work(r, to); }];
    return ok;
}

/* iCloud -> here, before the game starts. */
static void pull(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableSet<NSString *> *pending = [NSMutableSet set];
    NSArray<NSString *> *rels;
    NSURL *backup = nil;
    int copied = 0;
    rels = files_under(s_cloud, pending);
    for (NSString *rel in pending)
        [fm startDownloadingUbiquitousItemAtURL:[s_cloud URLByAppendingPathComponent:rel] error:nil];
    /* a few seconds for what is still in the cloud */
    for (int i = 0; i < 40 && pending.count; i++) {
        for (NSString *rel in pending.allObjects)
            if ([fm fileExistsAtPath:[s_cloud URLByAppendingPathComponent:rel].path])
                [pending removeObject:rel];
        if (pending.count)
            [NSThread sleepForTimeInterval:0.25];
    }
    for (NSString *rel in rels) {
        NSURL *c = [s_cloud URLByAppendingPathComponent:rel], *l = [s_local URLByAppendingPathComponent:rel];
        NSDate *tc, *tl;
        if ([pending containsObject:rel] || ![fm fileExistsAtPath:c.path])
            continue;
        tc = mtime(c);
        tl = [fm fileExistsAtPath:l.path] ? mtime(l) : nil;
        if (tl && (!tc || [tc timeIntervalSinceDate:tl] <= 1.0))
            continue;
        if (tl) {
            if (!backup) {
                NSDateFormatter *f = [[NSDateFormatter alloc] init];
                f.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
                backup = [[[s_local URLByDeletingLastPathComponent]
                              URLByAppendingPathComponent:@"save-backup"]
                              URLByAppendingPathComponent:[f stringFromDate:[NSDate date]]];
            }
            NSURL *b = [backup URLByAppendingPathComponent:rel];
            [fm createDirectoryAtURL:[b URLByDeletingLastPathComponent]
         withIntermediateDirectories:YES attributes:nil error:nil];
            [fm copyItemAtURL:l toURL:b error:nil];
        }
        if (copy_file(c, l, NO))
            copied++;
    }
    set_status([NSString stringWithFormat:@"Synced %@%@", now_text(),
                copied ? [NSString stringWithFormat:@" (%d from iCloud)", copied] : @""]);
}

/* Here -> iCloud. */
static void push(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableSet<NSString *> *placeholders = [NSMutableSet set];
    int copied = 0;
    if (!s_cloud || ![[NSUserDefaults standardUserDefaults] boolForKey:kCloudSaves])
        return;
    files_under(s_cloud, placeholders);
    for (NSString *rel in files_under(s_local, [NSMutableSet set])) {
        NSURL *l = [s_local URLByAppendingPathComponent:rel], *c = [s_cloud URLByAppendingPathComponent:rel];
        NSDate *tl = mtime(l), *tc;
        if (!tl || -[tl timeIntervalSinceNow] < 2.0 || [placeholders containsObject:rel])
            continue;                       /* being written, or iCloud's own is not here */
        tc = [fm fileExistsAtPath:c.path] ? mtime(c) : nil;
        if (tc && [tl timeIntervalSinceDate:tc] <= 1.0)
            continue;
        if (copy_file(l, c, YES))
            copied++;
    }
    if (copied)
        set_status([NSString stringWithFormat:@"Synced %@ (%d to iCloud)", now_text(), copied]);
}

void MC3CloudSyncNow(void)
{
    if (s_q)
        dispatch_async(s_q, ^{ push(); });
}

NSString *MC3CloudStatus(void)
{
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kCloudSaves])
        return @"Off";
    return s_status;
}

BOOL MC3CloudSavesEnabled(void)
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:kCloudSaves];
}

static void start_pushing(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (s_timer)
            return;
        s_timer = [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *t) {
            MC3CloudSyncNow();
        }];
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
                         queue:nil usingBlock:^(NSNotification *n) {
            __block UIBackgroundTaskIdentifier task =
                [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
                    [[UIApplication sharedApplication] endBackgroundTask:task];
                }];
            dispatch_async(s_q, ^{
                push();
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[UIApplication sharedApplication] endBackgroundTask:task];
                });
            });
        }];
    });
}

/* From ios_boot (src/ios_host.c), on the main thread, before the game. */
void ios_cloud_saves_start(const char *save_dir)
{
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{ kCloudSaves: @YES }];
    s_local = [NSURL fileURLWithPath:@(save_dir) isDirectory:YES];
    s_q = dispatch_queue_create("mc3.cloudsaves", DISPATCH_QUEUE_SERIAL);
    if (!MC3CloudSavesEnabled()) {
        set_status(@"Off");
        return;
    }
    dispatch_async(s_q, ^{
        /* not on the main thread: it may wait for the container */
        NSURL *c = [[NSFileManager defaultManager] URLForUbiquityContainerIdentifier:nil];
        if (!c) {
            set_status(@"iCloud is not available (signed out, or iCloud Drive off)");
        } else {
            s_cloud = [c URLByAppendingPathComponent:@"save" isDirectory:YES];
            [[NSFileManager defaultManager] createDirectoryAtURL:s_cloud
                                     withIntermediateDirectories:YES attributes:nil error:nil];
            pull();
        }
        dispatch_semaphore_signal(done);
    });
    /* at most 15 s at launch; a slow pull carries on and the game starts */
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)))
        fprintf(stderr, "[cloud] still pulling after 15 s: the game starts anyway\n");
    start_pushing();
}

/* Turned on in the menu while the game runs: only pushing (a pull under
 * a running game could replace a profile it has open). */
void MC3CloudSavesSetEnabled(BOOL on)
{
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kCloudSaves];
    if (!on) {
        s_status = @"Off";
        return;
    }
    if (!s_q)
        return;
    dispatch_async(s_q, ^{
        if (!s_cloud) {
            NSURL *c = [[NSFileManager defaultManager] URLForUbiquityContainerIdentifier:nil];
            if (!c) {
                set_status(@"iCloud is not available (signed out, or iCloud Drive off)");
                return;
            }
            s_cloud = [c URLByAppendingPathComponent:@"save" isDirectory:YES];
            [[NSFileManager defaultManager] createDirectoryAtURL:s_cloud
                                     withIntermediateDirectories:YES attributes:nil error:nil];
        }
        set_status(@"On (copies to iCloud; brings saves in at the next launch)");
        push();
    });
    start_pushing();
}
