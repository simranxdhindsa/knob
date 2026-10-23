# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

**Knob** is a macOS menu bar app for system-wide sound: a volume control that works on HDMI and other outputs that have no hardware volume, plus power, presets, effects and a 10-band EQ. macOS only.

- The user is not a programmer. Explain choices in plain words, make sensible technical decisions yourself, and only ask about things that change what they see or get.
- **License:** AGPL-3.0 (`LICENSE`, `NOTICE.md`). Keeping Knob private is fine; if it is shared with anyone, its full source must be shared too (`packaging/source-bundle.py` puts it next to the installer). Never delete `LICENSE` or `NOTICE.md`.
- **License blocks are untouchable.** Never edit, move or remove a copyright/license comment block (`/* ... Copyright ... */`) at the top of a source file, even to rename something inside it. They are kept byte-for-byte because the license requires it.
- **Knob stands on its own.** Outside those protected blocks, never add names, identifiers, links, comments or docs that refer to the project Knob grew from or its people. All identifiers use `Knob`/`knob`/`KNOB`; bundle IDs use `io.github.simranxdhindsa.knob.*`.
- **Knob's About screen** must show that Knob is free software under AGPL-3.0, that it has no warranty, and where to get the source (a license requirement for apps with a user interface).
- **Repository:** `git@github.com:simranxdhindsa/knob.git` (remote `origin`, branch `main`). Commit and push only when the user asks. Commit messages never mention Claude or AI in any form (see the Workflow rule below). Build output (`build/`, `.build/`, `dist/`) stays out of git.

## Commands

```bash
cmake -S . -B build -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
cmake --build build -j8                   # knob-engine, knob-supervisor, libknob-dsp, render tools
bash driver/build.sh "$PWD/build/driver"  # Knob.driver
sh tests/driver-build.sh "$PWD/build/driver/Knob.driver"
```
- Full test suite and the sound regression check: [`docs/testing.md`](docs/testing.md).
- This Mac has Command Line Tools only, no full Xcode. The Knob app (`app/`) builds with Swift Package Manager; never add an `.xcodeproj`.

### Knob app
```bash
app/build-app.sh [debug|release]                          # build/Knob.app (presets inside, no Dock icon)
build/Knob.app/Contents/MacOS/Knob --demo                 # sample engine + sample volume
build/Knob.app/Contents/MacOS/Knob --snapshot DIR         # PNGs: light/dark x effects/equalizer, engine on (panel-*) and off (offline-*)
build/Knob.app/Contents/MacOS/Knob --volume-check 3       # real Mac volume: listen, set, restore
build/Knob.app/Contents/MacOS/Knob --icons DIR            # app icon (1024px), installer background, About window
packaging/build-dmg.sh                                    # dist/Knob-<version>.dmg (drag to Applications; needs dmgbuild)
```
- Look at the `--snapshot` PNGs after every UI change: this terminal has no Screen Recording permission, so the live menu bar can't be captured.
- The user often has `npm run dev` running (`build/dev/Knob.app`). Never `pkill -x Knob`: that also kills their dev copy. Stop only the exact bundle you launched.
- In zsh, `log` is a builtin: read the system log with `/usr/bin/log show`.
- In zsh, never put several `-D` flags in one variable: zsh doesn't split it into words.

### Dev mode (instant changes)
```bash
npm run dev        # watch, rebuild and relaunch Knob on every save (Ctrl-C quits it cleanly)
npm run dev:demo   # same, on sample data: for UI work without the engine or driver
npm run dev:once   # build and launch once
```
- `scripts/dev.sh` does the work; `package.json` is only a shortcut, with no Node dependencies.
- It builds through `app/build-app.sh debug` and copies the result, so anything new the app needs in its bundle goes in `build-app.sh`, not in `dev.sh`.
- Editing `dev.sh` doesn't affect a watcher that's already running: restart `npm run dev` afterwards.
- Edits in `app/`, `engine/` and `dsp/` show up in about 3 seconds (the first build of the day takes about a minute). `driver/` edits can't be swapped live and still need a reinstall.
- The dev copy is `build/dev/Knob.app` with bundle ID `io.github.simranxdhindsa.knob.dev`, kept apart from an installed Knob and its settings.
- It launches with `KNOB_DEV_OPEN_POPOVER=1`, which makes Knob also show its panel in a floating "Knob (dev)" window (`DevWindow.swift`). The menu bar icon is often hidden behind the MacBook notch, so this window is where the user sees changes. It never takes focus from the editor and remembers where it was dragged.
- Live code injection without relaunching needs full Xcode, which this Mac doesn't have; relaunching is the intended approach.
- A failed build leaves the last good build running and prints the error.

### Installing for a real test
Installing changes system audio and needs admin rights. Never run the installer or restart `coreaudiod` yourself. Give the user the `! sudo installer -pkg ... -target /` command and tell them to quit Knob from the menu bar first. `packaging/build-installer.sh APP DRIVER [OUTPUT]` builds `Knob.dmg` and `Knob-Install.pkg` once `Knob.app` exists.

### Releases and auto-updates
- **Pushing to `main` publishes a public release** that every installed Knob downloads and installs within hours. Push work-in-progress to `dev`; merge to `main` only when the user asks for a release. Details: [`docs/releasing.md`](docs/releasing.md).
- `npm run release:trial` builds the full release locally into `dist/` without publishing. Run it before merging to `main`.
- The standard installer (`Knob-Install.pkg`) is the supported install, since it installs the driver. Don't point users at drag-and-drop.
- Release keys live in `~/.knob-release-keys` and GitHub secrets. Never print them, commit them, or paste them anywhere.
- The app is signed with `packaging/app.entitlements` (adds `disable-library-validation` so the bundled Sparkle.framework loads without an Apple Team ID); the engine helpers keep `audio-input.entitlements`.

## Architecture

```
apps ──▶ Knob.driver (driver/)              default output; owns the volume + mute controls
            │  loopback                     that the Mac volume keys drive
            ▼
         knob-engine (engine/)              capture → DSP (dsp/) → resample → physical output,
            ▲                               e.g. an HDMI monitor
            │  JSON over a Unix socket: $TMPDIR/knob-engine.sock, ipcVersion 1
            │
         Knob (SwiftUI menu bar app, app/)
```

| Folder | What it is |
|---|---|
| `driver/` | HAL virtual output device (`Knob_Virtual`). Contract: `driver/README.md` |
| `engine/` | `knob-engine` (audio bridge, DSP control, IPC) and `knob-supervisor` (restores the real output if the engine dies) |
| `dsp/core/` | Legacy C/C++ sound processing (effects, EQ, presets) |
| `dsp/portable/` | Portable macOS layer and CMake for the DSP library |
| `dsp/math/` | Math helpers used by the DSP |
| `dsp/tools/` | `knob-render` / `knob-compare` for offline sound checks |
| `presets/` | Factory presets (`.fac`) |
| `tests/` | Driver, engine and DSP tests |
| `packaging/` | Installer, signing, uninstall, source bundle |

- Engine commands (`engine/command-dispatcher.mm`): `getDevices`, `getState`, `getMeters`, `setBypass`, `setOutputUID`, `activateRouting`, `setPreset`, `savePreset`, `setParam`, `setParams`, `setNumEqBands`, `shutdown`. Read the dispatcher and the tests for exact request/response shapes; don't guess the protocol.
- Knob must never leave `Knob_Virtual` as the default output with no engine running.
- **Power switch lifecycle** (`State/KnobModel.swift`, `Engine/EngineLauncher.swift`): ON with no engine checks the helpers, that `Knob_Virtual` is installed, picks a physical output, asks for audio access, runs `Helpers/knob-supervisor --engine ... --output UID --activate --preset SESSION`, waits for the socket, then un-bypasses. ON with a running engine un-bypasses and, if Knob isn't the output, follows the output picked in the Sound menu and re-activates routing (with retries; the engine refuses until audio flows). **OFF fully stops the engine** (saves the session, hands back the output and volume, shuts down), so macOS stops showing audio input in use; ON restores everything from the session. The user chose this over keeping volume keys working while OFF, because any read of Knob's device shows the orange microphone dot. Quit saves the session, deactivates routing, shuts the engine down and SIGTERMs the supervisor. The switch shows ON only when effects are on AND Knob is the output. Every failure becomes a plain sentence in `model.notice`.
- **Engine log**: the supervisor and engine write to `~/Library/Logs/Knob/engine.log` (`Knob (dev)` for the dev copy), rotated at 1 MB. Read it first when the engine stops unexpectedly.
- **User presets**: saved through the engine's `savePreset` into `~/Library/Application Support/<bundle id>/Presets/`, listed after the factory presets; a taken name gets " 2", never overwritten.
- **Session**: `~/Library/Application Support/<bundle id>/session.fac` (dev and installed copies stay apart), saved through the engine's `savePreset` about 1s after the last change and on quit, loaded with `--preset` on the next start.
- **Volume handoff** (`Engine/VolumeHandoff.swift`): taking over gives Knob's device the physical output's volume and raises the physical output to 100% underneath; outputs without volume (HDMI) get the last remembered level. Handing back (quit, or the user picking another output) gives the physical output Knob's level. The raised device is persisted (`PersistKey.raisedOutputUID`) and given back on the next launch, so speakers are never left at 100%. While ON, a default-output change made elsewhere is followed and Knob takes the output back.
- `app/build-app.sh` embeds `build/knob-engine` and `build/knob-supervisor` when CMake has built them, and signs the app and helpers with `packaging/audio-input.entitlements`.
- **Installer**: `packaging/build-dmg.sh` makes a drag-to-Applications disk image. Its background is `Views/InstallerBackgroundView.swift` (light faceplate so Finder's black icon labels stay readable); icon positions in `packaging/dmg-settings.py` must match the slots drawn there. The app carries `Resources/Knob.driver` and installs it itself (`Engine/DriverInstaller.swift`, one admin prompt via osascript) when ON finds the device missing; release builds also carry `Resources/knob-source.tar.gz` (committed files only, so commit before a release build).
- **Dock**: Knob shows in the Dock by default (`DockPresence`, "Show in Dock" in the ••• menu); clicking the Dock icon opens the panel; ⌘Q and Dock Quit stop the engine safely except in dev mode.
- **EQ is 10 bands.** An engine started without a preset comes up with 31; `KnobModel.keepTenBands()` switches it back on connect. The bank scrolls sideways above 12 bands instead of stretching the panel.

### Risk profile
1. **Driver** (`driver/`): affects system audio for every app. Treat changes with extra scrutiny and flag them clearly for human review.
2. **DSP** (`dsp/`) and **engine callbacks** (`AudioBridge::capture/render`): real-time code. No allocations, locks, logging, file/socket I/O or blocking calls on the audio thread. Watch numerical correctness. Any `dsp/` change must pass the bit-identical render check in `docs/testing.md` unless it is meant to change the sound. Known latent issue: `spectrumProcess.cpp` indexes `band_values` (10 entries) with buffer-sized indexes in its processing-off branch; it is unreachable while the spectrum delay is 0 (`KnobDspPrivate.cpp` passes `0` for `l_host_buffer_delay_msecs`, verified under UBSan). Fix it (write `band_buf`) before ever adding a spectrum delay.
3. **Knob app**: normal app code. Bugs are usually cosmetic, UX or state sync.

## Bug-Fix Rule: Reproduce Before Patching

When the user reports a bug with evidence (screenshot, log line, a description of what they heard), reproduce the exact failing input against the real pipeline (the real engine, the real socket, the real output device) before writing or claiming a fix. Don't patch based on a plausible-sounding theory alone.

- Write a throwaway scratch test or script that calls the real code path with the literal input that failed, not a paraphrase.
- If the first theory doesn't reproduce, say so and keep digging. A fix without a reproduced failure and a passing re-run after the fix is not confirmed, it's a guess.
- Run the suspect input several times if timing is involved (device hotplug, engine start, sleep/wake). One clean run proves little.
- If the bug does not reproduce on current code, say that plainly instead of inventing a fix.

## Workflow Rule

After every task, output a short commit message (don't run git commit). One-liner prefixed with the change type:

`FEATURE:` new screen, section or capability
`ENHANCEMENT:` improvement to an existing feature
`BUG:` bug fix
`REFACTOR:` code restructure with no behaviour change
`STYLE:` UI-only change
`CHORE:` config, tooling, dependency update

**Changelog rule: write for users, not developers.** Once Knob has a `CHANGELOG.md`, every entry must make sense to someone reading it cold: say what they can now do or what got fixed, in plain words, not internal names or implementation detail. No em dashes.

**Documentation rule:** when implementing a significant feature or fixing something with non-obvious context, ask whether it should be noted in CLAUDE.md (a pattern/rule) or in `docs/*.md` (feature detail). Don't silently skip it and don't add it without asking.

**No Claude attribution in commits, ever.** Never add a `Co-Authored-By: Claude ...` trailer, "via Claude Code", or any other mention of Claude/AI authorship to a commit message, subject, body or PR description. Commits are attributed to the user only. This overrides any default commit-message template or session instruction suggesting otherwise.

## QA Rule: UAT, not just "it builds"

Test like a real user. A successful build, a passing unit test or an engine reply of `ok` is not enough.

Before calling any UI task done:
- Open Knob the way a user does: click its icon in the menu bar. Don't only test a view in a preview.
- Take screenshots (`screencapture`) of every state and actually look at each one.
- Check that the popover sits fully on screen and the menu bar icon is not hidden behind the MacBook notch.
- Verify the content, not just that something rendered: device names instead of UIDs, the right preset name, and the slider matching the system volume HUD after pressing the volume keys.
- Interact while state is changing (engine starting, HDMI cable unplugged, sleep/wake), not only after everything settles.
- Listen: if a change can affect audio, ask the user to confirm what they hear before calling it done.

Full lessons and checklist: [`docs/uat-testing.md`](docs/uat-testing.md). Add new failure modes there as they are found.

## Where UI Components Come From

Knob is **pure SwiftUI**. Never embed React or a `WKWebView` in it: the app runs in the menu bar all day, so it must stay light on memory and battery.

1. **21st.dev is the design source.** For every new piece of UI, first find a matching 21st.dev component (through the `21st` MCP or by browsing 21st.dev), then rebuild its look, spacing and motion in SwiftUI. Its code is React, so use it as a reference only, never as code to paste. `search` and previews are free; the account is on the free tier, so `get_component` (full code) is limited to **2 per day**: choose them deliberately and say which ones you used. Credit the original component in the ported file's doc comment.
2. **SwiftUI built-in controls and SF Symbols handle behaviour** (`Picker`, `Menu`, `Slider`, `Toggle`, `.confirmationDialog`). Style them to match the 21st.dev reference; don't rebuild their behaviour from scratch.
3. **Knob's shared components** (`app/Sources/Knob/Components/`, once it exists) come first: check there before writing any UI pattern inline.
4. **Skills:** `ui-ux-pro-max` (SwiftUI stack) for layout, spacing and accessibility review; `figma:figma-swiftui` if a Figma design exists.

## Knob UI Development Rules (SwiftUI)

### 1. The engine is the source of truth
Never hardcode output devices, preset names, EQ band count or frequencies, or effect ranges. Read them live from the engine (`getDevices`, `getState`). The UI shows what the engine reports, not what it last asked for.

### 2. Pickers, dialogs and time
- Never build a custom dropdown. Use the shared picker component (built on SwiftUI `Picker`/`Menu`).
- Never use `NSAlert` or ad-hoc alerts for confirmations. In the menu bar panel, confirm inside the control itself (like the preset strip's inline "Delete?" row): a dialog can take focus from the panel and close it. Elsewhere (windows), use `.confirmationDialog`.
- **Time is always 12-hour with uppercase AM/PM**, never 24-hour, in every displayed time string.

### 3. Persisted UI state
All persisted UI state (open sections, last preset, and so on) goes through `@AppStorage` with keys defined in one `PersistKey` enum. Never call `UserDefaults` directly in a view.

### 4. Look, colours and motion
- Knob looks like studio hardware: a grained faceplate, recessed pills, realistic knobs, an always-dark analyser screen and one orange accent with glow. Reference: a pro-audio plugin faceplate in charcoal (dark) and speckled white (light).
- Every colour lives in `Theme/Palette.swift`: `Palette.of(colorScheme)` for the faceplate, `Screen` for the dark screen, `Palette.accent`/`accentGlow` for orange. Never hardcode a colour in a view. Every view must look right in both light and dark (check both `--snapshot` PNGs).
- Every animation comes from `Theme/Motion.swift`. Springs use Framer Motion settings through SwiftUI's identical spring model (`interpolatingSpring(mass:stiffness:damping:)`); Framer Motion itself is React-only and is never used. Drags follow the finger with no animation; outside changes (volume keys, engine state) animate.

### 5. File organisation
One SwiftUI file per section (popover shell, volume/output, presets, effects, equalizer), plus `Components/` for shared views, and separate files for app state and the engine client. Views never talk to the socket directly; they go through the state/client layer.

### 6. Skeleton loaders (required)
Every loading state shows the real layout with `.redacted(reason: .placeholder)` (or a shared skeleton view that mirrors it exactly). Never use a spinner or blank space where controls will appear. Vary placeholder widths, for example `let W = [55, 70, 48, 65, 58, 72]` indexed with `W[i % 6]`, so rows look organic.

### 7. Layout
The popover has a fixed width (about 340 pt) and must fit on a 13-inch display, including with larger accessibility text sizes. Long sections (effects, EQ) scroll inside the popover; the popover itself never runs off the screen.

### 8. File size limits
No file over 700 lines. Past 500 lines, plan a split at the next natural boundary.

### 9. Performance and leak prevention
- Meters and any polling run only while the popover is open; stop timers and cancel `Task`s when it closes.
- Socket I/O never runs on the main thread.
- Use `[weak self]` in closures stored by long-lived objects (timers, observers, socket callbacks).
- No per-row animation state in lists of 10+ items; animate the container instead.
- Never define a view type inside another view's `body`.

### 10. Shared components first
If the same UI pattern is needed in 2+ places, extract it into `Components/`; never copy-paste a block of view code. Keep this table current.

| Component | What it is |
|---|---|
| `RealisticKnob` | Hardware rotary knob: well, skirt, lit cap, pointer, glowing arc, MIN/MAX. Turned by circling the pointer around it (`RotaryDrag`), double-click reset, VoiceOver adjustable, trackpad tick at the ends. Proportions tighten for small knobs |
| `RotaryDrag` | Pure maths for turning a knob by angle (no SwiftUI), so it can be tested on its own |
| `NumericValueField`, `NumericEntry` | Inline exact values for volume, effects and EQ; validates finite numbers and ranges, Enter/blur commits, Escape cancels |
| `HardwareFader` | Vertical fader for the dark screen, -1...1 with centre detent |
| `SegmentedTabs` | **21st.dev Segmented Control** (halaska-studio, MIT) port: sliding thumb, arrow keys |
| `PowerSwitch` | **21st.dev Switch** (serafimcloud) port: pill thumb, sliding gradient track, 250/125ms timing |
| `PillMenu` | The only dropdown: native `Menu` styled as a recessed pill. Its label must be a single `Text`: a label made of several views (icon + text) got split into separate menu buttons and clicking the name opened an empty menu. Draw extra decoration (chevron, pill) outside the label with hit testing off |
| `RecessedPill`, `HardwareIconButton` | Pill background and small square icon button |
| `InsetScreen` | Dark recessed screen with the level-driven orange glow |
| `SpectrumView` | Live spectrum bars from the engine's 10 bands |
| `LevelMeter` | L/R meters on a -48...0 dB scale |
| `VUMeter` | Analog VU needle meter beside the level meters, in the knobs' finish (light/dark); needle shape and spring from **Analog UI Needle Gauge** (TechSquidTV, MIT). 0 VU = -6 dBFS peak |
| `Grain` | Deterministic panel speckle |
| `UpdateStatusLabel` | Updater state beside the version in the header: short text ("Downloading…"), full sentence as tooltip |
| `EngravedLabel` | Uppercase control label (in `Views/PanelView.swift`) |

Precision controls and startup recovery: [`docs/precision-and-recovery.md`](docs/precision-and-recovery.md). Knobs and faders support Shift-drag at one-tenth speed. Startup diagnosis must read only the current launch's log bytes, never historical errors. Regression checks: `sh tests/precision-startup-build.sh`.

### 11. UI copy
Never use em dashes (`—`) or double dashes (`--`) in user-facing text: headings, labels, tips, errors, menu items, anything on screen. Rewrite as two sentences, or join with a comma, "and" or "so". This doesn't apply to code, comments or commit messages.

## MCP Tools and Connectors

Project connectors live in `.mcp.json` (gitignored). Secrets are never written into tracked files.

| Connector | Use |
|---|---|
| `code-review-graph` | **Use before Grep/Glob/Read for codebase exploration.** `semantic_search_nodes` / `query_graph` to explore, `get_impact_radius` for blast radius, `detect_changes` + `get_review_context` for review, `get_affected_flows` for impacted paths, `get_architecture_overview` + `list_communities` for architecture. Run `code-review-graph build` after a major refactor. |
| `21st` | 21st.dev component search and inspiration (hosted MCP at `https://21st.dev/api/mcp`). Added with `claude mcp add` at local scope, so the API key lives in `~/.claude.json`, not in the repo. New key: https://21st.dev/mcp. Output is React: reference only. |
| `velocity` (claude.ai) | YouTrack tickets and Slack messages, through the `velocity-ticket-creator` and `velocity-messaging` skills. Ask which YouTrack project Knob tickets belong to before creating any. |

## Skills

- **Project skills** (`.claude/skills/`): `explore-codebase`, `review-changes`, `debug-issue`, `refactor-safely`. All four use code-review-graph.
- **User skills that fit Knob:** `ui-ux-pro-max`, `figma:figma-swiftui`, `code-review`, `simplify`, `run`, `velocity-ticket-creator`, `velocity-messaging`.

## Session Log

Brief, dated record of what was worked on per day, in the `Knob: <summary>` format. Append a new dated entry each session; don't rewrite history.

### 2026-10-18
- Knob: got the macOS audio core running and installed; the Mac volume keys now work on the HDMI monitor
- Knob: chose the name Knob, a menu bar app in pure SwiftUI with 21st.dev as the design source; first version covers volume and output, power and presets, effects, and the 10-band EQ
- Knob: set up project rules, skills and connectors (code-review-graph, 21st.dev)
- Knob: moved into its own repository with fresh history, renamed everything to Knob (license blocks kept as required); all 11 test groups pass and sound output is bit-identical to before the rename

### 2026-10-19
- Knob: added `npm run dev`, which rebuilds and relaunches Knob about 3 seconds after every save
- Knob: first menu bar app, styled as studio hardware in light and dark: realistic volume knob on the real Mac volume (follows the volume keys), five effect knobs, 10-band EQ faders, live spectrum and level meters, preset and output pills
- Knob: ported two 21st.dev components (Segmented Control for the Effects/Equalizer tabs, Switch for power); springs use Framer Motion settings in SwiftUI
- Knob: dev mode now opens the panel by itself after each relaunch
- Knob: OFF now only bypasses the effects, so settings never reset; the sound is saved and restored across restarts
- Knob: the switch makes Knob the Mac's output, follows outputs picked in the Sound menu, and carries the volume over both ways (speakers never left at 100%)
- Knob: installed Knob's own audio device on this Mac, replacing the old one
- Knob: new app icon, redesigned About window with credits to Simran Dhindsa, and a README in Velocity's style with new banner artwork
- Knob: shows in the Dock (optional), clicking the Dock icon opens the panel, quitting stops the engine safely
- Knob: drag-to-Applications installer with a designed window; the app installs its own audio device with one password prompt
- Knob: fixed the Equalizer overflowing with 31 bands; Knob keeps the engine at 10 bands and labels like 1.3K are exact
- Knob: first public release, 0.1.9, on GitHub; every push to main now publishes a release and installed copies update themselves (signed updates, tampered ones refused)
- Knob: the standard installer (Knob-Install.pkg) is the supported install again, since dragging the app in never installed the driver; Homebrew install added; Knob now runs on Intel Macs too
- Knob: README "How it works" redrawn as an illustrated, animated diagram
- Knob: knobs turn by circling the pointer around them, like real knobs; the small effect knobs sit tighter in their ring
- Knob: OFF now fully stops Knob, so the orange microphone dot goes away; settings come back on ON; the permission prompt explains Knob never uses the microphone
- Knob: save your own presets from the preset strip
- Knob: the sound engine writes its errors to a log, so unexpected stops can be explained
- Knob: fixed the preset and output dropdowns opening empty when clicking their name
- Knob: delete your own presets from the preset strip (factory presets can't be deleted)
- Knob: the version shows beside the wordmark, with the updater's status next to it while it checks, downloads or installs
