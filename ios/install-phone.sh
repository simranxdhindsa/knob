#!/bin/bash
# Builds Knob for iPhone and installs it on a phone picked from the list, then opens it.
#   npm run build mobile              lists the phones and asks which one
#   npm run build mobile 2            uses the second phone in the list, without asking
set -euo pipefail

[ "${1:-}" = mobile ] || { echo "Usage: npm run build mobile" >&2; exit 2; }
shift

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$repo_dir/ios/Info.plist")"
bundle="$repo_dir/build/ios/iphoneos/Knob.app"
list="$(mktemp -t knob-phones)"
trap 'rm -f "$list"' EXIT

# One line per real iPhone: reachable (yes or no), id, name, model. Simulators are left out.
xcrun devicectl list devices --json-output "$list" -q > /dev/null 2>&1 || true
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
[ -n "$phones" ] || { echo "No iPhones found. Connect one with a cable and unlock it." >&2; exit 1; }

reachable=(); ids=(); names=()
while IFS=$'\t' read -r can id name model; do
  reachable+=("$can"); ids+=("$id"); names+=("$name")
  note=""
  [ "$can" = yes ] || note="  (not reachable)"
  printf '  %d. %s, %s%s\n' "${#ids[@]}" "$name" "$model" "$note"
done <<< "$phones"

choice="${1:-}"
if [ -z "$choice" ]; then
  [ -t 0 ] || { echo "Say which phone: npm run build mobile 1" >&2; exit 2; }
  read -r -p "Install on which iPhone? " choice
fi
case "$choice" in
  ''|*[!0-9]*) echo "Type the number of a phone in the list." >&2; exit 2 ;;
esac
if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#ids[@]}" ]; then
  echo "Type the number of a phone in the list." >&2
  exit 2
fi
index=$((choice - 1))
name="${names[$index]}"
if [ "${reachable[$index]}" != yes ]; then
  echo "$name can't be reached. Connect it with a cable or put it on the same Wi-Fi, unlock it and try again." >&2
  exit 1
fi

# The terminal shows each step, how long it has taken and any errors. Compiler warnings stay out.
step() { printf '[%3ds] %s\n' "$SECONDS" "$1"; }

SECONDS=0
step "Building Knob for $name"
set +e
bash "$repo_dir/ios/build-ios.sh" device 2>&1 | while IFS= read -r line; do
  case "$line" in
    "==> "*) step "${line#==> }" ;;
    *": error:"*|"Built "*|"No signing profile"*) echo "       $line" ;;
  esac
done
built="${PIPESTATUS[0]}"
set -e
[ "$built" -eq 0 ] || { step "The build failed."; exit 1; }

step "Installing on $name"
if ! xcrun devicectl device install app --device "${ids[$index]}" "$bundle" 2>&1 | sed 's/^/       /'; then
  step "Couldn't install on $name. Unlock it, keep it connected and try again."
  exit 1
fi
step "Opening Knob"
if ! xcrun devicectl device process launch --device "${ids[$index]}" "$app_id" 2>&1 | sed 's/^/       /'; then
  step "Knob is installed on $name, but it couldn't be opened. Unlock the phone and open it there."
  exit 1
fi
step "Done. Knob is installed and open on $name."
