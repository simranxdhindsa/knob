#!/bin/bash
# Builds Knob for iPhone and installs it on your default phone, then opens it.
#   npm run build mobile              your default iPhone, or a list if it isn't connected
#   npm run build mobile 2            the second phone in the list, without asking
#   npm run build mobile choose       pick from the list and make that your default
#   npm run build mobile fresh        build again even if no code has changed
# The default is an iPhone 16 Pro Max if one is known, otherwise it asks once, and it is kept in
# ~/.knob-default-phone. With no code changes nothing is built: a build that couldn't be installed
# is used again, and a phone that already has this code just opens Knob. Once installed, the build
# is deleted to free the space.
set -euo pipefail

[ "${1:-}" = mobile ] || { echo "Usage: npm run build mobile [number|choose|fresh]" >&2; exit 2; }
shift

choice=""
choosing=no
fresh=no
for word in "$@"; do
  case "$word" in
    choose) choosing=yes ;;
    fresh) fresh=yes ;;
    *) choice="$word" ;;
  esac
done

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$repo_dir/ios/Info.plist")"
out="$repo_dir/build/ios/iphoneos"
bundle="$out/Knob.app"
# Small notes kept beside the build, so they outlive it being cleaned away.
built_note="$repo_dir/build/ios/phone-built.txt"
installed_note="$repo_dir/build/ios/phone-installed.txt"
default_file="$HOME/.knob-default-phone"
default_model="iPhone 16 Pro Max"
mkdir -p "$repo_dir/build/ios"
list="$(mktemp -t knob-phones)"
trap 'rm -f "$list"' EXIT

# The terminal shows each step, how long it has taken and any errors. Compiler warnings stay out.
step() { printf '[%3ds] %s\n' "$SECONDS" "$1"; }
asking() { [ -t 0 ]; }

# Everything the phone build reads, signing profiles included, since a new one can add the StandBy
# card with no code changed. File sizes and times, as the sound model is too big to read through
# on every run; a file touched but unchanged only costs one extra build.
code_print() {
  (cd "$repo_dir" && {
    find app/Sources/Knob app/Resources/KnobShift ios dsp engine presets -type f ! -name .DS_Store -exec stat -f '%N %z %m' {} +
    find "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" -type f -exec stat -f '%N %z %m' {} + 2>/dev/null || true
  } | sort | shasum | cut -d' ' -f1)
}

# One entry per real iPhone: reachable (yes or no), id, name, model. Simulators are left out.
load_phones() {
  reachable=(); ids=(); names=(); models=()
  xcrun devicectl list devices --json-output "$list" -q > /dev/null 2>&1 || true
  local phones
  phones="$(python3 -I -c '
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except (ValueError, KeyError):
    devices = []
for device in devices:
    hardware = device["hardwareProperties"]
    if hardware.get("reality") != "physical" or hardware.get("deviceType") != "iPhone":
        continue
    reachable = device["connectionProperties"].get("tunnelState") != "unavailable"
    print("\t".join(["yes" if reachable else "no", hardware["udid"],
                     device["deviceProperties"].get("name", "iPhone"), hardware.get("marketingName", "iPhone")]))
' "$list")"
  [ -n "$phones" ] || return 0
  while IFS=$'\t' read -r can id name model; do
    reachable+=("$can"); ids+=("$id"); names+=("$name"); models+=("$model")
  done <<< "$phones"
}

show_phones() {
  local i note
  for ((i = 0; i < ${#ids[@]}; i++)); do
    note=""
    [ "${reachable[$i]}" = yes ] || note="  (not reachable)"
    [ "${ids[$i]}" != "$saved" ] || note="$note  (default)"
    printf '  %d. %s, %s%s\n' "$((i + 1))" "${names[$i]}" "${models[$i]}" "$note"
  done
}

position_of() {
  local i
  for ((i = 0; i < ${#ids[@]}; i++)); do
    if [ "${ids[$i]}" = "$1" ]; then echo "$i"; return; fi
  done
  echo -1
}

use_number() {
  case "$1" in
    ''|*[!0-9]*) echo "Type the number of a phone in the list." >&2; return 2 ;;
  esac
  if [ "$1" -lt 1 ] || [ "$1" -gt "${#ids[@]}" ]; then
    echo "Type the number of a phone in the list." >&2
    return 2
  fi
  target=$(($1 - 1))
  if [ "${reachable[$target]}" != yes ]; then
    echo "${names[$target]} can't be reached. Connect it with a cable or put it on the same Wi-Fi and unlock it." >&2
    target=-1
    return 1
  fi
}

# Finds the phone to install on and sets `target`, or leaves it at -1 if there is none right now.
pick_phone() {
  target=-1
  saved=""
  [ ! -f "$default_file" ] || saved="$(cat "$default_file")"
  load_phones
  if [ -n "$choice" ]; then
    # A mistyped number stops here, before a long build. A phone that's away is waited for.
    local result=0
    use_number "$choice" || result=$?
    [ "$result" -ne 2 ] || exit 2
    return 0
  fi
  if [ "$choosing" = no ]; then
    local i
    if [ -z "$saved" ]; then
      for ((i = 0; i < ${#ids[@]}; i++)); do
        if [ "${models[$i]}" = "$default_model" ]; then
          saved="${ids[$i]}"
          echo "$saved" > "$default_file"
          step "${names[$i]} is now your default iPhone."
          break
        fi
      done
    fi
    if [ -n "$saved" ]; then
      i="$(position_of "$saved")"
      if [ "$i" -ge 0 ] && [ "${reachable[$i]}" = yes ]; then
        target="$i"
        return 0
      fi
      if [ "$i" -ge 0 ]; then step "${names[$i]}, your default iPhone, isn't connected."; else step "Your default iPhone isn't connected."; fi
    fi
  fi
  if [ "${#ids[@]}" -eq 0 ]; then
    step "No iPhones found. Connect one with a cable and unlock it."
    return 0
  fi
  show_phones
  if ! asking; then
    step "Say which phone: npm run build mobile 1"
    return 0
  fi
  local answer
  read -r -p "Install on which iPhone? " answer
  use_number "$answer" || return 0
  if [ -z "$saved" ] || [ "$choosing" = yes ]; then
    echo "${ids[$target]}" > "$default_file"
    step "${names[$target]} is now your default iPhone."
  fi
}

build() {
  step "Building Knob"
  rm -f "$built_note"
  set +e
  bash "$repo_dir/ios/build-ios.sh" device 2>&1 | while IFS= read -r line; do
    case "$line" in
      "==> "*) step "${line#==> }" ;;
      *": error:"*|"Built "*|"No signing profile"*) echo "       $line" ;;
    esac
  done
  local built="${PIPESTATUS[0]}"
  set -e
  [ "$built" -eq 0 ] || { step "The build failed."; exit 1; }
  echo "$print" > "$built_note"
}

open_knob() {
  step "Opening Knob"
  if ! xcrun devicectl device process launch --device "${ids[$target]}" "$app_id" 2>&1 | sed 's/^/       /'; then
    step "Knob is installed on ${names[$target]}, but it couldn't be opened. Unlock the phone and open it there."
    exit 1
  fi
}

SECONDS=0
print="$(code_print)"
pick_phone
choice=""
choosing=no

# The phone already runs this exact code: nothing to build or install.
if [ "$target" -ge 0 ] && [ "$fresh" = no ] && [ -f "$installed_note" ] \
  && [ "$(cat "$installed_note")" = "$print ${ids[$target]}" ]; then
  step "No code changes since the last install on ${names[$target]}."
  open_knob
  step "Done. Knob is open on ${names[$target]}."
  exit 0
fi

if [ "$fresh" = no ] && [ -d "$bundle" ] && [ -f "$built_note" ] && [ "$(cat "$built_note")" = "$print" ]; then
  step "No code changes, so the last build is used."
else
  build
fi
step "Build size: $(du -sh "$bundle" | cut -f1)"

# A phone that dropped away never costs a rebuild: the build waits for it.
while :; do
  if [ "$target" -ge 0 ]; then
    step "Installing on ${names[$target]}"
    if xcrun devicectl device install app --device "${ids[$target]}" "$bundle" 2>&1 | sed 's/^/       /'; then
      break
    fi
    step "Couldn't install on ${names[$target]}. Unlock it and keep it connected."
  fi
  if ! asking; then
    step "The build is kept. Run this again once the iPhone is connected: it installs this build without building again."
    exit 1
  fi
  read -r -p "The build is kept. Connect and unlock the iPhone, then press Return (Control C to stop). " _
  pick_phone
done

echo "$print ${ids[$target]}" > "$installed_note"
freed="$(du -sh "$out" | cut -f1)"
rm -rf "$out"
rm -f "$built_note"
step "Cleaned the build, $freed freed."
open_knob
step "Done. Knob is installed and open on ${names[$target]}."
