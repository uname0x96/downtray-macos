# Downtray

Website: https://uname0x96.github.io/downtray/ (source in [uname0x96/downtray](https://github.com/uname0x96/downtray)).

A menu bar inbox for the files that land in `~/Downloads` (or any one folder you point it at).
Press ⌃⌥D, see the latest twenty, act on them with one key: open, Quick Look, reveal, copy
path, move, unzip, trash with undo. Pro (one-time purchase) adds any extra folders, a 200-file
list, a searchable history, and rules that sort arrivals automatically. macOS 14+,
sandboxed, no network. English, Japanese, German and French; the app follows the macOS
language, and Settings > General has a Language picker for choosing one of the four directly.

The app's logic is headless: a Swift package (`InboxCore`) that any client can drive by sending
events and reading a JSON snapshot. The SwiftUI app, the `inbox-cli` tool, the shell tests and
an agent all use the same presenter. See `docs/architecture.md` for the design and
`docs/rules.md` for the rules behind it.

## Requirements

- Xcode 16 or newer (Swift 6 toolchain), macOS 14 or newer.
- [xcodegen](https://github.com/yonaskolb/XcodeGen) to generate the app project (`brew install xcodegen`).
- `jq` for the scenario script (`brew install jq`).

## Build and run

```sh
# Core package, CLI and unit tests
swift build
swift test

# The app
cd macOS
xcodegen generate
xcodebuild -project Downtray.xcodeproj -scheme Downtray -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath ../.build/DerivedData build
open ../.build/DerivedData/Build/Products/Debug/Downtray.app
```

The project signs with your "Apple Development" certificate (team ID in `macOS/project.yml`).
Without one, add `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` to the `xcodebuild` line; macOS will
then ask for Downloads access again after every rebuild. On first launch macOS asks
"Downtray would like to access files in your Downloads folder"; the app waits for the
answer before it lists anything.

## Ship it

`docs/app-store.md` has the archive and export commands, the App Store Connect checklist
(agreement, app record, the Pro in-app purchase, sandbox tester), review notes, and draft
listing and privacy-policy text. In short:

```sh
cd macOS
xcodebuild ... -archivePath ../.build/Downtray.xcarchive CODE_SIGN_STYLE=Automatic archive
xcodebuild -exportArchive -archivePath ../.build/Downtray.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath ../.build/export -allowProvisioningUpdates
```

## Drive it without the UI

```sh
.build/debug/inbox-cli events                              # the grammar
.build/debug/inbox-cli send "arrive a.pdf 120k example.com" hotkey --summary
.build/debug/inbox-cli send --trace "arrive a.zip 3m" hotkey unzip trash undo
.build/debug/inbox-cli repl                                # one event per line, snapshot per line
.build/debug/inbox-cli bench 20                            # focus/open/trash/undo timings
```

Attach to the running debug build instead (the bridge listens on `127.0.0.1:8791`):

```sh
.build/debug/inbox-cli --remote state
.build/debug/inbox-cli --remote send hotkey "filter today" "type docs" --summary
```

Pro flows use the same grammar. `pro on` stands in for the store, `pick` answers the folder
panel:

```sh
.build/debug/inbox-cli send "pro on" "pick /Users/me/Scans" "folder add" \
  "rule add Receipts host=example.com ext=pdf then move /Users/me/Receipts" \
  "arrive receipt.pdf 30k example.com" "history on" "search receipt" --summary
```

## Tests

```sh
swift test                         # tier 1: reducer, presenter, grammar
scripts/test-inbox.sh              # tier 2, headless
scripts/test-inbox.sh attached     # tier 2 against the running debug app; writes to ~/Downloads
```

## Layout

```
Package.swift            InboxCore + inbox-cli + InboxCoreTests
Sources/InboxCore/       model, events, effects, reducer, presenter, services, snapshot, grammar
Sources/inbox-cli/       headless / remote driver
Tests/InboxCoreTests/    tier 1
macOS/project.yml        xcodegen spec for the app
macOS/Downtray/     SwiftUI + AppKit app, MacServices, folder watcher, debug bridge
scripts/test-inbox.sh    tier 2
scripts/check-strings.sh string catalog vs. code, and every language complete
docs/                    architecture, rules
specs/                   the product spec
```

## Status

MVP per `specs/mvp-spec.md` with the popover per `specs/popover-spec.md`, the History
panel per `specs/history-spec.md` and the filters per `specs/filter-spec.md`, plus the Pro tier:
extra folders, 200-file list, searchable history, rules, unlocked through StoreKit 2 (product
`app.downtray.mac.pro`, to be created in App Store Connect, see `docs/app-store.md`).
Icon, privacy manifest, usage strings, four languages and a signed App Store export are in place. Running the app from the
Xcode scheme uses `macOS/Downtray/Pro.storekit` for a local sandbox purchase; a build
launched any other way reports "Pro is not available in this build" and stays free.

## License

MIT. See `LICENSE`.
