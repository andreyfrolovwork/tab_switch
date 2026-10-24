# Tab Switch

A small macOS app that fixes window switching: press **⌘Tab** and you get every window on the current screen with a live preview, not just a row of app icons.

The built-in macOS switcher works per app. If you have three Safari windows and two terminals, ⌘Tab won't tell you which one is which. Tab Switch shows each window on its own, with a thumbnail, the app icon and the window title, so you can see where you're going before you get there.

It's deliberately simple: one menu bar icon, one panel, no settings screen.

## Features

- **⌘Tab** (or **⌥Tab**) opens a grid of the windows on the current Space, each with a live thumbnail.
- Keep holding the modifier and press **Tab** / **⇧Tab** or the arrow keys to move. Release it to switch to that window.
- **Return** or a click also switches. **Esc** closes the panel and leaves focus where it was.
- While the app is running, the system ⌘Tab switcher is turned off so the two don't fight. It comes back when you quit.
- Frosted "liquid glass" panel on macOS 26, regular blur on older versions.
- Lives in the menu bar with no Dock icon.

## Requirements

- macOS 14 or later (Liquid Glass background needs macOS 26)
- Apple Silicon (`build.sh` targets `arm64`)
- Xcode Command Line Tools (`xcode-select --install`)

## Build and run

```bash
./build.sh
open dist/WindowSwitcher.app
```

The app is built with `swiftc` directly. There is no Xcode project.

## Permissions

The app needs two permissions in **System Settings → Privacy & Security**:

| Permission | Why |
| --- | --- |
| **Accessibility** | To catch ⌘Tab globally and to raise the window you picked |
| **Screen & System Audio Recording** | To capture window thumbnails |

Each time the app starts, it checks both. If one is missing, it explains what's missing and opens the right settings page. If WindowSwitcher doesn't show up in the Screen Recording list, add it by hand with the **+** button and pick `dist/WindowSwitcher.app`. Changes to Screen Recording can need a restart of the app.

Without Accessibility the system ⌘Tab keeps working as usual. Without Screen Recording the switcher still works, just without previews.

### Keep permissions across rebuilds

macOS ties these permissions to the app's code signature. With an ad-hoc signature every build looks like a new app, and you'd have to grant the permissions again after each build.

To avoid that, create a self-signed code signing certificate once:

1. Open **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name: `WindowSwitcher Local`, Identity Type: **Self Signed Root**, Certificate Type: **Code Signing**.

`build.sh` uses that certificate automatically when it finds it, and falls back to ad-hoc signing otherwise.

## How it works

- `KeyMonitor.swift`: a `CGEventTap` that intercepts ⌘Tab / ⌥Tab and the navigation keys while the panel is open.
- `SystemHotkeys.swift`: turns off the system ⌘Tab and ⇧⌘Tab hotkeys while the tap is active and turns them back on at exit, including on `SIGTERM`.
- `Windows.swift`: lists on-screen windows via `CGWindowList` and activates the chosen one via the Accessibility API.
- `Thumbnails.swift`: captures previews with ScreenCaptureKit. They are kept in memory only and never written to disk.
- `Switcher.swift`, `SwitcherView.swift`: the panel and its layout.
- `main.swift`: menu bar item, permission checks, startup.

> **Note:** quit the app from its menu or with `kill -TERM`. A hard kill (`kill -9`) can't run the cleanup, so the system ⌘Tab stays off until you start and quit the app again.

## Debugging

```bash
dist/WindowSwitcher.app/Contents/MacOS/WindowSwitcher --dump     # list detected windows
dist/WindowSwitcher.app/Contents/MacOS/WindowSwitcher --thumbs   # capture thumbnails, print their sizes
```

Run them via `open -n -W --stdout /dev/stdout dist/WindowSwitcher.app --args --thumbs` if you want the app's own Screen Recording permission instead of your terminal's.

The running app logs its state (`hotkey on`, `capture on`, `needs access`, …) to `/tmp/windowswitcher.log`.

## Limitations

- Only windows on the current Space are shown.
- The UI text is in Russian for now.
