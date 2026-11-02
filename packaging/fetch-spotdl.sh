#!/bin/bash
# Fetches KnobShift's Spotify import helpers into build/spotdl-helpers, where app/build-app.sh
# picks them up: spotDL (MIT, a single macOS arm64 executable) and a static FFmpeg build (GPLv3),
# which spotDL uses to tag and package the audio. Both are pinned to exact versions and checked
# against their SHA-256, and neither is ever committed to this repository.
#
# Moving to a newer spotDL is a deliberate change of URL and SHA here: its YouTube matching
# (yt-dlp) needs updates whenever YouTube changes.
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
out="$repo_dir/build/spotdl-helpers"
mkdir -p "$out"

SPOTDL_URL="https://github.com/spotDL/spotify-downloader/releases/download/v4.6.0/spotdl-4.6.0-darwin"
SPOTDL_SHA="957bb335e773ab67fc7a65574b0465ad828849944025a84cdfc9466a4336e3bb"
FFMPEG_URL="https://github.com/eugeneware/ffmpeg-static/releases/download/b4.4/darwin-arm64"
# Pin this the first time the file is fetched (the script prints the value to use).
FFMPEG_SHA=""

fetch() {
    local name=$1 url=$2 sha=$3 target="$out/$1"
    if [ -x "$target" ] && [ -n "$sha" ] && [ "$(shasum -a 256 "$target" | cut -d' ' -f1)" = "$sha" ]; then
        echo "$name: already fetched"
        return
    fi
    echo "$name: downloading"
    curl -fsSL --retry 3 -o "$target.part" "$url"
    local actual
    actual=$(shasum -a 256 "$target.part" | cut -d' ' -f1)
    if [ -n "$sha" ] && [ "$actual" != "$sha" ]; then
        rm -f "$target.part"
        echo "$name: SHA-256 mismatch (expected $sha, got $actual). Not using it." >&2
        exit 1
    fi
    [ -n "$sha" ] || echo "$name: not pinned yet. Pin it in packaging/fetch-spotdl.sh with SHA-256 $actual" >&2
    mv "$target.part" "$target"
    chmod +x "$target"
}

fetch spotdl "$SPOTDL_URL" "$SPOTDL_SHA"
fetch ffmpeg "$FFMPEG_URL" "$FFMPEG_SHA"
echo "Spotify helpers ready in $out"
