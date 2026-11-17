<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Kleyn app icon">
</p>

<h1 align="center">Kleyn</h1>

<p align="center">
  A tiny macOS utility for cleaning your Mac: lock the keyboard so you can wipe it<br>
  without typing garbage or triggering shortcuts, or black out the screen to spot smudges.
</p>

<p align="center">
  <img src="docs/images/unlocked.png" width="400" alt="Kleyn with the keyboard unlocked">
  <img src="docs/images/locked.png" width="400" alt="Kleyn with the keyboard locked and the auto-unlock countdown running">
</p>

## Features

- **One-click lock.** Blocks all keyboard input system-wide: regular keys, modifiers, the Globe/fn key, and media, volume, brightness and keyboard-backlight keys.
- **Unlock with the mouse.** Click **Unlock Keyboard** with your mouse or trackpad when you're done.
- **No accidental shortcuts.** While locked, modifier keys you press while wiping are stripped from clicks, so a click never turns into a ⌘-click or a right-click.
- **Safety net.** An optional auto-unlock after 2 minutes, with a visible countdown. On by default, and remembered between launches.
- **Can't lose the button.** The window can't be closed or minimized while the keyboard is locked.
- **Fails safe.** Quitting Kleyn, or Kleyn crashing, always releases the keyboard.
- **Screen cleaning.** Covers every display, including the menu bar and Dock, in black so smudges and streaks stand out. Click or press Space to switch to white, which shows dust better. Press Esc to finish. Nothing is locked, and no permission is needed.
- **Small and dependency-free.** Pure Swift and SwiftUI, no third-party code.

## Requirements

- macOS 27 or later on a Mac with Apple silicon
- The **Accessibility** permission for the keyboard lock (see below). Screen cleaning needs no permission.

## Download

Download the latest **Kleyn-*version*.dmg** from the [Releases page](https://github.com/tyastonotaufiq/kleyn/releases/latest). Open it, drag **Kleyn** onto **Applications**, and open Kleyn from Applications. Kleyn is signed with Developer ID and notarized by Apple, so macOS opens it without a warning.

## Usage

1. Open Kleyn and click **Lock Keyboard**.
2. Clean your keyboard.
3. Click **Unlock Keyboard**, or wait for the auto-unlock.

Kleyn keeps running after you unlock, so you can lock again any time. Quit with ⌘Q or **Quit Kleyn**.

### Cleaning the screen

1. Click **Clean Screen**. Every display turns black.
2. Wipe the screen. Click or press Space to switch between black and white.
3. Press Esc when you're done.

Screen cleaning also ends if you switch to another app. **Clean Screen** isn't available while the keyboard is locked, because the lock would block Esc.

### Granting Accessibility access

macOS only lets apps with Accessibility access block keyboard input. On macOS 27, System Settings lists these apps under **Device Control and Data Access**. Until access is granted, Kleyn shows a banner with instructions:

1. Click **Open System Settings** in Kleyn (or go to **System Settings → Privacy & Security → Device Control and Data Access**).
2. Turn on **Kleyn**. If it isn't listed, add it with **+**.
3. Return to Kleyn. The banner disappears on its own, with no relaunch needed.

> [!TIP]
> If Kleyn is enabled but still can't lock, remove it from the **Device Control and Data Access** list, add it again, and relaunch. This can happen after switching between differently signed builds (for example, a Debug build and a release build), because macOS treats them as different apps.

## Limitations

Some keys are handled below the level any app can intercept:

- **Touch ID / power button:** pressing it can still sleep the display or lock the Mac.
- **Caps Lock:** the light and state may still toggle, even though the key event itself is blocked.
- **Secure Keyboard Entry:** when another app has it turned on (some terminals and password managers), macOS hides keystrokes from Kleyn. Kleyn shows a warning while locked if it detects this.

## How it works

Kleyn installs an active [`CGEventTap`](https://developer.apple.com/documentation/coregraphics/cgevent) at the HID level, before the system handles shortcuts like ⌘Tab or Force Quit. While locked, it drops key-down, key-up and modifier events, plus the system-defined events behind the media and hardware keys. Mouse and trackpad events pass through, with modifier flags removed.

The tap belongs to Kleyn's process, so the system removes it as soon as Kleyn exits. Taking exclusive control of the keyboard device through IOKit was ruled out: on current macOS that needs root, which would mean shipping a privileged helper.

All the locking logic is in [`KeyboardLocker.swift`](Kleyn/KeyboardLocker.swift).

Screen cleaning uses one borderless window per display, above the menu bar and Dock, and doesn't touch the keyboard lock. Those windows handle Esc, Space and clicks themselves; other keys are ignored, and ⌘ shortcuts like ⌘Q still work. The code is in [`ScreenCleaner.swift`](Kleyn/ScreenCleaner.swift).

## Building

Open `Kleyn.xcodeproj` in Xcode 27 or later and run the **Kleyn** scheme, or build from the command line:

```sh
xcodebuild -project Kleyn.xcodeproj -scheme Kleyn -configuration Release build
```

To build with your own Apple developer account, change the team under **Signing & Capabilities**.

### Distribution

The project is set up for direct distribution as a notarized Developer ID app:

- **App Sandbox is off.** The keyboard lock does work in the sandbox, but macOS never shows the Accessibility prompt to sandboxed apps, so users would have to find Kleyn and add it to the list by hand. With the sandbox off, clicking **Lock Keyboard** the first time brings up the system prompt instead.
- **Hardened Runtime is on**, with no exceptions.
- **Release builds don't add the `get-task-allow` entitlement**, which notarization rejects.

To ship a build, choose **Product → Archive**, then **Distribute App → Direct Distribution**. Xcode signs with your Developer ID, notarizes the app and staples the ticket.

To package the exported app as a DMG with the drag-to-Applications window, set up [dmgbuild](https://github.com/dmgbuild/dmgbuild) once, then run the script:

```sh
python3 -m venv .venv && .venv/bin/pip install dmgbuild
scripts/make-dmg.sh path/to/Kleyn.app    # writes Kleyn-<version>.dmg next to the app
```

The DMG isn't signed by the script. Sign and notarize it before shipping.

## Project layout

| Path | Contents |
|---|---|
| `Kleyn/KeyboardLocker.swift` | Event tap, auto-unlock countdown, permission checks |
| `Kleyn/ScreenCleaner.swift` | Full-screen black/white windows for screen cleaning |
| `Kleyn/ContentView.swift` | The window's interface |
| `Kleyn/KleynApp.swift` | App entry point |
| `Kleyn/AppIcon.icon` | Icon Composer app icon |
| `Design/Icon/` | Source SVG layers for the icon |
| `Design/DMG/` | DMG window background and the Swift script that renders it |
| `scripts/` | DMG build script and its dmgbuild settings |

## License

Kleyn is available under the [MIT License](LICENSE).
