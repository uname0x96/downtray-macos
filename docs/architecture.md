# Architecture

Downtray is a menu bar app whose whole behavior lives in one headless Swift package,
`InboxCore`. The macOS app, the command-line tool, the shell scripts and the unit tests all
drive the same presenter by sending events and reading one JSON snapshot of the model. The
rules this follows are in `docs/rules.md`; this document says how each rule maps to the code.

```
┌──────────────────────────── InboxCore (SwiftPM, no AppKit) ────────────────────────────┐
│  Event ──▶ InboxReducer.reduce(model, event) throws(EventError) ──▶ Step(model, effects) │
│                     ▲                                                     │              │
│                     │ result events                                       ▼              │
│              InboxServices (protocol)  ◀───── InboxPresenter (Mobius loop, @MainActor)   │
│                     │                                   │                                │
│        FakeServices │ MacServices                       ▼                                │
│        (in memory)  │ (the Mac)                Snapshot (JSON contract)                  │
└─────────────────────┼───────────────────────────────────┼────────────────────────────────┘
                      │                                   │
        macOS/Downtray (SwiftUI + AppKit)     inbox-cli · DebugBridge · scripts/test-inbox.sh
```

## Layout

| Path | What it holds |
|---|---|
| `Sources/InboxCore/Models.swift` | `InboxModel` and its value types: files, filters, watched folders, settings, toast, pending undo. Derived data (`visibleFiles`, `badgeCount`, `duplicateNames`, `emptyState`) is computed here so every client sees the same answer. |
| `Sources/InboxCore/Events.swift` | `Event`: everything that can happen, from the environment, the panel, the settings window, or as the outcome of an effect. `EventError`: the typed rejections. |
| `Sources/InboxCore/Effects.swift` | `InboxEffect`: every side effect the loop can ask for. |
| `Sources/InboxCore/Reducer.swift` | `InboxReducer.reduce`: the one function that changes state. Pure, synchronous, throws `EventError` for events that do not apply. |
| `Sources/InboxCore/Update.swift` | The Mobius `Update` wrapper: unchanged model → `.dispatchEffects`, rejection → `.reject(error)` effect. |
| `Sources/InboxCore/Services.swift` | `InboxServices`: the interface the presenter owns for talking to the world. |
| `Sources/InboxCore/Presenter.swift` | `InboxPresenter`: builds the Mobius loop, routes each effect to a service call, feeds results back as events, publishes `model` for SwiftUI. `send` throws the typed error; `dispatch` records it in `lastError`. |
| `Sources/InboxCore/FakeServices.swift` | In-memory implementation used by tests and the headless CLI. Keeps a log of calls so tests can assert on effects that reached the world. |
| `Sources/InboxCore/Snapshot.swift` | `Snapshot`: the JSON view of the model. Everything the UI shows is derivable from it. |
| `Sources/InboxCore/EventSyntax.swift` | The text grammar (`arrive a.pdf 120k example.com`, `hotkey`, `trash`, ...) shared by the CLI and the bridge. |
| `Sources/InboxCore/Hotkey.swift` | Key code + modifier value type, with display (`⌃⌥D`) and command-line (`ctrl+alt+d`) forms. |
| `Sources/InboxCore/Bridge.swift` | `BridgeResponse`: the wire format of the debug bridge. |
| `Sources/inbox-cli/main.swift` | `inbox-cli`: headless (in-process presenter + `FakeServices`) or `--remote` (the running app). |
| `macOS/Downtray/*` | The app: status item, popover, settings window, `MacServices`, folder watcher, hotkey, Quick Look, thumbnails, notifications, and the debug bridge. |
| `Tests/InboxCoreTests/*` | Tier 1: reducer specs, presenter wiring with fakes and a test clock, grammar and snapshot round trips. |
| `scripts/test-inbox.sh` | Tier 2: one scenario script that runs headless or against the real app. |

## The Mobius mapping

Mobius.swift is used as the loop runtime, not as the design. The design is the reducer:

- **Model** is `InboxModel`, a value type. Navigation (`panelOpen`), focus, selection, the
  pending "Move to…" and the undo window are all data in it (rule 2).
- **Event** is `Event`. Results of effects (`trashed`, `moved`, `unzipped`, `restored`,
  `undoExpired`, `destinationChosen`, ...) are events like any other (rule 3).
- **Update** is `InboxUpdate.update`, a thin adapter over `InboxReducer.reduce`. The reducer
  is the tested API; the adapter only turns `Step` into `Next` and a thrown `EventError` into
  the `.reject` effect (rule 4). The reducer stays synchronous and framework-free so tests use
  `MobiusTest.UpdateSpec` or call it directly.
- **Effect handler** is built in `InboxPresenter.makeLoop` with `EffectRouter`, one route per
  effect case. Each route calls one `InboxServices` method on the main actor and dispatches
  the result as an event. Timers (undo expiry, toast dismissal) use an injected clock so
  tests advance time instead of sleeping.
- The loop runs on the main thread. `send` is synchronous: when it returns, `model` already
  reflects the event, so the bridge can answer after the UI's next run-loop turn.

## Effects and their real implementations

| Effect | `MacServices` |
|---|---|
| `loadSettings` / `saveSettings` | `UserDefaults` (JSON), login item state read from `SMAppService`. |
| `startWatching` / `stopWatching` | `FolderWatcher`: `DispatchSource` on the directory, 150 ms debounce, rescan with `.addedToDirectoryDateKey`; partial downloads (`.download`, `.crdownload`, `.part`, `.tmp`) are skipped and new files are reported only after their size is stable for 3 polls at 400 ms. Source comes from the `kMDItemWhereFroms` xattr; AirDrop is inferred when a file lands in Downloads without it. |
| `requestAccess` | `NSOpenPanel` on the folder; the choice is kept as a security-scoped bookmark. |
| `openFiles`, `reveal`, `openFolder` | `NSWorkspace`. Opening goes through Gatekeeper like Finder. |
| `quickLook` | `QLPreviewPanel` hosted by the popover's `NSHostingController`; the popover stops being transient while the panel is up. |
| `copyToPasteboard` | `NSPasteboard`. |
| `chooseDestination`, `move` | `NSOpenPanel` (destination remembered as a bookmark) then `FileManager.moveItem` with unique names. |
| `unzip` | `/usr/bin/ditto -x -k` into a folder named after the archive, next to it. |
| `trash`, `restore` | `FileManager.trashItem` (all or nothing) and a move back from the returned Trash URL. |
| `scheduleUndoExpiry`, `scheduleToastDismiss` | Presenter timers (5 s and 4 s). |
| `setLaunchAtLogin` | `SMAppService.mainApp`; opens System Settings when approval is required. |
| `registerHotkey` | Carbon `RegisterEventHotKey`, default ⌃⌥D. |
| `showPanel`, `hidePanel` | The status item's `NSPopover`. |
| `notify`, `requestNotificationPermission` | `UNUserNotificationCenter`, bursts folded into one notification per 3 s. |
| `chooseFolder` | Pro. `NSOpenPanel` for a folder to watch; the choice is stored as a security-scoped bookmark keyed by path so it survives relaunches. |
| `loadHistory`, `saveHistory` | Pro. `history.json` in the container's Application Support (newest first, capped at 1000). |
| `checkProStatus`, `purchasePro`, `restorePurchases` | StoreKit 2: `Transaction.currentEntitlements` for the non-consumable `app.downtray.mac.pro`, `Product.purchase()`, `AppStore.sync()`. Without a store (no `.storekit` config, no App Store receipt) purchase fails with a toast and the app stays free. |

## Reading the model

`InboxModel` keeps `files` keyed by POSIX path. `recentFiles` are the candidates: enabled
folders only, files (folders too with `settings.includeFolders`), younger than
`settings.retention` (24 h / 7 d / 30 d, default 7 d) and newer than `settings.listClearedAt`
("Clear List" in Settings). The panel lists `visibleFiles`: `recentFiles` through the chip
(`filter`: All, 1h, Today, Unread), the Type menu (`typeFilter`: Docs, Images, Media, Archives,
Apps, from `TypeGroup.forExtension` plus `settings.typeOverrides`) and the Pro `query`, all
ANDed, newest first, capped at `listLimit` (20, Pro 200). The query matches the name, the
extension with or without its dot, the group's English name or its localized label
(`typeLabels`, injected by the app) and the web host. With the All or Today chip and no query
the list is grouped by `inboxSections` (Just now < 15 min, Earlier today, Yesterday, This week,
Earlier; Today shows the first two); 1h, Unread and a search are flat. The chip and type are
saved (`selectedChip`, `selectedType`); at launch Today falls back to All once the Downloads
scan shows nothing from today (`chipResolved`). `now` is the moment the panel opened
(`setToday(Date)`), so "1h" and "Just now" count from it.

The badge is the number of unread files in `recentFiles` (`badgeCount`, off with
`settings.showBadge`). `unread` is per file and is cleared by Open, Show in Finder, Mark as
Read, "Mark all seen", or, with `settings.markReadOnClose`, for the visible rows when the
panel closes; opening the panel alone never clears it, and Mark as Unread puts it back. A
download that lands again at the same path (`fileArrived` with a newer `addedAt`) is a new
arrival: unread again, back at the top. A file whose watcher reports it gone leaves the list at
once (`fileRemoved`); the user moved or deleted it themselves, so there is nothing to
announce. Only History (Pro) keeps a "Gone" row for it. `InboxFile.missing` marks those rows;
`dismiss` remains for scripts.

Empty states (`emptyState`): `needsAccess`; `nothingNew` when `recentFiles` is empty ("No
recent downloads" with an Open Downloads Folder button); `noMatches` when a query or a type
hides everything; otherwise per chip `nothingLastHour`, `nothingToday`, `caughtUp`.

### Pro

`settings.proUnlocked` gates four things in the reducer, each with a typed `proRequired`
error: extra folders (`addFolder`, `removeFolder`), a 200-file list with a name `query`,
`historyMode`, and `rules`. The store is the source of truth: `settingsLoaded` asks for
`checkProStatus`, and `proStatusChanged` overwrites the saved flag either way, so a stale
"unlocked" flag cannot outlive a refund.

- **Extra folders** are `FolderKind.custom(path)` (the raw value is the absolute path). They
  join `folders` at load from `settings.extraFolders` and are watched like Downloads.
- **History** is `[HistoryEntry]`, one line per file that ever arrived in a watched folder
  (path, size, kind, source, date), recorded in `fileArrived` and saved after each arrival. In
  history mode the same panel gets its own chrome per `specs/history-spec.md`: a back button,
  a "History" title, Done, a search field and an All / Available / Gone segment
  (`historyFilter`, event `setHistoryFilter`); no inbox chips, no footer, no gear. It lists
  `historyFiles` (files only, never folders) newest first, grouped by local calendar day with
  "Today" / "Yesterday" / weekday / date headers from Foundation. An Available row is an inbox
  row without the unread dot; a Gone row (`missing`) is shorter and secondary, shows
  "relative time · Moved or deleted", cannot be opened, and has one action, "Remove from
  history" (`removeFromHistory`, also on click and ⌫). If Open or Reveal finds the file gone,
  the row turns Gone in place (`onFileVanished` → `fileRemoved`). Empty states are
  `historyEmpty` ("Nothing in history yet.") and `noMatches`. The inbox shows the same search
  field with Pro, whose list holds 200 files (the free inbox of 20 has none, per the popover
  spec); a query with no hits there is `noMatches` too. Entering or leaving History clears the
  query, so each panel starts its search empty, and leaving History marks nothing seen. History
  is reached from the gear menu (Pro) or the "Show older files" row that ends the list when
  the folders hold more than it shows (`hasOlderFiles`); without Pro that row and the gear's
  "Downtray Pro…" open the Pro sheet drawn inside the panel (`paywallShown`, events
  `showOlderFiles` / `dismissPaywall`). "Clear history" lives only in Settings.
- **Rules** are `Rule { trigger, match, action }`. The trigger is arrival or "after opened";
  the match is any subset of kind, host, name substring and extension; the action is move to
  a folder, trash, mark seen, or `suggestTrash`, which puts a `Suggestion` on the model that
  the popover shows as a notice with Yes and dismiss. The first enabled matching rule wins, and
  it runs after the arrival has been recorded and notified.

## Event grammar

`inbox-cli events` prints the list. The same lines work in `inbox-cli send`, `inbox-cli repl`,
over the bridge, and in `scripts/test-inbox.sh`. Files are addressed by name when unique, or
by full path. `arrive` and `vanish` simulate the watcher and exist for the headless target;
the attached target sees real files.

Filter lines: `filter all|1h|today|unread`, `type any|docs|images|media|archives|apps`,
`type map <ext> <group|none>`, `type reset`, `search <text>`. Row actions: `open`, `reveal`,
`copy-path`, `copy-name`, `read`, `unread`, `trash`, `move`, `unzip`. Settings: `folders on|off`,
`keep day|week|month`, `read-on-close on|off`, `badge on|off`, `clear-list`, `seen` (mark all).

Pro events have their own lines: `pro on|off` (stands in for the store), `folder add`,
`folder remove <name>`, `history on|off|all|available|gone|clear`, `forget <file>`, `search <text>`,
`rule add <name> [kind=pdf] [host=example.com] [name=invoice] [ext=pdf] [on=arrival|opened] then move <path>|trash|seen|suggest-trash`,
`rule remove|enable|disable <name>`, `accept`, `dismiss-suggestion`, `unlock`, `restore`.

Session commands (not events): `state`, `reset`, `settle`, `dest <path>`, `pick <path>` (answers
the next "Add Folder…" panel) and, on the bridge, `settings` (what the gear button does) and
`windows` (visible windows, to check it opened) and `frames` (status item and popover
rectangles, top-left origin, for `scripts/click.swift`). A scripted `pick` grants no sandbox bookmark,
so in the attached tier the folder must be somewhere the app can already read, such as inside
`~/Downloads`.

## Debug bridge

`DebugBridge` (debug builds only, `#if DEBUG`) listens on `127.0.0.1:8791`. One request line,
one `BridgeResponse` JSON line: `{"ok": true, "snapshot": {...}}` or
`{"ok": false, "error": "…", "snapshot": {...}}`. After each event it waits two run-loop turns
and then until the popover's shown/hidden state matches `model.panelOpen`, so a script can
send the next line as soon as the panel is really there (rule 11). The debug entitlements add
`com.apple.security.network.server` for the listener; the release entitlements do not.

## Tests

| Tier | Where | What |
|---|---|---|
| 1 | `swift test` | Reducer specs with `MobiusTest`, presenter wiring with `FakeServices` and a `TestClock`, grammar/snapshot round trips. Milliseconds. |
| 2 | `scripts/test-inbox.sh [headless\|attached\|both]` | The spec's success loop and edge cases as one scenario, asserted on snapshots, then the Pro loop (unlock, extra folder, history, search, a move rule, a suggest-trash rule). Headless runs in-process; attached drives the real app, writes real files to `~/Downloads`, checks the pasteboard, the Trash, `ditto` and the rule's move on disk. |
| 3 | `scripts/test-click.sh`, and manual | Real mouse clicks through `CGEvent` (needs Accessibility for the terminal): status item, then one click on a row must open the file. The rest still needs a human: the Downloads privacy prompt, System Settings approval for login items, Quick Look rendering. |

## Decisions worth knowing

- **Primary click opens the file**, as the spec asks; ⌘-click and ⇧-click select. Keyboard
  users move with arrows and act with Return/Space/⌘R/⌘C/⌘M/⌘U/⌫.
- **Nothing is selected when the panel opens.** The spec's "focus the first unread row" was
  dropped on request: the pointer highlights the row under it with the same ring keyboard
  focus uses, and the first arrow key starts from the top (↓) or bottom (↑). Focus is only
  ever cleared by a filter change, never moved to another row behind the user's back.
- **A row is a file you can drag.** `FileRowView` offers an `NSItemProvider` for its file URL
  on drag, so a row can be dropped into Finder, Mail, a browser upload field or any other
  drop target; a drag carries one file (a SwiftUI drag item has one provider) and marks that
  file read, since it was used. The Settings window is a fixed 440 × 640 pt so the grouped
  form scrolls; sized to its content it grew past the bottom of the screen once List, Types
  and Danger were added.
- **The product is Downtray; the code keeps "inbox".** The app, bundle id (`app.downtray.mac`),
  product id, history folder and every user-facing string say Downtray. `InboxCore`, `inbox-cli`,
  `InboxReducer` and friends keep their names because the list they model is an inbox for
  arrivals, and renaming a package churns every import for no behavior. The product was
  called Arrivals until the App Store rejected the name as taken; it became Downtray before
  the first upload, while the bundle id could still change. After an upload it is fixed for good.
- **`DispatchSource` instead of `NSMetadataQuery`.** Spotlight indexing can lag or be disabled
  for Downloads; a directory event source plus a rescan is immediate and needs no index.
- **`ditto` instead of a zip library.** It is on every Mac, handles resource forks and large
  archives, and runs inside the sandbox because the output folder is next to the archive in
  a folder the app already has access to.
- **Signing.** Local builds use the developer's "Apple Development" certificate so macOS keeps
  the "access your Downloads folder" grant across rebuilds; with an ad-hoc signature every build
  is a new app to the privacy system. Pass `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` to
  `xcodebuild` to build without a certificate.
- **The model leads the popover, in both directions.** `hotkeyPressed` and the status item
  click both go through the reducer, which sets `panelOpen` and asks for `showPanel` or
  `hidePanel`. The popover does not animate, so show and close complete synchronously and the
  bridge can answer as soon as the effect returns. The popover delegate only reports a close
  the user caused (click outside, Escape, another app activating) and re-closes a popover that
  finished showing after the model had already closed it.
- **The popover takes the first click.** `showPopover` activates the app with
  `ignoringOtherApps` (the cooperative `activate()` is refused while another app is frontmost)
  and the hosting view is a `FirstMouseHostingView` that accepts the first mouse, so a click
  on a row acts on the row even when the window was not key. `PopoverHostingController` is a
  plain `NSViewController` around that view; the Quick Look handshake lives there as before.
- **Menu bar icon.** A template image from the asset catalog (`MenuBarIcon`, 18 pt), tinted
  by macOS; the unread count is the button's title next to it. Left click toggles the panel;
  right click shows a menu with Settings… and Quit. Quit is also ⌘Q in the panel and a button
  in Settings, since an accessory app has no Dock icon to quit from. Quitting is UI-only
  (`NSApp.terminate`), not a model event.
- **Settings opens through SwiftUI's `openSettings` action.** The private `showSettingsWindow:`
  selector stopped working on macOS 27. A zero-size `SettingsOpener` view inside the popover
  captures the environment action so AppKit code and the bridge can call it; the app activates
  itself first because an accessory app's window would otherwise open behind the front app.
- **Real home directory.** Inside the App Sandbox, `FileManager.urls(for: .downloadsDirectory)`
  and `NSHomeDirectory()` return the app container (`~/Library/Containers/<id>/Data/...`), and a
  `DispatchSource` cannot open that path. `WatchedFolder.standard` reads the real home from the
  password database (`getpwuid`) and the Downloads entitlement covers the real `~/Downloads`.
- **No network.** The core has no networking; the app's only listener is the debug bridge on
  loopback. StoreKit talks to Apple on the app's behalf; the core only sees a `Bool`.
- **Outcomes never throw.** Events that come back from an effect (`folderChosen`,
  `purchaseFailed`, …) have nobody waiting for an error, so the reducer answers them with a
  toast; thrown `EventError`s are reserved for events a caller sent and can see rejected.
- **Pro is data, not a build.** Every Pro path runs in the free build behind `isPro`, so the
  headless tier covers it with `pro on` and the fake store, and the real app is exercised the
  same way through the bridge. `Pro.storekit` in the scheme gives a local sandbox purchase when
  the app is run from Xcode.
- **Localization: the core speaks English, the app speaks the user's language.** Toasts and
  suggestions are data (`ToastText`, `Suggestion`) whose English `message` is what the
  snapshot reports, so the CLI, the scripts and the tests keep asserting on one wording
  regardless of locale. The app maps each case, and every enum label (`FileFilter`,
  `FileKind`, `FolderKind`, rule summaries), to the string catalog in
  `macOS/Downtray/Localized.swift`. Every UI string is `String(localized: "dotted.key",
  defaultValue: "English", comment: …)`; the one catalog, `Localizable.xcstrings`, holds
  English, Japanese, German and French, with plural variants where a count is shown. Dates
  and sizes come from Foundation formatters, so they follow the locale for free. The brand
  name, shortcut glyphs, file extensions and the debug bridge stay untranslated.
  `scripts/check-strings.sh` fails when code and catalog drift or a language misses a key.
  The language picker in Settings > General is a setting like any other (`Settings.language`,
  event `setLanguage`, grammar `language ja|system`); `saveSettings` mirrors it into the app's
  `AppleLanguages` default, the key System Settings > Language & Region > Applications writes,
  so both routes agree and Foundation picks the language at the next launch. Picking a language
  that differs from the localization the running process shows only asks, with the alert System
  Settings itself uses: Relaunch Now saves the choice and restarts, Later discards it, so the
  picker never shows a language the app is not displaying. `AppDelegate.relaunch()` opens a second
  instance and quits; the newcomer normally hands over to a running copy, so the leaving one first
  writes its pid to defaults (launch arguments do not reach a sandboxed app), and the newcomer
  waits for that pid to exit, forcing it if a closing sheet stalls the quit.
  The four filter chips (All, 1h, Today, Unread) and the Type menu button sit on one row at
  360 pt in every language: a chip hugs its label and never wraps, so a label that does not
  fit is shortened in the catalog. The Type button is Liquid Glass on macOS 26 and later
  (`.glass`, `.glassProminent` while a type is selected) and a tinted capsule before that. A row's
  second line is `time · size · kind`, where the kind is the system's name for image, archive,
  disk image, package, application and media types and the uppercase extension otherwise
  (`InboxFile.rowKind`), falling back to the extension when the line would overflow; the
  source (host or AirDrop) moved to the row's tooltip and menu caption. The bridge's `screenshot [dir]`
  renders the popover and the visible windows to PNG from inside the app (no screen-recording
  permission), which is how each locale's layout was checked.
