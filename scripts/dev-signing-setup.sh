#!/bin/bash
# One time setup: makes a local "Knob Dev" signing certificate so the dev copy keeps its
# microphone permission across rebuilds. Without it, every rebuild gets a new ad-hoc
# signature and macOS asks for audio access again on each relaunch.
#
#   bash scripts/dev-signing-setup.sh
#
# The certificate lives only in your login keychain and signs only the dev copy
# (build/dev/Knob.app). macOS asks for your password once, to trust it for code signing.
# To remove it later: security delete-identity -c "Knob Dev"
set -euo pipefail

name="Knob Dev"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning -v "$keychain" | grep -q "\"$name\""; then
    echo "\"$name\" is already set up."; exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
password=$(uuidgen)
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$name" \
    -keyout "$work/key.pem" -out "$work/cert.pem" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
    -out "$work/dev.p12" -passout "pass:$password"
security import "$work/dev.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null
# This is the step that asks for your password: it trusts the certificate for code signing.
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/cert.pem"

if security find-identity -p codesigning -v "$keychain" | grep -q "\"$name\""; then
    echo "Done. Restart npm run dev; allow audio access one last time and it will be remembered."
else
    echo "The \"$name\" certificate was not trusted, so dev builds keep the temporary signature." >&2
    exit 1
fi
