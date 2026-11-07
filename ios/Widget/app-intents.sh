#!/bin/bash
# App Intents without Xcode. A Live Activity button is an App Intent, and iOS only runs one if
# the bundle carries Metadata.appintents, which Xcode makes in two steps that this script does by
# hand:
#   app-intents.sh flags DIR
#       prints the swiftc flags that make the compiler write what each App Intent says about
#       itself (the "const values") into DIR.
#   app-intents.sh process DIR MODULE BUNDLE_ID SDK TARGET BUNDLE SOURCE...
#       runs Apple's appintentsmetadataprocessor over those, and puts Metadata.appintents in BUNDLE.
set -euo pipefail

mode="$1"; dir="$2"
mkdir -p "$dir"

if [ "$mode" = flags ]; then
  # The protocols the compiler should report conformances to, as Xcode's own list does.
  cat > "$dir/protocols.json" <<'EOF'
["AppIntent","AppEntity","AppEnum","EntityQuery","EntityStringQuery","EntityPropertyQuery","AppShortcutsProvider","AppIntentsPackage","LiveActivityIntent","DynamicOptionsProvider","TransientEntity","WidgetConfigurationIntent","AudioPlaybackIntent","ForegroundContinuableIntent","SystemIntent","URLRepresentableIntent","URLRepresentableEntity","_IntentValueRepresentable","IntentValueQuery"]
EOF
  echo "-emit-const-values -Xfrontend -const-gather-protocols-file -Xfrontend $dir/protocols.json"
  exit 0
fi

module="$3"; bundle_id="$4"; sdk="$5"; target="$6"; bundle="$7"; shift 7
# Xcode's driver puts each file's values next to its object file; with one swiftc run they land
# beside the output.
find "$dir" "$(dirname "$bundle")" -maxdepth 1 -name '*.swiftconstvalues' 2>/dev/null | sort -u > "$dir/constvalues.txt"
printf '%s\n' "$@" > "$dir/sources.txt"
: > "$dir/dependencies.txt"
toolchain="$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")"
case "$sdk" in iphonesimulator|iphoneos) family=iOS ;; *) family=macOS ;; esac
xcrun appintentsmetadataprocessor \
  --output "$bundle" --toolchain-dir "$toolchain" --module-name "$module" \
  --sdk-root "$(xcrun --sdk "$sdk" --show-sdk-path)" \
  --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
  --platform-family "$family" --deployment-target 17.0 --target-triple "$target" \
  --source-file-list "$dir/sources.txt" --swift-const-vals-list "$dir/constvalues.txt" \
  --metadata-file-list "$dir/dependencies.txt" --static-metadata-file-list "$dir/dependencies.txt" \
  --deployment-aware-processing --quiet-warnings
echo "App Intents metadata for $bundle_id: $(ls "$bundle/Metadata.appintents" 2>/dev/null | tr '\n' ' ')"
