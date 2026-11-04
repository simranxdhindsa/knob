#!/bin/bash
# Stops the iPhone build if a view fixes a colour or theme instead of following light and dark.
# Views take their colours from `Surface` (Theme/Surface.swift). Only what really sits on the
# always dark analyser may use `Screen` directly.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
shared="$repo_dir/app/Sources/Knob"

# The analyser, its contents, and the launch icon, which are dark in both themes on purpose.
analyser='/(InsetScreen|SpectrumView|ScreenSection|KnobShiftScreen|AppIconView)\.swift$'

files=()
while IFS= read -r file; do files+=("$file"); done < <(
  { ls "$shared"/Components/*.swift "$repo_dir"/ios/Sources/*.swift
    while read -r view; do echo "$shared/Views/$view.swift"; done < "$repo_dir/ios/shared-views.txt"
  } | grep -vE 'Spotify|YouTube|Google|SpotDL|HelperProcess|MacEngine|UpdateStatusLabel' | grep -vE "$analyser"
)

# Spotify's green and YouTube's red are brand colours, the same in both themes.
found="$(grep -nE '\bScreen\.|preferredColorScheme|\\\.colorScheme, \.(dark|light)|foregroundStyle\(\.(white|black)\)' "${files[@]}" \
  | grep -vE 'Screen\.(spotify|youtube)' || true)"

if [ -n "$found" ]; then
  echo "These lines fix a colour or theme, so they would look wrong in light or dark mode:" >&2
  echo "$found" | sed "s|$repo_dir/||" >&2
  echo "Use the surface colours from Theme/Surface.swift instead." >&2
  exit 1
fi
echo "Theme check passed: ${#files[@]} files follow light and dark."
