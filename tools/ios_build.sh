#!/usr/bin/env bash
# The iOS app (ADR 0011): tools/ios_build.sh [sim|device] [lib|app|run]
#
#   sim      arm64 simulator build (default); `run` installs and starts it
#            on the booted simulator (or SIM="iPhone Duo")
#   device   arm64 device build, signed with ios/Config/Local.xcconfig
#   lib      CMake only: work-<game>/ios/<sdk>/lib/{lib<MC3_APP>,libSDL2,libSDL2main}.a
#   app      lib, then xcodegen + xcodebuild (default):
#            work-<game>/ios/<sdk>/<Midnight Club 3[ Remix]>.app (GAME=remix)
#   run      app, then install and launch on the simulator
#   RUNTIME_ONLY=1 with lib: the toolkit's libraries and SDL2 alone, no
#            lifted code (brings the toolchain up before the disc is there)
#
# SDL2's source lives in work-dub/tools/SDL2-2.32.10 (as the Android build
# has it; MC3_SDL_DIR names another). Requires Xcode, CMake, Ninja, XcodeGen.
set -euo pipefail
. "$(dirname "$0")/env.sh"
[ "$MC3_HOST" = mac ] || mc3_fail "the iOS build runs on macOS"
mc3_app_env

target=${1:-sim}
step=${2:-app}
case "$target" in sim|device) ;; *) mc3_fail "usage: $0 [sim|device] [lib|app|run]" ;; esac
case "$step" in lib|app|run) ;; *) mc3_fail "usage: $0 [sim|device] [lib|app|run]" ;; esac
[ "$step" = run ] && [ "$target" = device ] && mc3_fail "run: simulator only; install on a device from Xcode or with devicectl"

sdk=$([ "$target" = sim ] && echo iphonesimulator || echo iphoneos)
tools="$MC3_REPO/work-dub/tools"
export MC3_SDL_DIR="${MC3_SDL_DIR:-$tools/SDL2-2.32.10}"
[ -d "$MC3_SDL_DIR" ] || mc3_fail "no SDL2 source in $MC3_SDL_DIR (libsdl.org, SDL2-2.32.10.tar.gz)"
command -v ninja >/dev/null || mc3_fail "no ninja: brew install ninja"
command -v xcodegen >/dev/null || [ "$step" = lib ] || mc3_fail "no xcodegen: brew install xcodegen"

build="$MC3_WORK/ios/$sdk"
echo "== libraries ($sdk) -> $build/lib"
cmake -S "$MC3_REPO/ios" -B "$build" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DMC3_SDL_DIR="$MC3_SDL_DIR" \
    -DMC3_VERSION="${APP_VERSION:-dev}" \
    -DMC3_BUILD_ID="${MC3_BUILD_ID:-local}" \
    -DMC3_RUNTIME_ONLY="$([ "${RUNTIME_ONLY:-0}" = 1 ] && echo ON || echo OFF)"
cmake --build "$build"
ls "$build"/lib/libSDL2.a "$build"/lib/libSDL2main.a >/dev/null
if [ "${RUNTIME_ONLY:-0}" = 1 ]; then
    echo "  runtime built (no game: RUNTIME_ONLY=1)"
    exit 0
fi
ls "$build/lib/lib$MC3_APP.a" >/dev/null
[ "$step" = lib ] && exit 0

echo "== app ($sdk)"
# The game's icon (AppIconGame) from its artwork; without it the app keeps
# ios/App's AppIcon.
icons="$MC3_WORK/ios/GameIcon.xcassets"
appicon=AppIcon
rm -rf "$icons"
art=$(mc3_app_artwork "${EDITION:-}")
py=$(mc3_pillow_python)
if [ -n "$art" ] && [ -n "$py" ]; then
    mkdir -p "$icons/AppIconGame.appiconset"
    printf '{ "info": { "author": "xcode", "version": 1 } }\n' > "$icons/Contents.json"
    cat > "$icons/AppIconGame.appiconset/Contents.json" <<'JSON'
{
  "images": [ { "filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" } ],
  "info": { "author": "xcode", "version": 1 }
}
JSON
    if "$py" "$MC3_REPO/tools/app_icon.py" ios "$art" "$icons/AppIconGame.appiconset/icon-1024.png"; then
        appicon=AppIconGame
    else
        rm -rf "$icons"
    fi
else
    echo "  (the default icon: $([ -n "$art" ] && echo "no Python with Pillow" || echo "no artwork, APP_ICON in config/$MC3_GAME/app.env"))"
fi
export MC3_ICON_CATALOG="$icons"
# iCloud saves: only with a container set up for the app (MC3_ICLOUD = 1 in
# ios/Config/Local.xcconfig, or MC3_ICLOUD=1 here); the simulator always.
icloud=()
if [ "$target" = sim ] || [ "${MC3_ICLOUD:-}" = 1 ] \
        || grep -qE '^[[:space:]]*MC3_ICLOUD[[:space:]]*=[[:space:]]*1' "$MC3_REPO/ios/Config/Local.xcconfig" 2>/dev/null; then
    icloud=(CODE_SIGN_ENTITLEMENTS=App/MidnightClub3-iCloud.entitlements)
    echo "  iCloud saves: on"
fi
(cd "$MC3_REPO/ios" && xcodegen generate --quiet)
derived="$build/xcode"
dest=$([ "$target" = sim ] && echo "generic/platform=iOS Simulator" || echo "generic/platform=iOS")
# MC3_XCODEBUILD_ARGS: e.g. -allowProvisioningUpdates and the App Store
# Connect API key flags for a device build without Xcode signed in.
xcodebuild -project "$MC3_REPO/ios/MidnightClub3.xcodeproj" -scheme MidnightClub3 \
    -configuration Debug -destination "$dest" -derivedDataPath "$derived" -quiet \
    MC3_WORK="$MC3_WORK" MC3_APP="$MC3_APP" MC3_PRODUCT_NAME="$MC3_SHORT_NAME" \
    ASSETCATALOG_COMPILER_APPICON_NAME="$appicon" \
    ${icloud[@]+"${icloud[@]}"} \
    ${MC3_XCODEBUILD_ARGS:-} build
app="$(find "$derived/Build/Products" -maxdepth 2 -name "$MC3_SHORT_NAME.app" | head -1)"
[ -d "$app" ] || mc3_fail "no app after the build (see xcodebuild's output above)"
rm -rf "$build/$MC3_SHORT_NAME.app"
cp -R "$app" "$build/"
echo "  app: ${build#$MC3_REPO/}/$MC3_SHORT_NAME.app"
[ "$step" = run ] || exit 0

echo "== simulator"
sim="${SIM:-}"
if [ -n "$sim" ]; then
    xcrun simctl boot "$sim" 2>/dev/null || true
fi
bundle="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$build/$MC3_SHORT_NAME.app/Info.plist")"
xcrun simctl install "${sim:-booted}" "$build/$MC3_SHORT_NAME.app"
xcrun simctl launch --console-pty "${sim:-booted}" "$bundle"
