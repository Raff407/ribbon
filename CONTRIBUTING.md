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
