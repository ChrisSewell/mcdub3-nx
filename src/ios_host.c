/*
 * ios_host.c -- iOS boot glue (ADR 0011), the counterpart of android_host.c.
 *
 *   folder    the app's Documents folder ($HOME/Documents in the sandbox),
 *             which the Files app and Finder show (UIFileSharingEnabled,
 *             LSSupportsOpeningDocumentsInPlace in ios/project.yml); the
 *             working directory
 *   disc      the first holding default.xbe of <folder>/game-<edition>/,
 *             <folder>/game/, then <folder>/game-<any edition>/; MC3_GAME_DIR
 *             overrides
 *   saves     <folder>/save/ (MC3_SAVE_DIR overrides), kept in iCloud by
 *             ios/App/CloudSaves.m
 *   settings  <MC3_APP>_env.txt in <folder>, KEY=VALUE per line, '#' starts
 *             a comment; applied with setenv before boot, as on the Switch
 *   log       <folder>/<MC3_APP>_log.txt (the run before it: _log_prev.txt),
 *             and every line still to stderr for Xcode's console
 *
 * Plain C on purpose: the sandbox's Documents folder is $HOME/Documents,
 * so no Objective-C is needed and this file builds in the C-only CMake
 * project like the other hosts.
 */
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
#include <SDL.h>
#include <dirent.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <mach-o/dyld.h>

#ifndef MC3_APP
#  define MC3_APP "mcdub3"
#endif
#ifndef MC3_PACKAGE_EDITION
#  define MC3_PACKAGE_EDITION "usa"
#endif
#ifndef MC3_GAME_TITLE
#  define MC3_GAME_TITLE "Midnight Club 3"
#endif

static char s_dir[512];
static int  s_pipe[2] = { -1, -1 };
static int  s_console = -1;                  /* the original stderr: Xcode */
static FILE *s_log;

/* stdout and stderr, into the log file and on to the console. */
static void *log_pump(void *arg)
{
    char buf[4096];
    ssize_t n;
    (void)arg;
    while ((n = read(s_pipe[0], buf, sizeof buf)) > 0) {
        if (s_log) {
            fwrite(buf, 1, (size_t)n, s_log);
            fflush(s_log);
        }
        if (s_console >= 0)
            (void)!write(s_console, buf, (size_t)n);
    }
    return NULL;
}

static void log_open(void)
{
    char path[600], prev[600];
    pthread_t th;
    snprintf(path, sizeof path, "%s/" MC3_APP "_log.txt", s_dir);
    snprintf(prev, sizeof prev, "%s/" MC3_APP "_log_prev.txt", s_dir);
    rename(path, prev);                      /* the run before, kept */
    s_log = fopen(path, "w");
    s_console = dup(STDERR_FILENO);
    if (pipe(s_pipe) != 0)
        return;
    dup2(s_pipe[1], STDOUT_FILENO);
    dup2(s_pipe[1], STDERR_FILENO);
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    if (pthread_create(&th, NULL, log_pump, NULL) == 0)
        pthread_detach(th);
}

static void env_file_apply(const char *dir)
{
    char path[600], line[512];
    FILE *f;
    snprintf(path, sizeof path, "%s/" MC3_APP "_env.txt", dir);
    if (!(f = fopen(path, "r")))
        return;
    while (fgets(line, sizeof line, f)) {
        char *key = line, *eq, *end;
        while (*key == ' ' || *key == '\t')
            key++;
        if (*key == '#' || *key == '\n' || *key == '\r' || !*key)
            continue;
        if (!(eq = strchr(key, '=')))
            continue;
        *eq = '\0';
        end = eq + 1 + strcspn(eq + 1, "\r\n");
        *end = '\0';
        setenv(key, eq + 1, 1);
        printf("[ios] %s=%s\n", key, eq + 1);
    }
    fclose(f);
}

/* The first start writes the documented template beside the settings, so
 * the full list of switches sits where the Files app shows it. */
static void env_file_template(void)
{
    char path[600], res[1024];
    uint32_t rn = sizeof res;
    FILE *f;
    snprintf(path, sizeof path, "%s/" MC3_APP "_env.txt", s_dir);
    if (access(path, F_OK) == 0)
        return;
    /* An iOS bundle is flat: resources sit beside the executable. */
    if (_NSGetExecutablePath(res, &rn) != 0 || !strrchr(res, '/'))
        return;
    *strrchr(res, '/') = '\0';
    {
        char src[1100];
        FILE *in;
        snprintf(src, sizeof src, "%s/env_template.txt", res);
        if ((in = fopen(src, "r")) != NULL && (f = fopen(path, "w")) != NULL) {
            char buf[4096];
            size_t n;
            while ((n = fread(buf, 1, sizeof buf, in)) > 0)
                fwrite(buf, 1, n, f);
            fclose(f);
        }
        if (in)
            fclose(in);
    }
}

/* The folder everything lives in (after ios_boot). */
const char *ios_app_dir(void)
{
    return s_dir;
}

static int has_disc(const char *dir)
{
    char path[700];
    snprintf(path, sizeof path, "%s/default.xbe", dir);
    return access(path, R_OK) == 0;
}

/* The disc: game-<edition>/ before game/ in Documents, then any other
 * edition's game-<edition>/ (the boot check takes every edition this lift
 * accepts, xbe_editions.h). */
static int find_disc(char *out, size_t cap)
{
    DIR *d;
    struct dirent *e;
    snprintf(out, cap, "%s/game-" MC3_PACKAGE_EDITION, s_dir);
    if (has_disc(out))
        return 1;
    snprintf(out, cap, "%s/game", s_dir);
    if (has_disc(out))
        return 1;
    if ((d = opendir(s_dir)) != NULL) {
        while ((e = readdir(d)) != NULL)
            if (!strncmp(e->d_name, "game-", 5)) {
                snprintf(out, cap, "%s/%s", s_dir, e->d_name);
                if (has_disc(out)) {
                    closedir(d);
                    return 1;
                }
            }
        closedir(d);
    }
    return 0;
}

/* The saves in iCloud (ios/App/CloudSaves.m): newer copies brought in
 * before the game reads them, its own written back while it runs. Weak:
 * nothing without the app's half. */
__attribute__((weak)) void ios_cloud_saves_start(const char *save_dir)
{
    (void)save_dir;
}

/* The app's welcome screen (ios/App/Welcome.m): returns when the player
 * presses Play, with the disc in place, MC3_GAME_DIR set to it. Weak:
 * straight on without the app's half (the disc check below asks). */
__attribute__((weak)) void ios_welcome(void)
{
}

void ios_boot(void)
{
    const char *home = getenv("HOME");
    char path[700];
    snprintf(s_dir, sizeof s_dir, "%s/Documents", home && *home ? home : ".");
    mkdir(s_dir, 0775);
    if (chdir(s_dir) != 0)
        fprintf(stderr, "[ios] chdir %s: %s\n", s_dir, strerror(errno));
    log_open();
    printf("[ios] " MC3_APP " starting in %s\n", s_dir);

    /* Landscape, and portrait for the split screen (the game above the
     * pad, xboxrecomp/src/input/screen_split.c); the home indicator out of
     * the way, and no idle sleep while a race runs (set before the window). */
    SDL_SetHint(SDL_HINT_ORIENTATIONS, "LandscapeLeft LandscapeRight Portrait");
    SDL_SetHint(SDL_HINT_IOS_HIDE_HOME_INDICATOR, "2");
    SDL_SetHint(SDL_HINT_IDLE_TIMER_DISABLED, "1");
    /* No on-screen keyboard, ever: the game takes no text, and SDL brought
     * one up when a fold or rotation made its text field first responder
     * again (keyboards' keys still arrive as presses). */
    SDL_SetHint(SDL_HINT_ENABLE_SCREEN_KEYBOARD, "0");

    /* Phone defaults, as on the Switch: 1080x720, HUD art at 2x, the
     * renderer on a thread of its own. The settings file overrides. */
    setenv("RECOMP_GL_SCALE", "1.5", 0);
    setenv("RECOMP_GL_UI_SCALE", "2", 0);
    setenv("RECOMP_GL_THREAD", "1", 0);

    env_file_template();
    env_file_apply(s_dir);
    ios_welcome();
    for (;;) {
        const char *g = getenv("MC3_GAME_DIR");
        static const SDL_MessageBoxButtonData buttons[] = {
            { SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT, 1, "Retry" },
            { SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, 0, "Quit" },
        };
        SDL_MessageBoxData box;
        char msg[800];
        int hit = -1;
        if (g ? has_disc(g) : find_disc(path, sizeof path)) {
            if (!g)
                setenv("MC3_GAME_DIR", path, 1);
            printf("[ios] disc: %s\n", getenv("MC3_GAME_DIR"));
            break;
        }
        printf("[ios] no disc found (%s)\n", g ? g : "searched Documents");
        snprintf(msg, sizeof msg,
                 "No game disc found.\n\n"
                 "In the Files app, open On My iPhone > " MC3_GAME_TITLE " and put the "
                 "extracted disc (the folder holding default.xbe) there as\n\n"
                 "  game-" MC3_PACKAGE_EDITION "\n\n"
                 "Not the .iso: the folder of files from it.%s%s",
                 g ? "\n\nMC3_GAME_DIR is set to " : "", g ? g : "");
        memset(&box, 0, sizeof box);
        box.flags = SDL_MESSAGEBOX_ERROR;
        box.title = MC3_GAME_TITLE;
        box.message = msg;
        box.numbuttons = 2;
        box.buttons = buttons;
        if (SDL_ShowMessageBox(&box, &hit) != 0 || hit == 0)
            exit(0);
    }
    if (!getenv("MC3_SAVE_DIR")) {
        snprintf(path, sizeof path, "%s/save", s_dir);
        mkdir(path, 0775);
        setenv("MC3_SAVE_DIR", path, 1);
    }
    ios_cloud_saves_start(getenv("MC3_SAVE_DIR"));
}
#endif
