#!/bin/bash
# Fetches KnobShift's Spotify and YouTube import helpers into build/spotdl-helpers, where
# app/build-app.sh picks them up: spotDL (MIT, a single macOS arm64 executable) and a static
# FFmpeg build (GPLv3), which spotDL uses to tag and package the audio, Deno (MIT), the
# JavaScript runtime yt-dlp now needs to read YouTube's pages, and yt-dlp itself (Unlicense) for
# YouTube links. All are pinned to exact versions and checked
# against their SHA-256, and none is ever committed to this repository.
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
FFMPEG_SHA="a2ad6f0fc42a3c8f5183ef1d53e906d6bb35478d14a6b67175c30ce6c17e9214"
DENO_URL="https://dl.deno.land/release/v2.9.8/deno-aarch64-apple-darwin.zip"
DENO_SHA="5882caa6c9b7ab7adb06f23ec1894ac5bec0b1a5df1195157f75829a0d3cb651"
# yt-dlp (Unlicense) for KnobShift's YouTube import, in its folder edition: it starts in a
# fraction of a second because nothing is unpacked at launch.
YTDLP_URL="https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.26/yt-dlp_macos.zip"
YTDLP_SHA="20d98fa608998eff87d1d35a6e9fb65e4b874639a6cc89addc19da3becde3ef1"

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
# Deno comes zipped: the checked zip is kept, and the program inside it unpacked beside it.
fetch deno.zip "$DENO_URL" "$DENO_SHA"
if [ ! -x "$out/deno" ] || [ "$out/deno.zip" -nt "$out/deno" ]; then
    unzip -oq "$out/deno.zip" deno -d "$out"
    chmod +x "$out/deno"
    touch "$out/deno"   # the zip keeps Deno's build date, which would look older than the zip
fi
# yt-dlp comes zipped as a folder (its program plus _internal). Only the Apple silicon half of
# each universal file is kept, like FFmpeg and Deno, which halves its size.
fetch yt-dlp.zip "$YTDLP_URL" "$YTDLP_SHA"
if [ ! -x "$out/yt-dlp/yt-dlp_macos" ] || [ "$out/yt-dlp.zip" -nt "$out/yt-dlp/yt-dlp_macos" ]; then
    rm -rf "${out:?}/yt-dlp"
    unzip -oq "$out/yt-dlp.zip" -d "$out/yt-dlp"
    find "$out/yt-dlp" -type f -print0 | while IFS= read -r -d '' file; do
        if lipo -archs "$file" 2>/dev/null | grep -q x86_64; then lipo -thin arm64 "$file" -output "$file"; fi
    done
    chmod +x "$out/yt-dlp/yt-dlp_macos"
    touch "$out/yt-dlp/yt-dlp_macos"
fi
echo "Spotify and YouTube helpers ready in $out"
