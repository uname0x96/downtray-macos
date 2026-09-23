# Shipping to the Mac App Store

What the repository already provides, what still happens in App Store Connect, and the text
to paste there. Everything below the checklist is a draft to edit, not a decision.

## Build and upload

```sh
cd macOS
xcodegen generate
xcodebuild -project Arrivals.xcodeproj -scheme Arrivals -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath ../.build/DerivedData \
  -archivePath ../.build/Arrivals.xcarchive CODE_SIGN_STYLE=Automatic archive
xcodebuild -exportArchive -archivePath ../.build/Arrivals.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath ../.build/export -allowProvisioningUpdates
```

`-allowProvisioningUpdates` lets Xcode create the "3rd Party Mac Developer Installer"
certificate and the Mac App Store provisioning profile on first use (it did on this machine).
The result is `.build/export/Arrivals.pkg`, signed for App Store Connect. Upload it with
the Transporter app, or open the `.xcarchive` in Xcode's Organizer and press Distribute App.
Notarization is not needed for App Store builds.

Bump `CFBundleVersion` in `macOS/project.yml` before every upload; App Store Connect rejects a
build number it has seen.

## Checklist

Done in the repository:

- [x] App icon, all ten sizes (`scripts/icon/make-icon.swift` regenerates them).
- [x] Privacy usage strings for Downloads, Desktop and Documents in `Info.plist`.
- [x] `PrivacyInfo.xcprivacy`: no tracking, no collected data, reasons for UserDefaults
      (CA92.1) and file timestamps (DDA9.1, 3B52.1).
- [x] App Sandbox with only Downloads, user-selected files and app-scoped bookmarks. The
      release entitlements have no network entitlement; the debug bridge is `#if DEBUG`.
- [x] Hardened runtime, version 1.0.0 (1), copyright string.
- [x] StoreKit 2 for the non-consumable `app.arrivals.mac.pro`, with a local
      `Pro.storekit` for testing from the Xcode scheme.
- [x] Release archive and App Store export succeed with automatic signing.

Only possible in App Store Connect (account owner):

- [ ] Accept the Paid Apps Agreement and fill in banking and tax forms. Without this the
      in-app purchase never leaves "Missing Metadata" and the app cannot be sold.
- [ ] Create the app record: name "Arrivals", bundle id `app.arrivals.mac`,
      primary category Productivity, SKU of your choice.
- [ ] Create the in-app purchase: Non-Consumable, product id `app.arrivals.mac.pro`,
      reference name "Pro", price tier for $7.99, display name "Arrivals Pro",
      description from `Pro.storekit`, a 1024×1024 promotional image is optional. Attach it
      to the first version under "In-App Purchases and Subscriptions" so it is reviewed with
      the app.
- [ ] Add a Sandbox tester account (Users and Access > Sandbox) and buy Pro once on a
      TestFlight or development build signed for the store, to confirm the store path outside
      the local `.storekit` file.
- [ ] Privacy policy URL (required because of the in-app purchase) and support URL. A draft
      policy is below.
- [ ] App privacy questionnaire: "Data not collected".
- [ ] Screenshots: at least one 1280×800 or 1440×900 (or the 2560×1600 / 2880×1800 Retina
      sizes) of the popover with a few files, one of Settings, one of the rule editor.
- [ ] Age rating: none of the content flags apply (4+).
- [ ] Export compliance: the app uses no encryption beyond what macOS provides; answer "No"
      to the custom encryption question.

Still worth doing before submitting:

- [ ] Run the Release build on a second Mac or a fresh user account: first-launch Downloads
      prompt, Desktop grant, login item approval, notification permission, a purchase with a
      Sandbox tester.
- [ ] Look at the Pro screens (Settings > Rules, the rule editor sheet, the search field and
      the History toggle in the popover) and adjust spacing and copy.
- [ ] Localization: the string catalog is still empty because command-line builds do not
      extract strings; build once in the Xcode IDE to populate `Localizable.xcstrings`, or
      leave it, the app then ships English only.
- [ ] Replace the placeholder copyright holder ("Arrivals") with the legal name.

## Review notes (paste into "Notes" for App Review)

> Arrivals is a menu bar utility (it has no Dock icon). After launch, press
> Control-Option-D or click the tray icon in the menu bar to open the inbox. The first time,
> macOS asks for access to the Downloads folder; please allow it, then drop any file into
> ~/Downloads and it appears at the top of the list.
>
> The gear button opens Settings. The Pro in-app purchase ("Arrivals Pro",
> non-consumable) is on the Settings window; it unlocks extra watched folders, a longer list
> with search, history, and rules. Rules act only on files that land in folders the user
> chose to watch, with actions the user configured (move to a folder the user picked, move to
> Trash with undo, mark as seen, or ask first). The app has no network access and collects no
> data.

## App Store description (draft)

**Subtitle** (30 chars): Your downloads, one key away

**Promotional text**: Press ⌃⌥D and act on what just landed in Downloads: open, Quick Look,
move, unzip or trash it, without leaving what you were doing.

**Description**

Arrivals puts the files that just arrived in your Downloads folder one keystroke away.
Press ⌃⌥D and the newest files are there, newest first, with a Quick Look thumbnail and where
they came from.

Act on a file with one key: Return opens it, Space previews it, ⌘R reveals it in Finder, ⌘C
copies its path, ⌘M moves it to a folder, ⌘U unzips it in place, and ⌫ moves it to the Trash
with a five-second undo. Filter by type (PDF, images, archives, installers) or to today's
files only. A badge on the menu bar icon counts what arrived while you were away, and an
optional notification tells you the moment a download finishes.

Arrivals Pro (one-time purchase) adds:
• Extra folders: watch your Desktop, a scanner folder, an AirDrop target, anything.
• A longer list, 200 files, with search.
• History: every file that ever landed, even after you moved it.
• Rules: sort arrivals automatically. Receipts from a shop into Receipts, installers
  straight to the Trash once opened, or just ask first.

Private by design: no account, no network, no analytics. Everything stays on your Mac, inside
the App Sandbox.

**Keywords** (100 chars): downloads,menu bar,files,inbox,finder,quick look,unzip,organize,
rules,productivity

**What's New (1.0.0)**: First release.

## Privacy policy (draft, host at the privacy policy URL)

> Arrivals does not collect, store or transmit any personal data. The app runs entirely
> on your Mac. It reads the folders you allow it to watch (Downloads by default, others only
> when you choose them) to show you the files there and to carry out the actions you ask for.
> Settings and the file history are stored locally in the app's sandbox container and never
> leave your computer. Purchases are handled by Apple through the App Store; the app receives
> only whether the purchase is present. The app makes no network connections. Contact:
> <support email>.

## Icon

`docs/icons/teal-tray.png` is the installed app icon, cut from the chosen artwork with
`scripts/icon/from-artwork.py` (removes background and shadow, squares the tile, 80 % of the
canvas). The menu bar glyph is `MenuBarIcon.imageset`, made from a black-on-white drawing with
`scripts/icon/menubar-template.py`. Earlier Gemini candidates (`flat`, `glossy`, `soft-3d`)
are kept alongside. To switch or to use a designed icon, run
`scripts/icon/make-iconset.sh <1024.png>`. New candidates:
`GEMINI_API_KEY=… scripts/icon/gen-gemini.sh out.png "style words"` (the free AI Studio tier
is enough); `scripts/icon/draw-icon.py` is the hand-drawn fallback that needs no key.
