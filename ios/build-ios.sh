#!/bin/bash
# Builds Knob for iPhone into build/ios/<sdk>/Knob.app, from the same KnobShift, panel and sound
# code as the Mac app (no Xcode project, like app/build-app.sh).
#   ios/build-ios.sh [simulator|device] [run]
# "run" installs it on the booted simulator (booting an iPhone first if none is), or on the
# connected iPhone for "device", and opens it.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
kind="${1:-simulator}"
case "$kind" in
  simulator) sdk=iphonesimulator; target=arm64-apple-ios17.0-simulator ;;
  device) sdk=iphoneos; target=arm64-apple-ios17.0 ;;
  *) echo "usage: ios/build-ios.sh [simulator|device] [run]" >&2; exit 2 ;;
esac
out="$repo_dir/build/ios/$sdk"
bundle="$out/Knob.app"
objects="$out/objects"
mkdir -p "$objects"

echo "==> Building the sound effects"
# 1. Knob's effects library for this SDK.
cmake -S "$repo_dir/dsp/portable" -B "$out/dsp" -G "Unix Makefiles" -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCMAKE_BUILD_TYPE=Release > "$out/dsp-configure.log"
cmake --build "$out/dsp" --target knob-dsp -j8 > "$out/dsp-build.log"

echo "==> Building the sound engine"
# 2. The engine's DSPController and the iPhone bridge to it.
sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
for source in "$repo_dir"/engine/dsp-controller.cpp "$repo_dir"/engine/dsp-controller-controls.cpp \
              "$repo_dir"/engine/dsp-controller-storage.cpp "$repo_dir"/ios/Bridge/KnobPhoneDSP.cpp; do
  xcrun --sdk "$sdk" clang++ -std=c++17 -O2 -target "$target" -isysroot "$sysroot" \
    -DKNOB_PHONE -DKNOB_HAVE_DSP -I"$repo_dir/dsp/portable" -I"$repo_dir/dsp/core/include" \
    -c "$source" -o "$objects/$(basename "$source" .cpp).o"
done

echo "==> Checking the iPhone colours"
"$repo_dir/ios/check-theme.sh"

echo "==> Building the app, this is the long step"
# 3. Swift: the shared code, without what only the Mac can do (system wide sound, Spotify and
#    YouTube downloads, windows, updates), plus the iPhone's own files.
shared="$repo_dir/app/Sources/Knob"
swift_sources=()
while IFS= read -r file; do swift_sources+=("$file"); done < <(
  { ls "$shared"/State/*.swift "$shared"/Theme/*.swift "$shared"/Components/*.swift
    printf '%s\n' "$shared"/KnobShiftLog.swift "$shared"/KnobShiftDemoRecorder.swift "$shared"/Engine/SoundEngine.swift "$shared"/Engine/EngineState.swift \
      "$shared"/Engine/DemoEngine.swift "$shared"/Engine/StartupFailure.swift
    while read -r view; do echo "$shared/Views/$view.swift"; done < "$repo_dir/ios/shared-views.txt"
  } | grep -vE 'Spotify|YouTube|Google|SpotDL|HelperProcess|KnobShiftImport|MacEngine|UpdateStatusLabel'
)
# Simulator builds are development builds: DEBUG turns on the KNOB_PHONE_* test switches.
debug_flags=()
if [ "$kind" = simulator ]; then debug_flags=(-DDEBUG); fi
xcrun --sdk "$sdk" swiftc -target "$target" -sdk "$sysroot" -swift-version 5 -Onone -g ${debug_flags[@]+"${debug_flags[@]}"} \
  -module-name Knob -import-objc-header "$repo_dir/ios/Bridge/KnobPhone-Bridging.h" \
  "${swift_sources[@]}" "$repo_dir"/ios/Sources/*.swift \
  "$objects"/*.o "$out/dsp/libknob-dsp.a" -lc++ \
  -framework AVFoundation -framework AVKit -framework AudioToolbox -framework MediaPlayer -framework SwiftUI -framework UIKit \
  -o "$out/Knob"

echo "==> Packing and signing the app"
# 4. The app: binary, Info.plist, factory presets and icon.
rm -rf "$bundle"
mkdir -p "$bundle/presets"
cp "$out/Knob" "$bundle/Knob"
cp "$repo_dir/ios/Info.plist" "$bundle/Info.plist"
cp "$repo_dir/presets/"*.fac "$bundle/presets/"
# KnobShift's on-device vocal separation model (Open-Unmix, MIT) and its licence.
ditto "$repo_dir/app/Resources/KnobShift" "$bundle/KnobShift"
# The app icon (Knob's icon as a full square: iOS rounds the corners), compiled by Apple's asset
# tool, which also says which Info.plist entries point at it.
xcrun actool "$repo_dir/ios/Assets.xcassets" --compile "$bundle" --platform "$sdk" \
  --minimum-deployment-target 17.0 --target-device iphone --app-icon AppIcon \
  --output-partial-info-plist "$out/icon-info.plist" --output-format human-readable-text > "$out/actool.log"
/usr/libexec/PlistBuddy -c "Merge $out/icon-info.plist" "$bundle/Info.plist" > /dev/null
if [ "$kind" = simulator ]; then
  codesign --force --sign - "$bundle"
else
  # A real iPhone needs Apple's signature: the Apple Development certificate and the profile
  # for this app ID that Xcode makes for the Apple ID added in Xcode (Settings, Accounts).
  app_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$repo_dir/ios/Info.plist")"
  profile="$(grep -l "$app_id" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.mobileprovision \
    "$HOME/Library/MobileDevice/Provisioning Profiles/"*.mobileprovision 2>/dev/null | head -1 || true)"
  if [ -z "$profile" ]; then
    echo "No signing profile for $app_id yet. Let Xcode make one for your Apple ID first." >&2
    exit 1
  fi
  cp "$profile" "$bundle/embedded.mobileprovision"
  security cms -D -i "$profile" > "$out/profile.plist"
  /usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$out/profile.plist" > "$out/entitlements.plist"
  identity="$(security find-identity -v -p codesigning | grep -m1 '"Apple Development' | sed -E 's/.*"(.*)"/\1/')"
  codesign --force --sign "$identity" --entitlements "$out/entitlements.plist" "$bundle"
fi
echo "Built $bundle"

if [ "${2:-}" = run ] && [ "$kind" = device ]; then
  # The first connected iPhone (not a simulator).
  phone="$(xcrun devicectl list devices 2>/dev/null | grep -E '(connected|available \(paired\)) .* physical' | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)"
  [ -n "$phone" ] || { echo "Connect your iPhone with a cable, or keep it on the same Wi-Fi, and unlock it." >&2; exit 1; }
  xcrun devicectl device install app --device "$phone" "$bundle"
  xcrun devicectl device process launch --device "$phone" io.github.simranxdhindsa.knob.phone
fi

if [ "${2:-}" = run ] && [ "$kind" = simulator ]; then
  if ! xcrun simctl list devices booted | grep -q Booted; then
    phone="$(xcrun simctl list devices available | grep -m1 -E '^\s+iPhone' | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
    xcrun simctl boot "$phone"
  fi
  xcrun simctl install booted "$bundle"
  xcrun simctl launch booted io.github.simranxdhindsa.knob.phone
fi
