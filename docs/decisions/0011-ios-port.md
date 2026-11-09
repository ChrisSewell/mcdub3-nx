# 11. An iOS port on the Android host layer, OpenGL ES 3.0

Date: 2026-11-09

## Context

Both games run on the Switch, Linux, macOS, Windows and, since v1.1.0,
Android (ADR 0010). iOS is the next host, for one owner's iPhone: the
translated game is plain C, no JIT, already built for 64-bit ARM, and the
runtime's host layer is SDL2, which runs on iOS. The Android port added
what a phone needs: an on-screen pad, a GLES path in the renderer, a boot
glue file for the folder, log and settings.

iOS's own OpenGL ES stops at 3.0 and is deprecated (since iOS 12), but it
still ships and runs on Metal. ANGLE's Metal backend, the other way to
OpenGL ES on iOS, is also ES 3.0 only. The renderer asked for ES 3.2 or
3.1 on Android, but its shaders use nothing past GLSL ES 3.00 and what it
takes from 3.1 and 3.2 (border clamp, buffer storage, base-vertex draws,
queries) is already optional.

## Decision

- **iOS is a host of its own** (`IOS` in CMake): `ios/CMakeLists.txt`
  builds SDL2 (static) and the game as `libmcdub3.a`; an XcodeGen app in
  `ios/` (`project.yml`) links them. `tools/ios_build.sh` runs both,
  for the simulator or a device. `make ios` / `make ios-sim`.
- **Personal builds only.** The app carries the lifted code of the owner's
  disc, so it is installed from Xcode or over the air by its owner, never
  through the App Store or TestFlight. Nothing of the game is in git, as
  before.
- **Renderer: an OpenGL ES 3.0 tier** (`#version 300 es`, `s_es_minor 0`)
  in the existing ES path, used when 3.2 and 3.1 contexts are refused.
  First on iOS's own driver through SDL's window code, no new library.
  Should Apple's driver fail, ANGLE on Metal gives the same ES 3.0 through
  the same tier. The Vulkan renderer on MoltenVK is the last resort.
- **Memory**: the runtime's 4 GB guest window needs the Extended Virtual
  Addressing and Increased Memory Limit entitlements, which the app
  declares; the simulator needs neither.
- **Host glue** `src/ios_host.c`, after `android_host.c`: the sandbox's
  Documents folder (`$HOME/Documents`, shown by the Files app through
  `UIFileSharingEnabled`) holds `game-<edition>/`, `save/`,
  `mcdub3_env.txt` and the log; defaults for a phone: scale 1.5, UI scale
  2, the renderer on its own thread. Landscape only. Plain C: no
  Objective-C is needed for any of it.
- **Controls**: the touch pad as on Android.
- **Movies**: the lifted Bink decoder; FFmpeg for iOS later if they
  stutter (`MC3_NATIVE_BINK` is off on iOS).
- **Signing** lives in `ios/Config/Local.xcconfig`, ignored by git, like
  the Android release key.

## Consequences

- A fourth packaging path (NRO, desktop apps, APK, .app), one more
  `IOS` branch in five CMake files.
- The ES 3.0 tier also serves any Android device that offers only 3.0.
- The first picture is the risk: Apple's ES 3.0 driver has not run this
  renderer. ANGLE is the fallback, with the same tier.

## Update (2026-11-09): what the first device needed

- **iOS 27 SDK**: the app adopts the UIScene lifecycle (`ios/App/SceneShim.m`):
  SDL2's windows are attached to the scene, also when made before it
  connected, and SDL's launch window is kept out. So the app shell is
  Objective-C after all (`ios/App/*.m`); the game and runtime stay C.
- **Pictures**: the window's framebuffer is SDL's (SDL_SysWMinfo), not 0;
  its renderbuffer is bound before each swap (`GLSwapFix.m`); no second
  GL context for compiling (UIKit gives each context a view of its own).
  SDL's drawable resize is moved to the renderer's thread, and its GL view
  keeps the window's frame (SDL set a portrait frame on a landscape
  window after a foldable reopened).
- **Memory**: the sandbox refuses `shm_open`; guest memory is an unlinked
  file in `TMPDIR` (toolkit `win32_compat.c`).
- **Portrait and foldables**: `xboxrecomp/src/input/screen_split.c` splits a
  screen held upright, the game above the on-screen pad (made for a
  clamshell held half folded); the pad keeps to the safe area, the
  picture fills the screen. The hinge (`UIHingeInteraction`) is reported.
- **The app's own screens**: a welcome screen (disc found or how to add
  it), a loading screen until the first frame, a menu (control style, pad,
  layout, saves) over the game; an icon drawn by `tools/ios_icon_draw.py`.
- **Saves in iCloud** (`CloudSaves.m`), opt in per build with
  `MC3_ICLOUD = 1` once the container is registered.
- **Touch pad**: LT, RT and LS added; A and B as lettered (Android keeps
  its swap).
- **Testing**: on the simulator only with SDL's dummy audio driver, checked
  in the log before anything else (`MC3_APU=0` hangs the Remix); a
  foldable simulator is folded from the command line (`duoctl`) and shot
  with `simctl io ... screenshot --display=primary`.
