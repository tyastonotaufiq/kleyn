# Porting claude-mods to Kleyn

This doc tracks bringing four mods from [`claude-mods`](https://github.com/tyastonotaufiq/claude-mods) into Kleyn as native features: Mac Caffeinater, Mac Cleaner, Mac Uninstaller and ADB Explorer. We port one mod at a time. Update the status table when a step moves.

The mods stay as they are in `claude-mods`. Nothing there changes.

## Status

| Step | Feature | Source mod | Status |
|---|---|---|---|
| 1 | Sidebar + Keep Awake | `mac-caffeinater` (0.1.0) | Done (`a990049`) |
| 2 | Cleaner | `mac-cleaner` (0.4.0) | Done (`1f7f422`) |
| 3 | Uninstaller | `mac-uninstaller` (0.6.0) | Testing |
| 4 | ADB Explorer | `adb-explorer` (0.3.0) | Not started |

Status values: Not started → Planning → Building → Testing → Done (commit) → Released (version).

## How we work

For each step:

1. **Read the mod.** Read its `hooks/register.tsx`, the logic file (`awake.ts`, `cleaner.ts`, `uninstaller.ts`, `adb.ts`) and its `tests/`. The logic file and tests are the spec: the same rules, limits and safety checks carry over.
2. **Plan.** Write a short plan for the step and agree on it before writing code.
3. **Build.** Write the step in Swift and SwiftUI with no third-party code, as Kleyn is now. Keep the I/O-free rules in their own file, like the mods do, so they can be tested.
4. **Test.** You run it from Xcode (⌘R) and try it. Claude only builds to check that it compiles.
5. **Commit and push** once you're happy.
   Add the feature to the README tagline ("A small Mac app of everyday utilities: …") and to the GitHub **About** description, so both name only what's built.
6. **Release** if you want to (see [Open decisions](#open-decisions)).

Don't start a step until the previous one is Done.

## App structure

Kleyn is one fixed 380-point window today. With four more features, it becomes a resizable window with a sidebar:

| Sidebar | What it is |
|---|---|
| Keep Awake | Step 1 |
| Keyboard Cleaning | Today's keyboard lock, unchanged |
| Screen Cleaning | Today's Clean Screen, unchanged |
| Cleaner | Step 2 |
| Uninstaller | Step 3 |
| ADB Explorer | Step 4 |

Pages that aren't built yet are already in the sidebar with a **Soon** badge and a placeholder page (`Kleyn/PlaceholderView.swift`) that says what they'll do. Each step replaces its placeholder with the real page and removes the page's `comingSoon` text in `ContentView.swift`.

Rules that carry over from today:

- **The Unlock button must stay reachable while the keyboard is locked.** You can't close or minimize the window then. Decided: while locked, the sidebar is disabled and Kleyn stays on the Keyboard Cleaning page.
- **Clean Screen stays unavailable while the keyboard is locked.** The lock would block Esc.
- **The Accessibility permission stays tied to the keyboard lock only.** None of the new features need it.

## Step 1: Sidebar and Keep Awake

**Source:** `claude-mods/mac-caffeinater`, with `hooks/awake.ts` (caffeinate arguments, running apps, typed times) and `hooks/register.tsx`.

**What ports:**

- Keep awake until stopped, or for 15 min, 30 min, 1 hour, 2 hours or 4 hours.
- Keep awake until a time you type (`18:30`, `6:30 pm`, `6pm`). A time already past today means tomorrow.
- Keep awake while a chosen open app runs (apps with a Dock icon). It stops when that app quits.
- An option to let the display sleep while the Mac stays awake, remembered across launches.
- Starting a new session replaces the one running.

**What changes in an app:**

- **Power assertions instead of `caffeinate`.** Use IOKit power assertions (`IOPMAssertionCreateWithName`) instead of running `caffeinate`: one that keeps the system awake, plus one that keeps the display on unless "let the display sleep" is on. No helper process and no permission.
- **Watching the app.** "While an app runs" watches that app's process with `NSWorkspace` notifications. Quitting and reopening the app ends the session, as in the mod.
- **It has to outlive the window.** The mod's status line ("Awake until 18:30") becomes a menu bar icon (`MenuBarExtra`) that shows what's on and has a Stop item. Closing the window must not quit Kleyn while Keep Awake is on.
- **The keyboard shortcuts in the mod's table don't carry over.** The app uses buttons. Shortcuts can come later.

**Known limits that carry over:** it only works while Kleyn is running, and closing a MacBook's lid still sleeps it unless closed-display mode applies.

**Also in this step:** the sidebar restructure above, plus a test target for the I/O-free rules (time parsing, durations). Kleyn has no tests yet.

**Done when:**

- [x] The sidebar shows Keyboard Cleaning and Screen Cleaning, which work exactly as before, including Unlock while locked
- [x] Every Keep Awake mode works and stops: until stopped, timed, until a time, while an app runs
- [x] Display sleep on/off works and is remembered
- [x] The menu bar icon shows the session, and Stop works from it
- [x] Closing the window keeps the session; quitting Kleyn ends it
- [x] Time parsing tests pass
- [x] README updated

### Plan

**Decided:**

- **Menu bar:** a cup icon appears only while Keep Awake is on. Its menu shows the status ("Awake until 18:30"), **Stop** and **Open Kleyn**.
- **While the keyboard is locked:** the sidebar is disabled and Kleyn stays on Keyboard Cleaning.
- **Test target:** you add it in Xcode as **KleynTests** (Unit Testing Bundle, Swift Testing), and Claude writes the tests.

**New files:**

| File | Contents |
|---|---|
| `Kleyn/KeepAwakeRules.swift` | The I/O-free part, ported from `awake.ts`: the session type, presets, `parseClockTime`, `clockLabel`, `describe`, and choosing the apps to list (Dock apps only, no Finder, named after the `.app`, the oldest process per name, sorted by name) |
| `Kleyn/KeepAwake.swift` | An `@Observable` class like `KeyboardLocker`. Start (until stopped, for a preset, until a typed time, while an app runs), Stop, and display sleep (saved in `UserDefaults`). It holds IOKit power assertions: prevent idle system sleep, plus prevent idle display sleep unless the display may sleep. A task ends timed sessions. An `NSWorkspace` termination observer ends app sessions. Messages match the mod: "Time's up: your Mac can sleep again.", "<App> quit: …", "Stopped: …" |
| `Kleyn/KeepAwakeView.swift` | The page: the status and Stop at the top, then **For a while** (Until I stop it, plus the 5 presets), **Until a time** (a text field and Start), **While an app is open** (a menu of running apps, read when it opens), and **Let the display sleep**. The running choice is highlighted, as in the mod |
| `Kleyn/KeyboardView.swift` | Today's keyboard part of `ContentView`, unchanged except that Clean Screen moves out |
| `Kleyn/ScreenView.swift` | The Clean Screen button with a short description, disabled while the keyboard is locked |
| `KleynTests/KeepAwakeRulesTests.swift` | Ports `tests/awake.test.ts`: typed times (later today, past means tomorrow, not-a-time cases), labels, `describe`, and the app list. The caffeinate argument tests become tests of which assertions are taken |

**Changed files:**

- **`Kleyn/ContentView.swift`:** becomes the sidebar (`NavigationSplitView`) with Keep Awake (at the top), Keyboard Cleaning and Screen Cleaning. **Quit Kleyn** moves to the bottom of the sidebar. The window is resizable, with a minimum size.
- **`Kleyn/KleynApp.swift`:** creates `KeepAwake` and adds a `MenuBarExtra` that's shown only while a session runs. **Open Kleyn** reopens the window if it was closed.
- **`README.md`:** Keep Awake in Features and Usage, and the new files in the project layout. Screenshots after you test.

**Not ported:** restoring a session after relaunch. In the mod, a session survives Claude Code reloading. In Kleyn, quitting ends it, and macOS drops the power assertions when Kleyn exits.

## Step 2: Cleaner (Mac Cleaner)

**Source:** `claude-mods/mac-cleaner`, with `hooks/cleaner.ts` (scan targets, parsing, trash rules) and `hooks/register.tsx`.

**What ports:**

- Scan the usual space users: app caches, logs, Xcode, Gradle, Android emulators and system images, npm, CocoaPods, and Java heap dumps (`*.hprof`) in the home folder.
- Rows appear as each folder is measured, with progress and the folder still being measured.
- Two groups: **Safe to remove** (rebuilt automatically) and **Review first** (archives, emulators).
- Items under 10 MB are added up per category into one row, which appears once the total reaches 10 MB. Trashing that row trashes each item, never the folder that holds them.
- Mark or unmark rows, mark all Safe to remove, unmark all, show in Finder, rescan.
- Move marked items to the Trash after a confirmation that names the count and total size.
- A log of moves (last 200).

**Safety rules (keep them exactly):**

- Nothing is deleted. Items go to the Trash with `FileManager.trashItem`, where Put Back works.
- Every move asks first.
- Only paths inside the home folder can be trashed, and never a folder directly in it (like `~/Downloads`) or a hidden file there (like `~/.zshrc`).
- These are always refused: iCloud Drive, Mail, Messages, the Photos library, Keychains, `~/Library/Containers`, `~/.ssh`.

**Left out:** the `mac-storage` skill and Claude's findings (`(Claude)` rows). There's no Claude in the app.

**Things to watch:**

- Some folders need Full Disk Access for an accurate size. macOS asks for Kleyn itself now, not the terminal. Decide whether to show a banner for it, like the Accessibility one.
- Scanning `~` for `.hprof` files must not walk into Desktop, Documents or Downloads, which would trigger macOS's "access files in…" prompts.
- Scanning has to happen off the main thread, and the scan must stop when you leave the page.

**Done when:**

- [ ] The scan matches the mod's targets and grouping on the same Mac. Same targets and grouping in code, except the Music app's caches; not compared side by side yet
- [x] The trash rules are unit-tested with the mod's test cases
- [ ] Trashed items show up in the Trash, and Put Back works. They do, but Put Back is missing sometimes (see Known issue)
- [x] Refused paths can't be trashed (unit tests)
- [x] A scan shows no permission prompts (checked 2026-11-18 after leaving out the Music app's caches; Full Disk Access only shows the note)
- [x] README updated, including a Safety note

**Known issue: Put Back.** On 2026-11-18, `~/java_error_in_studio.hprof` was moved to the Trash, put back, then moved again. Put Back worked the first time, but Finder didn't offer it the second time. The cause isn't known yet. One guess to check: the Trash window was open during the second move, and Finder may have overwritten the Put Back record. Try again with the Trash window closed; if it still happens, try `NSWorkspace.recycle`, then Finder through AppleScript (which needs the Automation permission).

### Plan

**Decided:**

- **Measuring sizes without `du`.** Kleyn adds up each folder itself (`FileManager` enumerator, allocated size per file, as `du` counts blocks). There's no helper process, and a scan stops at once when it's cancelled. It measures 4 folders at a time, as the mod does, off the main thread. The biggest folders (Gradle, DerivedData…) start first.
- **Free space without `df`.** Read from the home volume's resource values (total capacity, and available capacity for important usage, which is what Finder and System Settings show).
- **Moving to the Trash:** `FileManager.trashItem`, one item at a time. Each path is checked with `isTrashable` right before it moves. No `osascript` or `/usr/bin/trash`. Put Back is checked by hand during testing (see Things to watch).
- **When it scans:** the first time you open the page. The results stay while Kleyn runs, with **Rescan** to refresh them. Leaving the page cancels a scan that's still running, and coming back starts it again.
- **Marking during a scan** works. **Move to Trash** waits until the scan is done, as in the mod.
- **Show in Finder** selects every marked item (`NSWorkspace.activateFileViewerSelecting`). Each row also has **Show in Finder** in its context menu.
- **Log of moves:** the last 200 moves (date, paths, bytes) go to `~/Library/Application Support/Kleyn/cleaner-log.json`. The page doesn't show it, as in the mod. The README says where it is.
- **Full Disk Access:** no banner. If a scan couldn't read some folders, the page shows "Some folders couldn't be measured" with an **Open System Settings** button that goes to Full Disk Access. Nothing is shown otherwise.
- **Sizes like Finder:** 1 GB is 1,000,000,000 bytes (`ByteCountFormatter`, file style), so sizes and free space match Finder and System Settings. `minSize` becomes 10,000,000 bytes, and the ported size tests use those numbers.
- **Shortcuts:** ⌘R rescans, and ⌘⌫ moves marked items to the Trash (still asking first).
- **The Music app's caches are left out** (`com.apple.Music`, `com.apple.AMPLibraryAgent`, `com.apple.iTunes*` in `~/Library/Caches`). Measuring them made macOS ask Kleyn for **Media & Apple Music** access, as it asked the terminal for the mod. They're about 20 MB.

**New files:**

| File | Contents |
|---|---|
| `Kleyn/CleanerRules.swift` | The I/O-free part, ported from `cleaner.ts`: the targets, `minSize`, the item and row types, `cleanPath`, `isTrashable` (with the same protected lists), building rows (nested rows dropped, small items summed per category, safe first, biggest first), `rowPaths`, `commonFolder`, `rowLabel`, `tildify` and size labels |
| `Kleyn/Cleaner.swift` | An `@Observable` class like `KeepAwake`. It owns the rows, the marks, the progress ("Scanning 37 of 152 · found 61.2 GB so far · ~/.gradle/caches…"), the message line and the free space. Scan, cancel, mark and unmark, mark all safe, unmark all, show in Finder, move to Trash, and the log |
| `Kleyn/CleanerView.swift` | The page. At the top: free space, **Rescan**, and the progress or message line. Then **Safe to remove · 12.3 GB** (with **Mark All**) and **Review first · 4.5 GB**. Each row has a checkbox, the path or summary label, the size (bold from 1 GB) and a second line with the category and reason. At the bottom: "3 items marked, 1.2 GB" with **Unmark All**, then **Show in Finder** and **Move to Trash**. Moving asks first: "Move 12 items, 3.4 GB, to the Trash?" |
| `KleynTests/CleanerRulesTests.swift` | Ports `tests/cleaner.test.ts`: what may be trashed (all of its cases), building rows and summary rows, `commonFolder`, `rowLabel`, sizes and `~` paths |

**Changed files:**

- **`Kleyn/ContentView.swift`:** Cleaner loses its `comingSoon` text and Soon badge, and shows `CleanerView`.
- **`Kleyn/KleynApp.swift`:** creates the `Cleaner`, like the locker, so results stay when you switch pages.
- **`README.md`:** the tagline, Features, a "Freeing up space" usage section, Safety, Full Disk Access, and the new files in the project layout. Screenshots after you test.

**Not ported:**

- `parseDu`, `parseDf`, `finderTrashScript` and their tests. Kleyn doesn't run `du`, `df` or AppleScript.
- `parseFindings`, refreshing after Claude's turn, the `mac_cleaner_state` tool and `(Claude)` rows. There's no Claude in the app.

**Things to watch while testing:**

- **Put Back.** Check that Finder's **Put Back** works on an item Kleyn trashed. If it doesn't, switch to `NSWorkspace.recycle`.
- **Sizes against the mod.** Run `/mac-cleaner` on the same Mac. The rows and groups should match. Sizes may differ slightly from `du`.
- **Permission prompts.** A scan shouldn't trigger any "access files in…" or "access data from other apps" prompt.

## Step 3: Uninstaller (Mac Uninstaller)

**Source:** `claude-mods/mac-uninstaller`, with `hooks/uninstaller.ts` (where apps leave files, matching, what may be shown) and `hooks/register.tsx`.

**What ports:**

- **All apps:** a list of apps you can filter by name or bundle ID. macOS's own apps (`/System/Applications`, Safari) are left out. Apple apps in `/Applications`, like Xcode, are listed.
- **One app:** the app, then each file it left, with its location, size and the reason it's listed:
  - Marked: the app and everything named after its bundle ID.
  - Unmarked, in yellow: folders matched by the app's name, and shared group containers.
  - Unmark the app itself to keep it and remove only its leftovers.
- **Leftovers of removed apps:** files in `~/Library` named after a bundle ID no installed app has, grouped per app. Leave out Apple's own files, IDs from developers with an app still installed, and apps Spotlight finds elsewhere.
- **System extensions** whose app is gone: listed with their state, not removed.
- **Show in Finder:** everything marked is shown selected, with one window per folder. You move it to the Trash there.

**Safety rules (keep them exactly):**

- Kleyn never moves or deletes anything here. Finder does, with `NSWorkspace.activateFileViewerSelecting`.
- Each path is checked again before it's shown:
  - An app must be a `.app` in `/Applications` or `~/Applications`, or one folder down.
  - A leftover must sit directly inside one of the `~/Library` places apps write to, never be the place itself.
- These are never listed: another app's container, Keychains, Mail, iCloud Drive, `~/.ssh`, `~/.aws`, shell startup files, `~/.claude`.
- Nothing under `/Library` is ever listed.

**Left out:** the `mac-uninstall` skill (dotfolders, CLI config, login items, `/Library` files) and Claude's findings.

**Things to watch:**

- Measuring another app's container can trigger macOS's "access data from other apps" prompt for Kleyn. If it's denied, show the size as —.
- Some sizes need Full Disk Access, the same as Step 2.
- Reuse Step 2's folder-size code.

**Done when:**

- [ ] The app list and leftovers match the mod's results for the same app
- [ ] The matching and "may be shown" rules are unit-tested with the mod's test cases
- [ ] Show in Finder selects the right files, and nothing is moved by Kleyn
- [ ] Leftovers of removed apps and system extensions are listed
- [ ] README updated, including a Safety note

### Plan

**Decided:**

- **Reading apps natively.** Kleyn reads each app's `Info.plist` itself instead of running `plutil`, including an iPhone or iPad app's `WrappedBundle/Info.plist`. It lists apps the way the mod does: `.app` bundles in `/Applications` and `~/Applications`, and one folder down (not `Utilities`). Each row shows the app's icon, name and version.
- **Finding removed apps with Launch Services instead of `mdfind`.** `NSWorkspace.urlsForApplications(withBundleIdentifier:)` answers "is this app installed anywhere else?" with no helper process. An app in the Trash doesn't count as installed, so its leftovers are listed, as in the mod.
- **System extensions** still come from `/usr/bin/systemextensionsctl list`. macOS has no API that lists other apps' extensions. It's the only helper process in this step, run with an argument list.
- **Sizes** use Step 2's folder-size code, moved into its own file so the Cleaner and the Uninstaller share it. Measured 4 at a time, off the main thread.
- **Showing in Finder:** `NSWorkspace.activateFileViewerSelecting`, called directly. As in the mod, the leftovers are shown first and the app a moment later, so the app's window ends up in front.
- **After Finder moves things:** when you switch back to Kleyn, rows whose files are gone disappear by themselves. **Rescan** (⌘R) still looks again from scratch.
- **Search** matches the app's name, its file name and its bundle ID. VS Code's name is "Code", but Finder shows "Visual Studio Code", so typing either finds it.
- **An app that's open:** the app page says "Slack is open. Quit it before moving it to the Trash." Kleyn doesn't quit it for you.
- **Containers are measured on click.** Measuring `~/Library/Containers/<app>` or a group container makes macOS ask "Kleyn would like to access data from other apps". So these rows show a **Measure** button instead of a size, and macOS asks only when you click it. If access is denied, the size shows as —. Show in Finder works either way, because Finder moves the container, not Kleyn. Everything else is measured right away. In **Removed apps**, a row with containers shows the size without them, plus a **Measure** button that adds them.
- **Leftovers are only ever children of the `~/Library` places.** The mod's rule also allowed dotfolders like `~/.vscode`, but only for Claude's findings. With no Claude, the rule is narrower: `~/.anything` is never listed.

**New files:**

| File | Contents |
|---|---|
| `Kleyn/UninstallerRules.swift` | The I/O-free part, ported from `uninstaller.ts`: the places, which apps are macOS's own, `isRemovableApp`, `isRemovableLeftover`, bundle IDs in file names (`group.`, team-ID prefixes), the owner of a file by ID, matching by ID or name, the reason line, which rows are marked at first, leftovers of removed apps grouped per ID (helpers in their app's row), parsing `systemextensionsctl list`, extensions of removed apps, a running extension holding containers, reading an `Info.plist`, and the search filter |
| `Kleyn/Uninstaller.swift` | An `@Observable` class like `Cleaner`: the app list, one app's rows, the removed apps' rows and extensions, marks, measuring, Show in Finder, and dropping rows whose files are gone |
| `Kleyn/UninstallerView.swift` | The page, with three views in a navigation stack. **All apps:** a search field (name or bundle ID, Return opens the first match), the list, and **Leftovers of Removed Apps**. **One app:** the app and its leftovers, each with a checkbox, `~` path, size, and a line with where it is and why it's listed. Name matches and shared containers are orange and unmarked. **Removed apps:** one row per bundle ID with its places and item count, then **System Extensions of Removed Apps** with their state. Both have **Mark All**, **Unmark All**, **Show in Finder** and **Rescan** |
| `Kleyn/DiskUsage.swift` | The folder-size code, moved out of `Cleaner.swift` |
| `KleynTests/UninstallerRulesTests.swift` | Ports `tests/uninstaller.test.ts`: what may be shown, macOS's own apps, IDs in names, the longest owner, ID and name matches (Chrome and Canary, shared names), marked at first, removed apps and their helpers, Apple and Shortcuts left out, `systemextensionsctl` parsing, extensions of removed apps, containers, `Info.plist` reading, search |

**Changed files:**

- **`Kleyn/Cleaner.swift`:** uses `DiskUsage`.
- **`Kleyn/ContentView.swift`:** Uninstaller loses its `comingSoon` text and Soon badge, and shows `UninstallerView`.
- **`Kleyn/KleynApp.swift`:** creates the `Uninstaller`.
- **`README.md`:** the tagline, Features, an "Uninstalling apps" usage section, Safety, and the new files.

**Not ported:** Claude's findings, `parseFindings`, refreshing after Claude's turn, the state tool, `parseDu`, `plutil`, `mdfind`, and the `osascript` reveal script with its test.

## Step 4: ADB Explorer

**Source:** `claude-mods/adb-explorer`, with `hooks/adb.ts` (parsing, quoting, delete rules) and `hooks/register.tsx`.

**What ports:**

- A device picker when more than one device is connected (USB or Wireless debugging), and a header with the model, Android version, free space and battery.
- Browse folders (start at `/sdcard`), go up, show or hide dotfiles, measure folder sizes.
- Mark items, then:
  - pull them to `~/Downloads/adb-explorer/<model>/` and open that folder in Finder
  - push files and folders by dragging them in from Finder
  - delete
- The last folder is remembered per device serial.

**Safety rules (keep them exactly):**

- Deletes only work strictly inside `/sdcard` (and `/storage/emulated/0`). Anything else is refused before asking.
- Every delete asks first. The default is to move items to `/sdcard/_adb_trash/<timestamp>/`. Delete permanently (`rm -rf`) is the other choice.
- Every adb call passes `-s <serial>`, and runs as an argument list (`Process` with `arguments`), never through a shell on the Mac.

**Finding `adb`:**

- Look in the Android SDK's `platform-tools` first (`~/Library/Android/sdk`), then `/opt/homebrew/bin` and `/usr/local/bin`.
- An app opened from Finder doesn't get your shell's environment variables, so `$ANDROID_HOME` and `$PATH` usually aren't available. Check them, but don't rely on them.
- Kleyn doesn't include its own `adb`.
- If none is found, show how to get it: Android Studio, or `brew install android-platform-tools`.

**Left out:** the `android-files` skill. Wi-Fi pairing stays in Android Studio or `adb pair`, and Kleyn just lists paired devices.

**Things to watch:**

- Pulling into `~/Downloads` makes macOS ask once whether Kleyn may access the Downloads folder.
- Long copies must not block the window and should show progress.
- `adb` runs as a child process. Hardened Runtime allows this without exceptions, but check that notarization still passes.

**Done when:**

- [ ] Browse, pull, push (drag and drop), and delete to the device trash all work on a real phone, over USB and Wi-Fi
- [ ] The delete rules and the quoting are unit-tested with the mod's test cases
- [ ] Missing `adb` shows clear instructions
- [ ] README updated, including Requirements and Safety

## Open decisions

- **Releases:** ship each step as its own release (1.2, 1.3, 1.4, 1.5), or ship them together as 2.0?
- **Menu bar:** only for Keep Awake, or a menu bar icon for Kleyn as a whole (lock keyboard, clean screen, keep awake)?
- **Full Disk Access:** Step 2 decided: a note on the page only when a scan couldn't read some folders. Step 3 can reuse it.
- **Keyboard shortcuts:** add the mods' shortcuts (`r` rescan, `t` trash…) to the app, or rely on buttons and standard ⌘ shortcuts? Step 2 decided: standard ⌘ shortcuts (⌘R, ⌘⌫).
- **DMG background:** its text ("Drag Kleyn to Applications") doesn't need to change. Check after the README and screenshots change.
- **App icon:** the keyboard-with-sparkles icon fits less once Kleyn does more. Keep it or redesign it later?
