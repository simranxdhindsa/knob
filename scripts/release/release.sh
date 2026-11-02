#!/bin/bash
# Builds a Knob release and, with --publish, puts it on GitHub Releases, where every installed
# Knob finds it and updates itself. .github/workflows/release.yml runs this on each push to main.
#
#   bash scripts/release/release.sh            # trial run: build everything into dist/vX.Y.Z/
#   bash scripts/release/release.sh --publish  # also publish the GitHub release (needs GH_TOKEN)
#
# Secrets come from the environment (GitHub secrets in CI) or, locally, from ~/.knob-release-keys:
#   KNOB_SIGNING_P12_BASE64, KNOB_SIGNING_P12_PASSWORD   release certificate: macOS keeps Knob's
#                                                        permissions across updates
#   SPARKLE_PRIVATE_KEY                                  update key: Knob refuses unsigned updates
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "$0")/../.." && pwd)
repo=simranxdhindsa/knob
sparkle_version=2.10.0
sparkle_sha256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
keys=$HOME/.knob-release-keys

publish=no
[ "${1:-}" = --publish ] && publish=yes

build_number=$(git -C "$repo_dir" rev-list --count HEAD)
version="$(tr -d '[:space:]' < "$repo_dir/VERSION").$build_number"
tag="v$version"
out="$repo_dir/dist/$tag"
work=$(mktemp -d /private/tmp/knob-release.XXXXXX)
keychain="$work/release.keychain-db"
original_keychains=$(security list-keychains -d user | tr -d '"')
cleanup() {
    if [ -f "$keychain" ]; then
        # shellcheck disable=SC2086
        security list-keychains -d user -s $original_keychains
        security delete-keychain "$keychain" 2>/dev/null
    fi
    rm -rf "$work"
}
trap cleanup EXIT
log() { printf '\n==> %s\n' "$*"; }

if [ -z "${KNOB_SIGNING_P12_BASE64:-}" ] && [ -f "$keys/signing-p12-base64.txt" ]; then
    KNOB_SIGNING_P12_BASE64=$(cat "$keys/signing-p12-base64.txt")
    KNOB_SIGNING_P12_PASSWORD=$(cat "$keys/signing-p12-password.txt")
fi
if [ -z "${SPARKLE_PRIVATE_KEY:-}" ] && [ -f "$keys/sparkle-private-key.txt" ]; then
    SPARKLE_PRIVATE_KEY=$(cat "$keys/sparkle-private-key.txt")
fi
if [ "$publish" = yes ] && { [ -z "${KNOB_SIGNING_P12_BASE64:-}" ] || [ -z "${SPARKLE_PRIVATE_KEY:-}" ]; }; then
    echo "Release keys missing. Run scripts/release/set-github-secrets.sh once (see docs/releasing.md)." >&2
    exit 1
fi

log "Knob $version"
if [ -n "${KNOB_SIGNING_P12_BASE64:-}" ]; then
    keychain_password=$(uuidgen)
    security create-keychain -p "$keychain_password" "$keychain"
    security set-keychain-settings -lut 21600 "$keychain"
    security unlock-keychain -p "$keychain_password" "$keychain"
    (umask 077; printf '%s' "$KNOB_SIGNING_P12_BASE64" | base64 -D > "$work/signing.p12")
    security import "$work/signing.p12" -k "$keychain" -P "$KNOB_SIGNING_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null
    rm -f "$work/signing.p12"
    # Older codesign (GitHub's runners) only finds identities in keychains on the search list.
    # shellcheck disable=SC2086
    security list-keychains -d user -s "$keychain" $original_keychains
    if ! security find-identity -p codesigning "$keychain" | grep -q '"Knob Release"'; then
        echo "The release certificate didn't import: the identity \"Knob Release\" isn't in the keychain." >&2
        security find-identity -p codesigning "$keychain" >&2
        exit 1
    fi
    export KNOB_SIGN_IDENTITY="Knob Release" KNOB_SIGN_KEYCHAIN="$keychain"
else
    echo "Note: no release certificate, so this trial build is signed ad-hoc."
fi

log "Sound engine and driver (Apple silicon + Intel)"
engine_dir="$work/build"
cmake -S "$repo_dir" -B "$engine_dir" -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release \
    "-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 >/dev/null
cmake --build "$engine_dir" -j8 --target knob-engine knob-supervisor >/dev/null
bash "$repo_dir/driver/build.sh" "$engine_dir/driver" >/dev/null
sh "$repo_dir/tests/driver-build.sh" "$engine_dir/driver/Knob.driver"

log "App"
KNOB_VERSION=$version KNOB_BUILD=$build_number KNOB_UNIVERSAL=1 KNOB_ENGINE_DIR=$engine_dir \
    bash "$repo_dir/packaging/fetch-spotdl.sh"
    bash "$repo_dir/app/build-app.sh" release

log "Installer"
rm -rf "$out"
bash "$repo_dir/packaging/build-installer.sh" "$repo_dir/build/Knob.app" "$engine_dir/driver/Knob.driver" "$out"

# An update that changes the driver ships the installer (one password prompt); otherwise the
# app alone, which installs silently.
previous_tag=$(git -C "$repo_dir" describe --tags --abbrev=0 --match 'v*' HEAD 2>/dev/null || true)
installation_type=
archive="Knob-$version.zip"
if [ -n "$previous_tag" ] && ! git -C "$repo_dir" diff --quiet "$previous_tag" HEAD -- driver/; then
    archive="Knob-Install-$version.pkg.zip"
    installation_type=package
    (cd "$out" && ditto -c -k --sequesterRsrc Knob-Install.pkg "$archive")
    rm -f "$out/Knob-$version.zip"
    echo "The driver changed since $previous_tag: this update installs the full package."
fi

log "Update feed"
sparkle_dir="$work/sparkle"
mkdir -p "$sparkle_dir"
curl -fsSL -o "$work/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz"
echo "$sparkle_sha256  $work/sparkle.tar.xz" | shasum -a 256 -c - >/dev/null
tar -xf "$work/sparkle.tar.xz" -C "$sparkle_dir" bin/sign_update
signature=
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    (umask 077; printf '%s' "$SPARKLE_PRIVATE_KEY" > "$work/sparkle-key")
    signature=$("$sparkle_dir/bin/sign_update" --ed-key-file "$work/sparkle-key" "$out/$archive")
    rm -f "$work/sparkle-key"
else
    echo "Note: no update key, so installed copies would refuse this trial build's update."
fi
if [ -n "$previous_tag" ]; then
    git -C "$repo_dir" log --no-merges --format='%s' "$previous_tag..HEAD" -- . ':!*.md' ':!docs' ':!.claude' \
        > "$work/changes.txt"
else
    cat > "$work/changes.txt" <<'NOTES'
First release of Knob: a volume control that works on HDMI monitors and other outputs with no volume of their own, plus presets, effects and a 10-band equalizer
Knob now updates itself, so you never need to download it again
NOTES
fi
python3 -I "$repo_dir/scripts/release/appcast.py" --version "$version" --build "$build_number" \
    --url "https://github.com/$repo/releases/download/$tag/$archive" --signature "$signature" \
    --installation-type "$installation_type" --changes "$work/changes.txt" \
    --appcast "$out/appcast.xml" --notes "$out/release-notes.md"
(cd "$out" && shasum -a 256 Knob.dmg Knob-Install.pkg "$archive" appcast.xml > SHA256SUMS)
ls -l "$out"

if [ "$publish" = no ]; then
    log "Trial run done: $out (nothing published)"
    exit 0
fi

log "Publishing $tag"
# Draft first, then publish: installed copies never see a release whose files are still uploading.
gh release create "$tag" --repo "$repo" --target "$(git -C "$repo_dir" rev-parse HEAD)" --draft \
    --title "Knob $version" --notes-file "$out/release-notes.md" \
    "$out/Knob.dmg" "$out/Knob-Install.pkg" "$out/$archive" "$out/appcast.xml" "$out/SHA256SUMS"
gh release edit "$tag" --repo "$repo" --draft=false --latest
log "Published https://github.com/$repo/releases/tag/$tag"
