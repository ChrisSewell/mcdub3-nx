/* The app's own code is SDL2main's UIApplicationMain and the game's
 * SDL_main (src/main.c), both in the libraries Xcode links (project.yml).
 * Xcode links a target only when it compiles something, so this file
 * exists; it also makes sure UIKit is loaded before SDL asks for it. */
#import <UIKit/UIKit.h>

__attribute__((used)) static Class mc3_app_shell(void)
{
    return [UIApplication class];
}
