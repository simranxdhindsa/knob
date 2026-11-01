#!/bin/bash
# Builds build/Knob.app from the Swift package. Usage: app/build-app.sh [debug|release]
# Optional environment (the release workflow sets these):
#   KNOB_VERSION=0.1.42 KNOB_BUILD=42   version shown to users / build number updates compare
#   KNOB_UNIVERSAL=1                    Apple silicon + Intel in one app
#   KNOB_SIGN_IDENTITY="Knob Release"   signing certificate (default: ad-hoc). A fixed certificate
#                                       keeps macOS permissions (microphone) across updates.
#   KNOB_SIGN_KEYCHAIN=path             keychain holding that certificate
#   KNOB_ENGINE_DIR=path                CMake build folder with knob-engine and driver/ (default build/)
#   KNOB_FEED_URL, KNOB_BUNDLE_ID       only for testing updates against a local feed
set -euo pipefail
app_dir=$(cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(cd -- "$app_dir/.." && pwd)
config=${1:-release}
version=${KNOB_VERSION:-0.1.0}
build_number=${KNOB_BUILD:-1}
identity=${KNOB_SIGN_IDENTITY:--}
feed_url=${KNOB_FEED_URL:-https://github.com/simranxdhindsa/knob/releases/latest/download/appcast.xml}
bundle_id=${KNOB_BUNDLE_ID:-io.github.simranxdhindsa.knob}
engine_dir=${KNOB_ENGINE_DIR:-$repo_dir/build}
sign() {
    codesign --force --sign "$identity" ${KNOB_SIGN_KEYCHAIN:+--keychain "$KNOB_SIGN_KEYCHAIN"} \
        --options runtime --timestamp=none "$@"
}
bundle="$repo_dir/build/Knob.app"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/presets" "$bundle/Contents/Frameworks"
if [ "${KNOB_UNIVERSAL:-0}" = 1 ]; then
    # One build folder per chip: SwiftPM trips over two --arch builds sharing one.
    for arch in arm64 x86_64; do
        swift build -c "$config" --package-path "$app_dir" --arch "$arch" --scratch-path "$app_dir/.build/$arch"
    done
    bin_dir=$(swift build -c "$config" --package-path "$app_dir" --arch arm64 --scratch-path "$app_dir/.build/arm64" --show-bin-path)
    intel_dir=$(swift build -c "$config" --package-path "$app_dir" --arch x86_64 --scratch-path "$app_dir/.build/x86_64" --show-bin-path)
    lipo -create "$bin_dir/Knob" "$intel_dir/Knob" -output "$bundle/Contents/MacOS/Knob"
else
    swift build -c "$config" --package-path "$app_dir"
    bin_dir=$(swift build -c "$config" --package-path "$app_dir" --show-bin-path)
    cp "$bin_dir/Knob" "$bundle/Contents/MacOS/Knob"
fi
# Sparkle (auto-updates) is universal already. Its helpers are signed inside out, as Sparkle documents.
ditto "$bin_dir/Sparkle.framework" "$bundle/Contents/Frameworks/Sparkle.framework"
sparkle="$bundle/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$sparkle/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
sign "$bundle/Contents/Frameworks/Sparkle.framework"
cp "$repo_dir/presets/"*.fac "$bundle/Contents/Resources/presets/"
cp "$app_dir/Resources/AppIcon.icns" "$bundle/Contents/Resources/AppIcon.icns"
# KnobShift's on-device vocal separation model (Open-Unmix, MIT) and its licence.
ditto "$app_dir/Resources/KnobShift" "$bundle/Contents/Resources/KnobShift"
cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleName</key><string>Knob</string>
<key>CFBundleDisplayName</key><string>Knob</string>
<key>CFBundleExecutable</key><string>Knob</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHumanReadableCopyright</key><string>Free software under the GNU AGPL v3.</string>
<key>NSMicrophoneUsageDescription</key><string>Knob reads the sound your apps play through Knob's own audio device, so it can add effects. It never listens to your microphone.</string>
<key>NSAudioCaptureUsageDescription</key><string>Knob reads the sound your apps play through Knob's own audio device, so it can add effects. It never listens to your microphone.</string>
<key>SUFeedURL</key><string>$feed_url</string>
<key>SUPublicEDKey</key><string>$(cat "$repo_dir/packaging/update-public-key.txt")</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUAutomaticallyUpdate</key><true/>
<key>SUScheduledCheckInterval</key><integer>14400</integer>
</dict></plist>
PLIST
plutil -lint "$bundle/Contents/Info.plist" >/dev/null
# The engine helpers (built by CMake into build/) go inside the app, which starts them.
entitlements="$repo_dir/packaging/audio-input.entitlements"
if [ -x "$engine_dir/knob-engine" ] && [ -x "$engine_dir/knob-supervisor" ]; then
    mkdir -p "$bundle/Contents/Helpers"
    for helper in knob-engine knob-supervisor; do
        cp "$engine_dir/$helper" "$bundle/Contents/Helpers/$helper"
        sign --entitlements "$entitlements" "$bundle/Contents/Helpers/$helper"
    done
else
    echo "Note: engine helpers not built yet (cmake --build build); the power switch can't start the engine." >&2
fi
# The audio device rides inside the app, which installs it on first use (one password prompt).
if [ -d "$engine_dir/driver/Knob.driver" ]; then
    ditto "$engine_dir/driver/Knob.driver" "$bundle/Contents/Resources/Knob.driver"
else
    echo "Note: audio device not built yet (bash driver/build.sh build/driver); Knob can't install it." >&2
fi
# Release builds carry their complete source code (AGPL-3.0), as the About window says.
if [ "$config" = release ] && git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1; then
    python3 -I "$repo_dir/packaging/source-bundle.py" "$bundle/Contents/Resources" >/dev/null
    rm -f "$bundle/Contents/Resources/SOURCE_SHA256SUMS"
fi
sign --entitlements "$repo_dir/packaging/app.entitlements" "$bundle"
codesign --verify --deep --strict "$bundle"
echo "Built $bundle"
