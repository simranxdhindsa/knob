#!/bin/bash
# Builds Knob's StandBy extension (the Live Activity and the small widget) with plain swiftc,
# like the app. Called by ios/build-ios.sh:
#   ios/Widget/build-standby.sh SDK TARGET OUT
# It leaves OUT/standby/KnobStandby.appex, ready to be copied into Knob.app/PlugIns and signed.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$here/../.." && pwd)"
sdk="$1"; target="$2"; out="$3"
work="$out/standby"
appex="$work/KnobStandby.appex"
sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
rm -rf "$work"
mkdir -p "$work" "$appex"

# -parse-as-library for @main, -application-extension because it runs inside iOS's widget host,
# and _NSExtensionMain as its entry point, which is what Xcode does for a widget.
sources=("$here"/*.swift "$repo_dir/app/Sources/Knob/Theme/Palette.swift")
intent_flags="$("$here/app-intents.sh" flags "$work/intents")"
# Two steps: the compiler writes the App Intents "const values" beside the object file.
# shellcheck disable=SC2086
xcrun --sdk "$sdk" swiftc -c -wmo -target "$target" -sdk "$sysroot" -swift-version 5 -Onone -g \
  -parse-as-library -application-extension -module-name KnobStandby $intent_flags \
  "${sources[@]}" -o "$work/KnobStandby.o"
xcrun --sdk "$sdk" swiftc -target "$target" -sdk "$sysroot" "$work/KnobStandby.o" \
  -framework WidgetKit -framework SwiftUI -framework AppIntents -framework ActivityKit \
  -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -rpath -Xlinker @executable_path/../../Frameworks \
  -o "$appex/KnobStandby"

cp "$here/Info.plist" "$appex/Info.plist"
"$here/app-intents.sh" process "$work/intents" KnobStandby io.github.simranxdhindsa.knob.phone.standby "$sdk" "$target" "$appex" \
  "${sources[@]}"
echo "Built $appex"
