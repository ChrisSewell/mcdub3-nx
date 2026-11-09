/* SDL2's iOS swap shows whatever renderbuffer is bound (ADR 0011).
 *
 * SDL_uikitopenglview's swapBuffers ends in
 * [context presentRenderbuffer:GL_RENDERBUFFER], which presents the
 * renderbuffer bound at that moment, and SDL leaves rebinding its own to
 * the application. Every other host (EGL, CGL, WGL) presents the window's
 * surface whatever is bound, so the renderer (nv2a_gl) binds its own
 * renderbuffers and never puts SDL's back: the frame was drawn into the
 * window's framebuffer and never shown (black screen, intro movies'
 * sound playing). Bind SDL's framebuffer and colour renderbuffer right
 * before every swap.
 *
 * Its layoutSubviews also resizes the drawable when the view changes size
 * (rotation: the split screen in portrait), on the main thread, making
 * the renderer's context current there while the renderer's thread is
 * using it. That resize is moved here, after a swap, on the renderer's
 * thread: layoutSubviews only notes the size wanted.
 *
 * Its frame is the window's, always: SDL sets it to a size of its own on
 * some events (UIKit_ComputeViewFrame, from the deprecated status bar
 * orientation), and after a foldable reopened that left a portrait drawable
 * on a landscape screen (the picture small, in a corner). setFrame: keeps
 * the window's bounds whatever it is asked.
 *
 * The view's safe area goes to the runtime in pixels
 * (xbox_screen_insets, xboxrecomp/src/input/screen_split.c): the picture
 * and the on-screen pad stay clear of a camera strip. */
#import <UIKit/UIKit.h>
#import <OpenGLES/ES3/gl.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#include <stdio.h>

@interface NSObject (MC3SDLGLView)
- (GLuint)drawableRenderbuffer;
- (GLuint)drawableFramebuffer;
- (int)backingWidth;
- (int)backingHeight;
- (void)updateFrame;
@end

void xbox_screen_insets(int left, int top, int right, int bottom);

static IMP s_swap_buffers, s_view_layout, s_set_frame;
static atomic_int s_want_w, s_want_h;          /* the size layoutSubviews saw */

static void mc3_swap_buffers(id self, SEL cmd)
{
    int w, h;
    glBindFramebuffer(GL_FRAMEBUFFER, [self drawableFramebuffer]);
    glBindRenderbuffer(GL_RENDERBUFFER, [self drawableRenderbuffer]);
    ((void (*)(id, SEL))s_swap_buffers)(self, cmd);
    w = atomic_load(&s_want_w);
    h = atomic_load(&s_want_h);
    if (w > 0 && h > 0 && (w != [self backingWidth] || h != [self backingHeight])) {
        int ow = [self backingWidth], oh = [self backingHeight];
        [self updateFrame];                     /* the next frame at the new size */
        fprintf(stderr, "[ios] drawable %dx%d -> %dx%d (wanted %dx%d)\n", ow, oh,
                [self backingWidth], [self backingHeight], w, h);
    }
}

/* SDL_uikitopenglview's layoutSubviews without its resize: UIView's (the
 * superclass's) layout, and the size for the next swap. */
static void mc3_layout_subviews(id self, SEL cmd)
{
    UIView *v = (UIView *)self;
    ((void (*)(id, SEL))s_view_layout)(self, cmd);
    CGFloat k = v.contentScaleFactor;
    UIEdgeInsets in = v.safeAreaInsets;
    atomic_store(&s_want_w, (int)(v.bounds.size.width * k));
    atomic_store(&s_want_h, (int)(v.bounds.size.height * k));
    xbox_screen_insets((int)(in.left * k), (int)(in.top * k), (int)(in.right * k), (int)(in.bottom * k));
}

static void mc3_set_frame(id self, SEL cmd, CGRect f)
{
    UIWindow *w = ((UIView *)self).window;
    if (w && !CGRectEqualToRect(f, w.bounds)) {
        fprintf(stderr, "[ios] GL view frame %.0fx%.0f asked, the window's %.0fx%.0f kept\n",
                f.size.width, f.size.height, w.bounds.size.width, w.bounds.size.height);
        f = w.bounds;
    }
    ((void (*)(id, SEL, CGRect))s_set_frame)(self, cmd, f);
}

@interface MC3GLSwapFix : NSObject
@end

@implementation MC3GLSwapFix

+ (void)load
{
    Class cls = objc_getClass("SDL_uikitopenglview");
    Method m = cls ? class_getInstanceMethod(cls, @selector(swapBuffers)) : NULL;
    if (m)
        s_swap_buffers = method_setImplementation(m, (IMP)mc3_swap_buffers);
    m = cls ? class_getInstanceMethod(cls, @selector(layoutSubviews)) : NULL;
    if (m) {
        s_view_layout = class_getMethodImplementation(class_getSuperclass(cls),
                                                      @selector(layoutSubviews));
        method_setImplementation(m, (IMP)mc3_layout_subviews);
    }
    m = cls ? class_getInstanceMethod(cls, @selector(setFrame:)) : NULL;
    if (m) {
        /* the superclass's setFrame: (UIView's): the view class has none */
        s_set_frame = class_getMethodImplementation(class_getSuperclass(cls), @selector(setFrame:));
        class_addMethod(cls, @selector(setFrame:), (IMP)mc3_set_frame, method_getTypeEncoding(m));
    }
}

@end
