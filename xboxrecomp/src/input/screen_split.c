/*
 * screen_split.c -- a tall screen shared: the game in the top half, the
 * on-screen pad (touch_pad.c) in the bottom half, like a handheld. Made for
 * a clamshell foldable held in portrait and partly folded (the game on the
 * upper half, the controls on the half lying flat), and the same on any
 * phone held upright, where the game would otherwise be a thin band.
 *
 *   RECOMP_SCREEN_SPLIT  auto (default): split whenever the screen is
 *                        taller than wide; 1 always; 0 never (the pad over
 *                        the game, as in landscape)
 *
 * The host's settings change the mode at run time (xbox_screen_split_mode)
 * and report a foldable's hinge (xbox_screen_hinge, kept for the log and
 * later use). The hinge's place is not reported, only its state, so the
 * split is at the middle, where a clamshell folds. A closed foldable's
 * outer screen held upright is split like any other tall screen.
 */
#include <stdlib.h>

#include "screen_split.h"

static volatile int s_mode = -2;                /* -2: not read yet */
static volatile int s_hinge = XBOX_HINGE_NONE;
static volatile int s_in[4];                    /* safe-area insets: l t r b */
static volatile int s_gen;

static int mode(void)
{
    if (s_mode == -2) {
        const char *e = getenv("RECOMP_SCREEN_SPLIT");
        s_mode = e && *e == '1' ? XBOX_SPLIT_ON : e && *e == '0' ? XBOX_SPLIT_OFF
                                                                  : XBOX_SPLIT_AUTO;
    }
    return s_mode;
}

void xbox_screen_split_mode(int m)
{
    s_mode = m < XBOX_SPLIT_AUTO || m > XBOX_SPLIT_ON ? XBOX_SPLIT_AUTO : m;
    s_gen++;
}

void xbox_screen_insets(int left, int top, int right, int bottom)
{
    if (left == s_in[0] && top == s_in[1] && right == s_in[2] && bottom == s_in[3])
        return;
    s_in[0] = left > 0 ? left : 0;
    s_in[1] = top > 0 ? top : 0;
    s_in[2] = right > 0 ? right : 0;
    s_in[3] = bottom > 0 ? bottom : 0;
    s_gen++;
}

int xbox_screen_layout_gen(void)
{
    mode();
    return s_gen;
}

void xbox_screen_hinge(int status)
{
    s_hinge = status;
}

int xbox_screen_split(int sw, int sh, int game[4], int pad[4])
{
    int m = mode(), half;
    int x = s_in[0], y = s_in[1], w = sw - s_in[0] - s_in[2], h = sh - s_in[1] - s_in[3];
    if (w < sw / 2 || h < sh / 2) {             /* nonsense insets: none */
        x = y = 0;
        w = sw;
        h = sh;
    }
    /* the picture fills the screen, camera strip and all; the pad keeps
     * inside the safe area, where every control can be pressed (but see
     * the split below) */
    game[0] = 0; game[1] = 0; game[2] = sw; game[3] = sh;
    pad[0] = x; pad[1] = y; pad[2] = w; pad[3] = h;
    if (sw <= 0 || sh <= 0 || m == XBOX_SPLIT_OFF)
        return 0;
    if (m == XBOX_SPLIT_AUTO && sh <= sw)
        return 0;
    /* at the middle of the screen (the crease), not of the safe area; the
     * pad's half is below anything a strip at the side holds (iOS's clock
     * sits in its top part), so the pad takes the full width there too,
     * above the home indicator's margin */
    half = sh / 2;
    game[3] = half;
    pad[0] = 0;
    pad[1] = half;
    pad[2] = sw;
    pad[3] = y + h - half;
    return 1;
}
