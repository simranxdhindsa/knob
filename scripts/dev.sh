#!/bin/bash
# Dev mode: watch the source, rebuild what changed and relaunch a dev copy of
# Knob, so edits show up in the menu bar a few seconds after saving.
#
#   bash scripts/dev.sh          # watch until Ctrl-C
#   bash scripts/dev.sh --once   # build and launch once, then exit
#   bash scripts/dev.sh --demo   # same, but Knob runs on sample data (no engine or driver needed)
#
# app/ changes      -> swift build (incremental) -> relaunch Knob
# engine/, dsp/     -> rebuild knob-engine + knob-supervisor -> relaunch Knob
# driver/           -> not hot-swappable: needs a reinstall with admin rights
#
# The dev copy lives in build/dev/Knob.app with its own bundle ID, so it never
# touches an installed /Applications/Knob.app or its settings.
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
app_dir=${KNOB_APP_DIR:-$repo_dir/app}
cmake_dir=$repo_dir/build
bundle=$repo_dir/build/dev/Knob.app
bundle_id=io.github.simranxdhindsa.knob.dev
product=${KNOB_PRODUCT:-Knob}
# A fixed "Knob Dev" certificate (scripts/dev-signing-setup.sh) lets macOS remember the audio
# permission across rebuilds. Without it, ad-hoc signing changes every build and macOS asks again.
sign_identity=-
if security find-identity -p codesigning -v 2>/dev/null | grep -q '"Knob Dev"'; then sign_identity="Knob Dev"; fi
stamp=$repo_dir/build/dev/.last-build
poll_seconds=1
once=no
app_args=()
for arg in "$@"; do
    case $arg in
        --once) once=yes ;;
        --demo) app_args+=(--demo) ;;
        *) printf 'Unknown option: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

log() { printf '\033[1;34m[dev %s]\033[0m %s\n' "$(date '+%-I:%M:%S %p')" "$*"; }
warn() { printf '\033[1;33m[dev %s]\033[0m %s\n' "$(date '+%-I:%M:%S %p')" "$*"; }

if [ ! -f "$app_dir/Package.swift" ]; then
    warn "No Swift package at $app_dir yet. Dev mode starts working once the Knob app exists."
    exit 1
fi

# Only one dev mode at a time: two of them rebuild the same build/Knob.app at once and break each
# other's signing ("the code cannot be read by the verifier"). Any other one still running, even
# a forgotten one in the background, is stopped first, the way Ctrl-C stops it, then its helpers.
stop_other_dev_modes() {
    local others=() helpers=() pid parent alive child
    while read -r pid; do
        [ "$pid" = "$$" ] && continue
        parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        # A dev mode's helpers run as its children (and so does this check); its top one is stopped.
        if [ -n "$parent" ] && ps -o command= -p "$parent" 2>/dev/null | grep -q 'scripts/dev\.sh'; then continue; fi
        others+=("$pid")
        while read -r child; do [ -n "$child" ] && helpers+=("$child"); done < <(pgrep -P "$pid" || true)
    done < <(pgrep -f 'scripts/dev\.sh' || true)
    [ ${#others[@]} -gt 0 ] || return 0
    warn "Another dev mode was already running (${others[*]}). Stopping it so the builds don't collide."
    kill -TERM "${others[@]}" 2>/dev/null || true
    for _ in $(seq 1 20); do
        alive=no
        for pid in "${others[@]}"; do kill -0 "$pid" 2>/dev/null && alive=yes; done
        [ "$alive" = no ] && break
        sleep 0.5
    done
    [ ${#helpers[@]} -eq 0 ] || kill -TERM "${helpers[@]}" 2>/dev/null || true
}
stop_other_dev_modes

# Engine helpers are optional: the app can still be iterated on without them.
build_engine() {
    if [ ! -f "$cmake_dir/CMakeCache.txt" ]; then
        warn "Engine not configured (no build/CMakeCache.txt). Skipping engine; see CLAUDE.md Commands."
        return 0
    fi
    log "Building engine..."
    cmake --build "$cmake_dir" -j8 --target knob-engine knob-supervisor >/dev/null
}

# app/build-app.sh knows what goes inside Knob.app (presets, Info.plist), so dev
# mode reuses it and then copies the result into the separate dev bundle.
build_app() {
    log "Building app..."
    local output
    if [ -f "$app_dir/build-app.sh" ]; then
        output=$(bash "$app_dir/build-app.sh" debug 2>&1) || {
            printf '%s\n' "$output" | grep -E 'error:' >&2 || printf '%s\n' "$output" >&2
            return 1
        }
    elif ! output=$(swift build --package-path "$app_dir" --product "$product" 2>&1); then
        printf '%s\n' "$output" | grep -E 'error:' >&2 || printf '%s\n' "$output" >&2
        return 1
    fi
}

assemble_bundle() {
    rm -rf "$bundle"
    if [ -f "$app_dir/build-app.sh" ]; then
        ditto "$repo_dir/build/Knob.app" "$bundle"
    else
        local bin_dir
        bin_dir=$(swift build --package-path "$app_dir" --show-bin-path)
        mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/presets"
        cp "$bin_dir/$product" "$bundle/Contents/MacOS/Knob"
        cp "$repo_dir/presets/"*.fac "$bundle/Contents/Resources/presets/"
        cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Knob</string>
  <key>CFBundleName</key><string>Knob</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.0-dev</string>
  <key>CFBundleVersion</key><string>0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
    fi
    mkdir -p "$bundle/Contents/Helpers"
    # The dev copy always gets its own bundle ID, whatever Info.plist says.
    /usr/libexec/PlistBuddy -c "Delete :CFBundleIdentifier" "$bundle/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bundle_id" "$bundle/Contents/Info.plist"

    for helper in knob-engine knob-supervisor; do
        if [ -x "$cmake_dir/$helper" ]; then
            cp "$cmake_dir/$helper" "$bundle/Contents/Helpers/$helper"
            codesign --force --sign "$sign_identity" --options runtime --timestamp=none \
                --entitlements "$repo_dir/packaging/audio-input.entitlements" \
                "$bundle/Contents/Helpers/$helper" 2>/dev/null
        fi
    done
    codesign --force --sign "$sign_identity" --options runtime --timestamp=none \
        --entitlements "$repo_dir/packaging/app.entitlements" "$bundle" 2>/dev/null
}

dev_app_running() { pgrep -f "$bundle/Contents/MacOS/Knob" >/dev/null; }

# Quit politely first so Knob can stop its engine and hand the output back.
quit_app() {
    dev_app_running || return 0
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        dev_app_running || return 0
        sleep 0.3
    done
    pkill -TERM -f "$bundle/Contents/MacOS/Knob" || true
    sleep 0.5
}

launch_app() {
    # KNOB_DEV_OPEN_POPOVER lets the app reopen its popover straight after a relaunch.
    open --env KNOB_DEV_OPEN_POPOVER=1 "$bundle" ${app_args[@]+--args "${app_args[@]}"}
    log "Knob relaunched."
}

changed_since_stamp() {
    local dir=$1
    [ -d "$dir" ] || return 1
    [ -n "$(find "$dir" -newer "$stamp" -type f \
        \( -name '*.swift' -o -name '*.mm' -o -name '*.m' -o -name '*.cpp' -o -name '*.c' \
           -o -name '*.h' -o -name '*.hpp' -o -name '*.plist' -o -name '*.json' -o -name '*.xcassets' \
           -o -name 'Package.swift' -o -name 'CMakeLists.txt' \) \
        -not -path '*/.build/*' -print -quit 2>/dev/null)" ]
}

rebuild() {
    local need_engine=$1
    if [ "$need_engine" = yes ] && ! build_engine; then
        warn "Engine build failed. Fix the error and save again. Knob keeps running the last good build."
        return 1
    fi
    if ! build_app; then
        warn "App build failed. Knob keeps running the last good build."
        return 1
    fi
    assemble_bundle
    quit_app
    launch_app
}

mkdir -p "$(dirname "$stamp")"
touch "$stamp"
rebuild yes || true

if [ "$once" = yes ]; then
    exit 0
fi

# KnobShift's full log (plans, mixes, transition effects), printed here for testing only and
# never shown in Knob itself. Colours: effects purple, mixes orange, plans cyan, errors red.
knobshift_log="$HOME/Library/Logs/Knob (dev)/knobshift.log"
mkdir -p "$(dirname "$knobshift_log")"
touch "$knobshift_log"
tail -n 0 -F "$knobshift_log" 2>/dev/null |
    while IFS= read -r line; do
        case "$line" in
            *"  EFFECT "*) colour='1;35' ;;
            *"  KNOBMIX"*) colour='0;33' ;;
            *"  ERROR "*) colour='1;31' ;;
            *"  PLAN "*|*"  SYNC "*) colour='0;36' ;;
            *) colour='0;37' ;;
        esac
        printf '\033[%sm[knobshift] %s\033[0m\n' "$colour" "${line#*, }"
    done &
effects_tail=$!

trap 'echo; log "Stopping, quitting dev Knob..."; kill "$effects_tail" 2>/dev/null; pkill -f "tail -n 0 -F $knobshift_log" 2>/dev/null; quit_app; exit 0' INT TERM
log "Watching for changes. Save a file to see it in Knob. Ctrl-C to stop."

# A failed build (often another build running in the same folder at that moment) is tried
# again by itself 5 seconds later, so a fix shows up without saving again.
retry_at=0
retry_engine=no

while true; do
    sleep "$poll_seconds"
    if [ "$retry_at" -gt 0 ] && [ "$(date +%s)" -ge "$retry_at" ]; then
        retry_at=0
        log "Trying the build again..."
        if rebuild "$retry_engine"; then retry_engine=no; else
            retry_at=$(( $(date +%s) + 5 ))
            warn "Still failing. Trying again in 5 seconds."
        fi
        continue
    fi
    engine_changed=no
    app_changed=no
    driver_changed=no
    if changed_since_stamp "$repo_dir/engine" || changed_since_stamp "$repo_dir/dsp"; then
        engine_changed=yes
    fi
    changed_since_stamp "$app_dir" && app_changed=yes
    changed_since_stamp "$repo_dir/driver" && driver_changed=yes
    [ "$engine_changed$app_changed$driver_changed" = nonono ] && continue
    # Stamp before building, so a save made mid-build triggers another round.
    touch "$stamp"
    if [ "$driver_changed" = yes ]; then
        warn "driver/ changed. The driver can't be swapped live: it needs a rebuild and a reinstall with admin rights."
    fi
    [ "$engine_changed$app_changed" = nono ] && continue
    if rebuild "$engine_changed"; then
        retry_at=0
        retry_engine=no
    else
        [ "$engine_changed" = yes ] && retry_engine=yes
        retry_at=$(( $(date +%s) + 5 ))
        log "Trying again in 5 seconds."
    fi
done
