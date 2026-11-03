# Releasing and auto-updates

Every push to `main` publishes a release. Installed copies of Knob update themselves from it.

```
push to main ─▶ .github/workflows/release.yml (GitHub's macos-26 runner, free for public repos)
                 └─ scripts/release/release.sh --publish
                      ├─ engine + driver + app, Apple silicon + Intel, signed "Knob Release"
                      ├─ Knob.dmg (Knob-Install.pkg, read-me, uninstaller, source), Knob-Install.pkg
                      ├─ update archive, signed with the Sparkle key
                      └─ GitHub release vX.Y.N + appcast.xml
installed Knob ─▶ releases/latest/download/appcast.xml (at launch, then every 4 hours)
                 └─ downloads, checks the signature, installs, relaunches (app/Sources/Knob/Updater.swift)
```

- **Version:** `VERSION` holds `major.minor`; the last part and the build number are the commit count, so every release is newer than the one before. Bump `VERSION` by hand for a big release.
- **Release notes** come from the version's section of `CHANGELOG.md` (`## 2.0`): `### New features` first, then `### Fixes`, written for users. They are never built from commit messages. Update that section before pushing to `main`; without one, the notes say only "Small improvements and fixes."
- **Docs-only pushes** (`*.md`, `docs/`, `.claude/`, `LICENSE`) don't release.
- **Driver changes:** updates always ship the app alone (`Knob-<version>.zip`). Sparkle refuses package installers when the app has no Apple Developer ID signature ("updating apps with package installers is disabled when Autoupdate is not signed"), which broke 2.0.104. The app carries the driver and installs a newer one itself: turning Knob on finds an older installed driver (`CFBundleVersion` in `driver/Info.plist`, compared by `DriverInstaller.installedIsOutdated`) and shows INSTALL, one password prompt. **Bump `CFBundleVersion` in `driver/Info.plist` with every driver change**, or installed Macs keep the old one.
- **App-only updates** install silently: `postinstall` gives the user ownership of `/Applications/Knob.app`, so no password is needed.
- **Dev builds** (`npm run dev`, bundle ID ending in `.dev`) never update themselves.
- **Install methods:** the standard installer (`Knob-Install.pkg`) is the only supported one; it installs the driver. Homebrew (`Casks/knob.rb`) runs the same package. Dragging `Knob.app` into Applications does not install the driver.

## Keys (never in the repo)

Kept in `~/.knob-release-keys/` (folder mode 700) and in the repo's GitHub secrets:

| File | GitHub secret | What it does |
|---|---|---|
| `sparkle-private-key.txt` | `SPARKLE_PRIVATE_KEY` | Signs updates. Installed copies only accept updates signed with it (public half: `packaging/update-public-key.txt`). |
| `signing-p12-base64.txt` + `signing-p12-password.txt` | `KNOB_SIGNING_P12_BASE64`, `KNOB_SIGNING_P12_PASSWORD` | Self-signed "Knob Release" certificate. A fixed certificate keeps macOS permissions (audio access) across updates. |

- **Losing the Sparkle key means installed copies can never update again.** Keep a backup of the folder in a password manager. The Sparkle key is also in the login keychain (account `knob`).
- Upload or refresh the secrets with `npm run release:secrets` (needs `gh auth login`). Key material never goes through a chat or a web form.
- Without an Apple Developer ID, the first install shows Gatekeeper's "can't verify" warning (Open Anyway). Updates aren't affected. Moving to a Developer ID later: sign with it in `release.sh`, keep the same Sparkle key, and existing installs keep updating.

## Trying a release locally

`npm run release:trial` builds everything into `dist/vX.Y.N/` with the local keys and publishes nothing. To test the updater itself without GitHub, build an old version with `KNOB_FEED_URL=http://127.0.0.1:8765/appcast.xml KNOB_BUNDLE_ID=io.github.simranxdhindsa.knob.updatetest`, serve a newer signed archive and appcast with `python3 -m http.server`, and run the old one with `--demo` so it doesn't start a second engine.
