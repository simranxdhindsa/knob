# Contributing to Knob

Thanks for helping make Knob better. Every kind of help counts, not only code.

## Ways to help

- **Found a bug?** [Open an issue](https://github.com/simranxdhindsa/knob/issues/new/choose) using the bug report form.
- **Have an idea?** Share it in [Discussions → Ideas](https://github.com/simranxdhindsa/knob/discussions/categories/ideas).
- **Stuck or have a question?** Ask in [Discussions → Q&A](https://github.com/simranxdhindsa/knob/discussions/categories/q-a).
- **Made a preset or a setup you love?** Post it in [Show and tell](https://github.com/simranxdhindsa/knob/discussions/categories/show-and-tell).
- **Want to write code?** Read on.

## Before you start coding

For anything bigger than a small fix, open an issue or a discussion first, so we can agree on the approach before you spend time on it.

## Set up

You need macOS 14 or later, the Apple Command Line Tools (`xcode-select --install`) and CMake (`brew install cmake`). Full Xcode is not needed.

```bash
cmake -S . -B build -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release
cmake --build build -j8          # sound engine and tools
bash driver/build.sh "$PWD/build/driver"
app/build-app.sh debug           # build/Knob.app
npm run dev:demo                 # live reload on sample data, for UI work
```

## Checks before a pull request

- Run the tests in [`docs/testing.md`](docs/testing.md).
- **Sound code (`dsp/`)** must pass the bit identical render check in `docs/testing.md`, unless the change is meant to change the sound.
- **Audio thread code** (DSP and the engine's capture and render callbacks) must not allocate, lock, log or do any I/O.
- **Driver changes (`driver/`)** affect sound for every app on the Mac, so they get extra review.
- **UI changes:** check light and dark mode (`build/Knob.app/Contents/MacOS/Knob --snapshot DIR`), and make sure the iOS app still builds.

## House rules

- **UI text uses no dashes** of any kind; write "Double click", not "Double-click".
- **Colours** come from `Theme/Palette.swift` and **animations** from `Theme/Motion.swift`; never hardcode them in a view.
- **Never edit the copyright and license comment blocks** at the top of source files.
- **Commit messages** are one short line with a type prefix: `FEATURE:`, `ENHANCEMENT:`, `BUG:`, `REFACTOR:`, `STYLE:` or `CHORE:`.

## Branches

Open pull requests against **`dev`**. Merging into `main` publishes a release that every installed copy of Knob downloads, so only finished, tested work goes there.

## License

Knob is free software under the [AGPL 3.0](LICENSE). By contributing, you agree that your contribution is shared under the same license.

Please also follow our [Code of Conduct](CODE_OF_CONDUCT.md).
