#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir="$root/build/precision-startup-tests"
mkdir -p "$test_build_dir"
swiftc "$root/tests/precision-startup-test.swift" \
    "$root/app/Sources/Knob/Components/RotaryDrag.swift" \
    "$root/app/Sources/Knob/Components/NumericEntry.swift" \
    "$root/app/Sources/Knob/Engine/StartupFailure.swift" \
    -o "$test_build_dir/precision-startup-test"
"$test_build_dir/precision-startup-test" "$@"
