#!/bin/bash
# Re-records the README demo from the real app: docs/images/knob-demo.gif (README) and
# build/demo/knob-demo.mp4 (posts). Needs Google Chrome, Node 22+ and ffmpeg. About 4 minutes.
#   1. Knob --demo-frames plays a scripted story on the real panel, offscreen, as 30fps PNGs
#   2. stage.html adds the pointer, click ripples and captions around those frames
#   3. render.mjs screenshots stage.html frame by frame in headless Chrome; ffmpeg encodes
set -euo pipefail
cd "$(dirname "$0")/../.."

# Show the version people actually have: the latest release tag, e.g. v3.0.140 -> 3.0.140.
version=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
version=${version:-$(cat VERSION)}
KNOB_VERSION=$version KNOB_BUILD=${version##*.} app/build-app.sh debug

# --demo-frames saves the preset and tab it shows; give the installed Knob its own back afterwards.
bundle=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" build/Knob.app/Contents/Info.plist)
saved_preset=$(defaults read "$bundle" knob.ui.lastPreset 2>/dev/null || true)
saved_tab=$(defaults read "$bundle" knob.ui.selectedTab 2>/dev/null || true)
restore() {
  if [ -n "$saved_preset" ]; then defaults write "$bundle" knob.ui.lastPreset "$saved_preset"
  else defaults delete "$bundle" knob.ui.lastPreset 2>/dev/null || true; fi
  if [ -n "$saved_tab" ]; then defaults write "$bundle" knob.ui.selectedTab "$saved_tab"
  else defaults delete "$bundle" knob.ui.selectedTab 2>/dev/null || true; fi
}
trap restore EXIT

out=build/demo
rm -rf "$out"
build/Knob.app/Contents/MacOS/Knob --demo-frames "$out/frames"
node scripts/demo-video/render.mjs 450 "$out/stage"

ffmpeg -v error -y -framerate 30 -i "$out/stage/f-%05d.png" \
  -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -movflags +faststart "$out/knob-demo.mp4"
ffmpeg -v error -y -framerate 30 -i "$out/stage/f-%05d.png" \
  -vf "fps=20,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=224:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
  docs/images/knob-demo.gif
echo "Wrote docs/images/knob-demo.gif and $out/knob-demo.mp4"
