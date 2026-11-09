/* touch_pad.h -- the on-screen pad for touch screens (touch_pad.c). */
#ifndef XBOX_TOUCH_PAD_H
#define XBOX_TOUCH_PAD_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

union SDL_Event;

/* A window event from the renderer's loop (fingers; a key hides the pad). */
void xbox_touchpad_handle(const union SDL_Event *e);
/* Port 0 has a real controller: the pad hides. */
void xbox_touchpad_controller(int connected);
int  xbox_touchpad_shown(void);
/* A host's settings, at run time: mode -1 auto, 0 off, 1 always; the
 * stick's up/down as gas/brake; A and B swapped; opacity; size. */
void xbox_touchpad_configure(int mode, int stick_pedals, int swap_ab, float alpha, float scale);
/* The overlay for a sw x sh screen, RGBA (straight alpha), top row first:
 * -1 hidden, 0 unchanged since the last call, 1 changed (upload again). */
int  xbox_touchpad_image(int sw, int sh, const uint32_t **rgba, int *w, int *h);

#ifdef __cplusplus
}
#endif

#endif
