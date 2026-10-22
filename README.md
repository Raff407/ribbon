# Ribbon

**A free, open-source scrolling window manager for macOS**, in the spirit of
[PaperWM](https://github.com/paperwm/PaperWM) and [niri](https://github.com/YaLTeR/niri).

Every window is a column on one endless horizontal strip. Opening a window adds a column
next to the one you're using, and nothing else shrinks. You move along the strip with the
keyboard or the trackpad, and it scrolls with a spring animation.

Ribbon is a native Swift app (AppKit + SwiftUI) with no Electron and no config files to
learn. It only needs the Accessibility permission, and you never have to disable SIP.

## Features

- **The strip:** one per display and per Space, each with its own focus and scroll position.
- **Columns:** preset widths, full width (while the column has focus), centre, wider/narrower.
- **Stacks and tabs:** stack several windows in one column, or turn a column into tabs with
  a clickable tab bar.
- **Pinning:** pin a column to the left or right edge while the rest of the strip scrolls.
- **Trackpad:** hold a modifier and swipe sideways, or optionally use a bare 3/4-finger swipe.
- **Mouse:** drag a window onto another column to reorder, or resize it to set the column's
  width.
- **Strip indicator:** a frosted bar showing each column's app icon and where you are. While
  you hold the shortcut key you can click or drag its tiles.
- **Focus border and dimming:** optional, off by default.
- **Floating windows:** dialogs, Quick Look and fixed-size windows float automatically.
- **Per-app rules:** float an app, always tile it, or leave it alone.
- **Native tabs:** Finder and Terminal windows with macOS tabs take a single column.
- **Multi-monitor:** windows snap flush to the edge instead of spilling onto the next
  screen, you can send a window to the next display, and you can switch Ribbon off for any
  display.
- **Session restore and launch at login.**
- **Optional** focus-follows-mouse and mouse-follows-focus.
- **Rebindable shortcuts,** with presets.
- **Automation:** a `ribbon://` URL scheme and a `ribbon` command-line tool.
- **Safe exit:** quit, pause or kill Ribbon and every hidden window goes back on screen.

## Install

### Download

1. Get `Ribbon-<version>.zip` from the
   [latest release](https://github.com/Raff407/ribbon/releases/latest).
2. Unzip it and move **Ribbon.app** to **Applications**.
3. Open it. Ribbon isn't notarised by Apple, so the first launch is blocked. Go to
   **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
   Alternatively, run this once:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Ribbon.app
   ```

4. Allow Ribbon under **System Settings → Privacy & Security → Accessibility**. The welcome
   window closes and tiling starts.

The release is a universal app, so it runs on both Apple silicon and Intel Macs with
macOS 13 Ventura or later.

### Build from source

You need macOS 13+ and Xcode 15+.

```bash
git clone https://github.com/Raff407/ribbon.git
```

```bash
cd ribbon && Scripts/build-app.sh
```

```bash
cp -R build/Ribbon.app /Applications/
```

> **Tip:** if macOS keeps asking for Accessibility after you install a new build, remove
> Ribbon from the Accessibility list with **−** and add it back with **+**.

## Shortcuts

Every shortcut is **⌥ (Option) + a letter**. Add **⇧** to move a window instead of moving focus.
Arrow keys and number keys are never used, so ⌥-arrow word jumps and ⌥-number characters
(such as # and € on UK keyboards) keep working.

| Action | Keys |
|---|---|
| Focus left / down / up / right | ⌥ H J K L |
| Move window left / down / up / right | ⌥⇧ H J K L |
| Cycle width / backwards | ⌥ R / ⌥⇧ R |
| Full width (until focus moves on) | ⌥ F |
| Centre the column | ⌥ C |
| Wider / narrower | ⌥ = / ⌥ - |
| Stack into left / right column | ⌥ [ / ⌥ ] |
| Pop out to the left / right | ⌥⇧ [ / ⌥⇧ ] |
| Float / unfloat | ⌥ T |
| Tabbed column | ⌥⇧ T |
| Pin to left / right edge | ⌥ P / ⌥⇧ P |
| Send to next display (monitor) | ⌥ M |
| Pause / resume Ribbon | ⌥ Q |
| Gather all windows | ⌥⇧ G |
| Settings | ⌥ , |

Focus, move and resize repeat while you hold the keys. In **Settings → Shortcuts** you can:
- rebind anything
- bind commands that have no default (first/last window, window 1–9, taller/shorter, …)
- switch to the **Control-Option (⌃⌥)** preset, which also uses arrow and number keys

**Scrolling:** hold ⌃⌥ and swipe sideways with two fingers (or use the mouse wheel). The
modifier is configurable in Settings → Trackpad & Mouse.

## Recommended macOS settings

**Settings → Mac Setup** checks these for you:

- **Displays have separate Spaces**: on (System Settings → Desktop & Dock)
- **Automatically rearrange Spaces based on most recent use**: off
- **Stage Manager**: off
- Quit other window managers and snapping apps, such as Rectangle, Magnet, yabai or AeroSpace.
- For bare-swipe scrolling, change the macOS three/four-finger swipe between Spaces
  (Trackpad → More Gestures) so it uses a different number of fingers.

## Automation

```bash
ribbon focus-right
```

```bash
ribbon list
```

The `ribbon` tool is in `Scripts/`; copy it somewhere on your `PATH`. Each command id also
works as a URL, for example `ribbon://cycle-width` or `ribbon://command/pin-left`. There are
also `ribbon://enable`, `ribbon://disable`, `ribbon://relayout`, `ribbon://gather` and
`ribbon://settings`, which makes it easy to drive from Raycast, Alfred or Shortcuts.

## How it works

macOS won't put a window completely off-screen. So when a window scrolls out of view,
Ribbon *parks* it in a bottom corner of its display with a 1-point sliver still showing,
choosing a corner that doesn't touch a neighbouring display. When the window scrolls back,
it slides in from the edge of the screen.

Moving a window means sending a message to the app that owns it. Ribbon does that on a
background queue for each app, and only the latest position is kept, so a slow app drops
frames instead of stalling everything else.

| Module | Responsibility |
|---|---|
| `RibbonCore` | Pure model and maths: strips, columns, layout and scrolling, parking, springs, settings, window classification, session restore, platform protocols |
| `RibbonEngine` | `WindowManager`: turns events, commands, gestures and drags into new layouts. It talks to the OS only through protocols, so it's unit-tested with fakes |
| `RibbonAX` | Accessibility: per-app observers, window registry, animated frame applier, displays, Spaces |
| `RibbonInput` | Keyboard shortcuts (event tap), key names, scroll tap, multi-touch swipes |
| `RibbonUI` | Settings window, menu bar, overlays (indicator, focus border, dimming, tab bars), onboarding |
| `Ribbon` | App wiring, URL scheme, signal handling |

Settings are stored in `UserDefaults` (`com.raff.ribbon`) and the session in
`~/Library/Application Support/Ribbon/session.json`.

## Privacy and security

- **No network access.** Ribbon makes no network requests, has no telemetry and no account.
- **Keystrokes stay local.** The shortcut listener sees key presses to spot Ribbon's own
  shortcuts. It acts on those and passes everything else straight through; nothing is
  logged, stored or sent anywhere.
- **What it stores, locally:** settings in `UserDefaults` and the window layout (app ids and
  window titles, used to restore your session) in
  `~/Library/Application Support/Ribbon/session.json`. Delete that file to clear it.
- **Permissions:** Accessibility only. Screen recording, files, contacts and the like are
  never requested.
- **Copy Debug Info** puts your window titles on the clipboard, and only when you click it.
- **`ribbon://` links** can only arrange windows. Browsers ask before opening them.

Found a vulnerability? See [SECURITY.md](SECURITY.md).

## Development

```bash
swift build
```

```bash
swift test
```

See [CONTRIBUTING.md](CONTRIBUTING.md). `RibbonCore` and `RibbonEngine` have unit tests
(about 130 of them). The macOS-facing layers need a real session with the Accessibility
permission.

## Known limitations

- Spaces support uses private CoreGraphics functions. Without them, every display has a
  single strip.
- Bare multi-finger swipes use the private MultitouchSupport framework. A trackpad you
  connect while swipes are running is only picked up after the Mac wakes from sleep, or
  after you switch swipes off and on.
- Native-tab detection is a heuristic: same app, same frame, and exactly one of the two
  windows on screen.
- Keyboard shortcuts don't fire while macOS secure input is on (for example while a
  password field is focused).
- The app isn't notarised (that needs a paid Apple developer account), hence the **Open
  Anyway** step.

## License

[MIT](LICENSE)
