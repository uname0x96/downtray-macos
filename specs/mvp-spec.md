# Download Inbox — MVP Spec

**Working name:** Download Inbox  
**One-liner:** A menu bar inbox for files that just landed on your Mac.  
**Platform:** macOS 14 Sonoma and later. Universal (Apple Silicon + Intel). Test on 14, 15, 26, 27. Do not support Ventura 13 or older.  
**Distribution:** Mac App Store first (sandboxed)  
**Pricing (v1):** Free with 20-file list + core actions. Paid one-time (~$7.99) unlocks rules, extra folders, history.  
**Timebox:** 2 weeks to usable TestFlight / notarized build.

---

## Problem

New files dump into `~/Downloads` from Safari, Chrome, AirDrop, Mail, Slack, Zoom.  
The Dock stack shows a few icons. Finder Recents often hides files that were never opened.  
The user knows the file arrived 20 seconds ago and still has to hunt.

Download Inbox is not a Finder, not a download accelerator, not a drop shelf.

## Job to be done

When a file arrives, I want to **see it, decide, and move on** in under 5 seconds.

---

## Scope — ship this

### Surfaces

1. **Menu bar extra**
   - Idle: tray icon.
   - Unread: badge count of files arrived since last open (cap at 9+).
2. **Popover panel** (~360 × 520 pt)
   - Header: title + filter chips + settings gear.
   - List of latest files (default 20).
   - Footer: “Open Downloads in Finder” · “Mark all seen”.
3. **Settings window** (standard Settings scene)
   - Folders to watch
   - Launch at login
   - Hotkey
   - Notification on new file (off by default)
   - Paid unlock

No main window on launch. App is an accessory (`LSUIElement`).

### Watched locations (MVP)

- `~/Downloads` — required, on by default
- `~/Desktop` — optional toggle
- User cannot add arbitrary folders in free tier

Use `NSMetadataQuery` + `DispatchSource` / FSEvents on granted folders. Prefer date added (`kMDItemDateAdded`) then modification date.

Ignore while writing:

- `*.download`, `*.crdownload`, `*.part`, `*.tmp`
- files whose size is still changing (poll 400ms × 3)

### List row

Each row shows:

- Icon / thumbnail (Quick Look thumbnail generator)
- Filename (1 line, truncate middle)
- Meta: relative time · size · kind · source if known
- Unread dot if not yet acted on / opened in Inbox

Source (nice-to-have, not blocker):

- `kMDItemWhereFroms` → host (`invoice.pdf · dropbox.com`)
- AirDrop heuristic: no where-froms + landed in Downloads recently

### Actions per file

Primary click = Open.  
Hover / swipe / `…` menu:

| Action | Shortcut in panel | Notes |
|---|---|---|
| Open | Return | Default app |
| Quick Look | Space | `QLPreviewPanel` |
| Reveal in Finder | ⌘R | |
| Copy path | ⌘C | POSIX path |
| Move to… | ⌘M | standard save panel; bookmark destination |
| Unzip here | ⌘U | `.zip` only in MVP; extract beside archive |
| Trash | ⌫ | moves to Trash, undo toast 5s |

Multi-select: Shift/⌘ click. Batch: Open / Trash / Move.

### Filters (chips, single-select)

All · Today · PDF · Images · Archives · Installers

Installers = `.dmg .pkg .app`.  
Archives = `.zip .tar .gz .7z` (unzip only `.zip` in MVP).

### Hotkey

Default: `⌃⌥D` (not ⌘Space). User-remappable.  
Opens popover and focuses first unread row.

### Permissions

- App Sandbox on
- Downloads folder read/write entitlement
- User-selected file read/write (Move to…)
- Desktop only after user toggle + grant
- Launch at login via `SMAppService`
- No Full Disk Access
- No Accessibility

If Downloads access is denied: empty state with one button “Grant access to Downloads”.

### Notifications

Off by default.  
If on: one banner per burst (debounce 3s), title = filename, action = Open.

---

## Intentionally out of v1

Do **not** build these. They turn the app into Finder / Hazel / Yoink.

- Full folder browser / nested tree
- Search across the whole disk
- Clipboard history
- Drag-and-drop shelf
- Download acceleration / browser takeover
- iCloud / Dropbox / Google Drive as sources
- Unzip rar / 7z
- Auto-rename with AI
- Sharing / AirDrop send
- Multiple windows
- iOS / iPad companion
- Sync rules across Macs
- Custom icon packs

Rules engine is **paid v1.1**, not free MVP:

- “After opening a `.dmg`, offer to Trash it”
- “PDFs from `stripe.com` → `~/Documents/Invoices`”
- Keep the hook in Settings: “Rules — Coming in Pro” so the upgrade path is visible without shipping the engine.

---

## Empty / edge states

- No files yet: “Nothing new. New downloads will show up here.”
- Permission missing: grant CTA
- File vanished (moved externally): row greys out, tap removes
- Duplicate names: show parent folder in meta line
- 0-byte / quarantine: still list; Open lets Gatekeeper do its job

---

## Supported macOS versions

**Minimum:** macOS 14.0 Sonoma  
**Architectures:** Universal (`arm64` + `x86_64`). Do not ship arm64-only in v1.  
**Declared in Xcode:** `MACOSX_DEPLOYMENT_TARGET = 14.0`, `ARCHS = arm64 x86_64`

| Version | Name | Ship? | Notes |
|---|---|---|---|
| 27 | Golden Gate | Yes | Apple Silicon only. Test on M-series. |
| 26 | Tahoe | Yes | Majority of users. Last official Intel OS. |
| 15 | Sequoia | Yes | Still material share; still receiving Apple security updates. |
| 14 | Sonoma | Yes — floor | Security support ended 14 Sep 2026. Keep as min to cover leftover Intel Macs and late upgraders. |
| 13 | Ventura | No | APIs we use exist (`MenuBarExtra`, `SMAppService`), but OS is unsupported and share is ~1%. Not worth a test target. |
| 12 and older | Monterey… | No | Would require legacy login-item APIs and drop SwiftUI `MenuBarExtra`. Out of scope. |

**Test matrix before each store build:** 14.8.x, 15.8.x, 26.7.x, 27.0 on at least one Apple Silicon machine. Intel smoke-test on 14 or 15 if a machine is available; otherwise rely on Universal build + one CI `x86_64` compile.

**Why not go lower:** the app’s stack already runs on 13, but stretching to Ventura/Monterey adds unsupported OS risk and QA time without adding a meaningful audience. “Support many versions” for this product means **14 through current**, not 10.15 through current.

**App Store listing:** Compatibility line = “Requires macOS 14.0 or later.”  
Build with current Xcode / macOS SDK as required by App Store Connect; that does not force raising the deployment target.

**Intel policy:** keep Universal while the min OS is 14. Dropping Intel would cut Tahoe/Sequoia users on 2019–2020 Intel Macs. Revisit only if we raise the floor to macOS 26+.

---

## Tech notes

- SwiftUI popover + AppKit status item (`MenuBarExtra` is 13+; we still target 14)
- Login item via `SMAppService.mainApp` (13+; no legacy `SMLoginItemSetEnabled` path)
- `NSWorkspace` to open / recycle
- Security-scoped bookmarks for any extra folder and Move destinations
- Thumbnail cache on disk, cap 100MB
- Do not hold file coordinators longer than an action
- No `#available` branches for OS older than 14. `#available(macOS 15/26/27)` only if a new API is opt-in.
- Localize UI strings from day one (EN first). No network calls.

Bundle ID suggestion: `app.downloadinbox.mac`  
App Store category: Productivity  
Age: 4+

---

## Success metric for MVP

A user who downloads a PDF can:

1. Hit the hotkey  
2. See that PDF at the top  
3. Open or Move it  

…without touching Finder. If that loop is not <5 seconds, the build is not done.

---

## Week plan

**Days 1–3:** status item, folder watch, list of 20, Open / Reveal / Trash  
**Days 4–6:** Quick Look, Unzip zip, filters, unread badge, hotkey  
**Days 7–8:** Settings, login item, permission empty states, Move to…  
**Days 9–10:** polish, quarantine-safe opens, crash/energy, screenshots  
**Days 11–14:** TestFlight, App Store listing copy, $7.99 Pro stub

---

## Store copy (English, draft)

**Name:** Download Inbox  
**Subtitle:** Triage files the moment they land  

**Promo:**  
Downloads pile up. This is the inbox for everything that just arrived — browser, AirDrop, attachments. Open, preview, file, or toss. Then get back to work.

**Keywords:** downloads, files, menu bar, AirDrop, organize, inbox, finder, pdf
