# Contributing

Issues and pull requests are welcome.

## Getting set up

You need macOS 13 or later and Xcode 15 or later.

```bash
swift build
```

```bash
swift test
```

`Scripts/swiftw` does the same through Xcode's toolchain with its caches redirected. Use it
if a different `swift` comes first on your `PATH` (for example one installed by swiftly),
or if your shell blocks writes to `~/Library/Caches`.

To try a change in the real app, run `Scripts/build-app.sh` and launch `build/Ribbon.app`.

## Where things live

- **`RibbonCore`**: the model and maths (strips, columns, layout, springs, settings). It is
  pure value types and pure functions, covered by unit tests.
- **`RibbonEngine`**: `WindowManager`, the logic that reacts to events and commands. It only
  talks to macOS through the protocols in `RibbonCore/Platform.swift`, so it's tested with fakes.
- **`RibbonAX`, `RibbonInput`, `RibbonUI`**: the macOS-facing parts (Accessibility, keyboard
  and trackpad input, settings window and overlays).

Bug fixes and new behaviour in `RibbonCore` or `RibbonEngine` should come with a test.

The Accessibility write mailbox, shortcut state and overlay drawing decisions also have
regression tests that run without managing real windows.

### Layout benchmark

Run the opt-in benchmark in an optimized build:

```bash
RIBBON_RUN_LAYOUT_BENCHMARK=1 Scripts/swiftw test -c release --filter LayoutBenchmarkTests
```

It reports median relayout times for 20, 100 and 300 tabbed columns (three windows each),
using fake platform services. One warm-up sample is discarded, then five samples of 300
relayouts are measured. There is no machine-dependent timing threshold in CI.
To compare revisions, run the same `LayoutBenchmarkTests.swift` and `Fakes.swift` on both,
on the same machine while other builds are idle. These timings measure the engine's work;
they do not include Accessibility IPC, rendering or real application responsiveness.

## Reporting bugs

Please include:
- your macOS version
- your display setup
- the app that misbehaved
- the output of **menu bar icon → Copy Debug Info**

The debug info lists your open windows' app names and titles. Read it before posting and
remove anything private.

To report a security problem, see [SECURITY.md](SECURITY.md). Please don't open a public
issue for it.
