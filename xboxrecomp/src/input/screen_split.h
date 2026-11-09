/* screen_split.h -- the game above, the on-screen pad below (screen_split.c). */
#ifndef XBOX_SCREEN_SPLIT_H
#define XBOX_SCREEN_SPLIT_H

#ifdef __cplusplus
extern "C" {
#endif

/* RECOMP_SCREEN_SPLIT and the host's settings menu. */
enum { XBOX_SPLIT_AUTO = -1, XBOX_SPLIT_OFF = 0, XBOX_SPLIT_ON = 1 };

/* A foldable's hinge, as the host reports it (iOS: UIHingeInteraction). */
enum { XBOX_HINGE_NONE = 0, XBOX_HINGE_CLOSED = 1, XBOX_HINGE_PARTLY_OPEN = 2,
       XBOX_HINGE_FULLY_OPEN = 3 };

void xbox_screen_split_mode(int mode);
void xbox_screen_hinge(int status);
/* The screen's safe area, as insets in pixels (a camera cut-out, a
 * foldable's outer screen): the pad keeps inside it; the picture fills the
 * whole screen. */
void xbox_screen_insets(int left, int top, int right, int bottom);
/* Changes with every mode or inset change: lay out again. */
int  xbox_screen_layout_gen(void);

/* For a sw x sh screen (pixels, y down), the game's area (the whole
 * screen, or its top half) and the pad's (inside the safe area), as
 * x, y, w, h: 1 when the screen is split, the game's on top; 0 when the
 * game has the whole screen and the pad, if any, is laid over it. */
int  xbox_screen_split(int sw, int sh, int game[4], int pad[4]);

#ifdef __cplusplus
}
#endif

#endif
