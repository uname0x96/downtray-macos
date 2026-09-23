# Downtray — Filter & Recents Spec

Version: 1.0  
Date: 2026-09-23  
Audience: implementation (Claude / engineer)  
Product: Downtray — menu bar popover that shows **the newest files that just landed in watched folders** (default `~/Downloads`).

This is **not** a download manager. Do not add Active / Paused / Failed / speed / queue.

---

## 1. Goal

User opens the tray to answer: **“What file just appeared?”**

Primary jobs, in order:

1. See files that arrived in the last hour / today.
2. See files not opened yet (unread).
3. Jump to a file by name or type.

Non-goals:

- Pause, resume, retry, connections, torrents.
- Full Finder replacement.
- Browsing the entire disk history.

---

## 2. Replace current chip row

### Remove

`PDF` · `Images` · `Other`

These mix a time axis (`Today`) with a type axis and overflow the popover.

### New header layout

```
Downtray                                          ⚙
[ All ] [ 1h ] [ Today ] [ Unread ]

[ Type ▾ ]  [ 🔍  Name or type                 ]
```

Constraints:

- One chip row. No wrap. No second chip row.
- Max 4 time/state chips.
- Type is a **menu button**, not a chip.
- Search is full width under the chips (current position is fine).
- Default selection on launch: `Today` if that set is non-empty, else `All`.
- Chip selection is **single-select**.

---

## 3. Filter model

Filters are AND-combined.

```
visible = items
  .filter(timeOrReadChip)
  .filter(typeMenu)        // ignored when menu = Any
  .filter(searchQuery)     // ignored when query blank
  .sorted(newestFirst)
```

`newestFirst` = `arrivedAt` descending, then `name` ascending.

Only one chip is selected. Type menu is independent. Search is independent.

### 3.1 Chips

| ID | Label | Rule |
|---|---|---|
| `all` | All | Every retained item (after retention policy). |
| `1h` | 1h | `now - arrivedAt <= 60 minutes`. |
| `today` | Today | `arrivedAt` is in local calendar today. |
| `unread` | Unread | `isUnread == true`. |

Chip badge (optional, small number on the chip):

- `1h`, `Today`, `Unread` may show count of matching items **before search**.
- Hide badge when count is 0.
- Do not badge `All`.

Empty chip set: keep chip enabled. List shows empty state for that filter (see §8).

### 3.2 Type menu

Button label:

- `Type` when `Any`
- Selected group name when not Any (`Docs`, `Images`, …)

Menu items:

1. Any
2. separator
3. Docs
4. Images
5. Media
6. Archives
7. Apps

No `Other` item. Uncategorized files only appear when Type = Any (or search matches).

Checkmark on the current type.

### 3.3 Type taxonomy (macOS Downloads)

Match **UTI if available**, else lowercase extension. First match wins.

**Docs**

- pdf
- doc, docx, docm, odt, rtf, txt, md
- xls, xlsx, csv, tsv, ods, numbers
- ppt, pptx, key, odp
- pages
- epub, mobi
- json, xml, yaml, yml

**Images**

- png, jpg, jpeg, gif, webp, heic, heif, bmp, tiff, tif, svg, ico, raw, dng

**Media**

- mp4, m4v, mov, mkv, webm, avi, mpeg, mpg
- mp3, m4a, aac, wav, flac, aiff, ogg

**Archives**

- zip, rar, 7z, tar, gz, tgz, bz2, xz

**Apps** (Mac installers / bundles dropped as files)

- dmg, pkg, app (if a file, not a directory we skip — see §6)
- exe, msi, apk (still categorize; user may download them)

A file can only belong to one group.

Settings must allow adding an extension → group mapping. Built-in table is the default; user overrides win.

### 3.4 Search

Placeholder: `Name or type`

Case-insensitive. Trim whitespace.

Match if **any** is true:

- filename contains query
- extension equals query, with or without leading `.` (`pdf` and `.pdf`)
- type group name contains query (`docs`, `images`)
- source host contains query if we have a source URL (`github.com`)

When query is non-empty:

- Keep the selected chip (Today + “invoice” is valid).
- Do **not** auto-reset Type.
- Debounce 150ms.

Empty query = no search constraint.

---

## 4. List

### 4.1 Group headers (visual only)

Do not use headers as filters. Headers depend on the selected chip.

If chip = `1h` or `unread` or search is active: **no section headers** (flat list).

If chip = `all` or `today`:

| Header | Rule |
|---|---|
| Just now | `now - arrivedAt < 15 minutes` |
| Earlier today | today and not Just now |
| Yesterday | local yesterday |
| This week | last 7 local days, excluding today/yesterday |
| Earlier | older |

Hide a header if that section has 0 visible rows.

`today` chip only shows Just now + Earlier today.

### 4.2 Row

```
[file icon]  filename
             2.1 MB · 3m ago · Safari
                              [• unread]
```

- Icon = system file icon.
- Secondary line: size · relative time · source if known.
- Unread indicator: small dot at trailing edge, or bold filename. Pick one; do not do both.
- Click row = Open file (Launch Services) **and** mark read.
- Hover (optional): Show in Finder button.

Relative time:

- `< 1 min` → `Just now`
- `< 60 min` → `12m ago`
- same calendar day → `3:41 PM`
- else → `Sep 22`

### 4.3 Sort

Always newest `arrivedAt` first inside each section.

### 4.4 Cap

Popover lists at most `retention.maxItems` (default 50) after filters.

If more exist, footer: `Showing 50 newest` — not a paging control.

---

## 5. Item model

```ts
type DownloadItem = {
  id: string              // stable: folder URL bookmark + inode or path hash
  path: string
  name: string
  ext: string             // lowercase, no dot
  typeGroup: 'docs' | 'images' | 'media' | 'archives' | 'apps' | 'other'
  sizeBytes: number
  arrivedAt: Date         // see §6.2
  isUnread: boolean
  lastOpenedAt?: Date
  sourceURL?: string
  sourceApp?: string      // Safari, Chrome, … if known
}
```

Persist `id`, `arrivedAt`, `isUnread`, `lastOpenedAt`, `sourceURL` in a local store so unread survives relaunch.

If the file is deleted on disk, drop the item from the list (do not keep ghost rows).

---

## 6. Filesystem rules (core product)

Watch default folder: `~/Downloads`.  
User may add more folders in Settings.

Use FSEvents / `NSMetadataQuery` / directory watcher. Debounce bursts 300ms.

### 6.1 Ignore

Never show:

- Names starting with `.`
- Temp / in-progress:  
  `.download`, `.crdownload`, `.part`, `.aria2`, `.tmp`, `~$*`
- `.DS_Store`, `desktop.ini`
- Directories, unless Settings “Include folders” is on (default **off**)
- Files smaller than 0 bytes that disappear within 2s (create-then-rename races)

When a `.crdownload` / `.download` **renames** to a final name, that is the moment the item is born.

### 6.2 `arrivedAt`

Priority:

1. Time the watcher first observed a **stable** final file (after rename from temp).
2. Else file creation date.
3. Else modification date.

Do not use “last opened” as arrivedAt.

If the same path is replaced (`report.pdf` downloaded again):

- Treat as a **new arrival**.
- New `arrivedAt = now`.
- Reset `isUnread = true`.
- Keep same `id` if path unchanged, or new id if inode changed — prefer inode change = new item.

If the system adds `report (1).pdf`, it is a separate item.

### 6.3 Unread

`isUnread = true` when item is created.

Mark **read** when any of:

- User opens the file from the popover
- User chooses Show in Finder
- User chooses Mark as Read

Do **not** mark all read merely because the popover opened.  
(Setting exists: “Mark visible as read when popover closes” — default **off**.)

`Unread` chip = `isUnread == true`, independent of age (an unread file from yesterday still appears).

### 6.4 Menu bar badge

Badge count = number of unread items in retention window.  
0 → hide badge.

---

## 7. Context menu (row)

1. Open
2. Show in Finder
3. separator
4. Mark as Read / Mark as Unread (toggle)
5. Copy Path
6. Copy Name
7. separator
8. Move to Trash

No “Retry download”.

---

## 8. Empty states

| Situation | Title | Body |
|---|---|---|
| Watch folder empty / nothing retained | No recent downloads | New files in Downloads will show up here. |
| Chip `1h` empty | Nothing in the last hour | |
| Chip `today` empty | Nothing today | |
| Chip `unread` empty | You’re all caught up | |
| Search no hits | No matches | Try a file name or type like pdf. |

Primary empty action when no items at all: `Open Downloads Folder`.

---

## 9. Settings (gear)

Window or nested popover. Keep short.

**Watched folders**

- List of folders (default `~/Downloads`)
- Add / Remove
- Include subfolders: default off
- Include folders as items: default off

**List**

- Keep items: `24 hours` / `7 days` / `30 days` (default 7 days)
- Max items: `50` (default)
- Hide temp files: on (locked on)
- Mark visible as read when popover closes: off

**Appearance**

- Show menu bar badge: on
- Show relative time: on

**Types**

- Table: extension → group
- Reset to defaults

**Danger**

- Mark all as read
- Clear list (does not delete files)

Do not put filter chips in Settings.

---

## 10. Persistence & defaults

UserDefaults / small JSON store:

```
selectedChip: 'today'
selectedType: 'any'
watchedFolders: ['~/Downloads']
retentionDays: 7
maxItems: 50
markReadOnClose: false
typeOverrides: {}
unreadMap: { [id]: { arrivedAt, isUnread } }
```

Search query is **not** persisted.  
Selected chip and type **are** persisted.

---

## 11. Copy (EN, matches current UI language)

| Key | String |
|---|---|
| app_name | Downtray |
| chip_all | All |
| chip_1h | 1h |
| chip_today | Today |
| chip_unread | Unread |
| type_button | Type |
| type_any | Any |
| type_docs | Docs |
| type_images | Images |
| type_media | Media |
| type_archives | Archives |
| type_apps | Apps |
| search_placeholder | Name or type |
| empty_all_title | No recent downloads |
| empty_all_body | New files in Downloads will show up here. |
| empty_1h | Nothing in the last hour |
| empty_today | Nothing today |
| empty_unread | You’re all caught up |
| empty_search | No matches |
| row_just_now | Just now |
| section_just_now | Just now |
| section_earlier_today | Earlier today |
| section_yesterday | Yesterday |
| section_this_week | This week |
| section_earlier | Earlier |
| action_open | Open |
| action_reveal | Show in Finder |
| action_mark_read | Mark as Read |
| action_mark_unread | Mark as Unread |
| action_copy_path | Copy Path |
| action_copy_name | Copy Name |
| action_trash | Move to Trash |
| settings_title | Settings |

Do not localize in this iteration unless the project already has localization.

---

## 12. Interaction details

- Popover width: keep current (~360–400pt). Chips must fit one row at default font; if they don’t, compress chip horizontal padding before wrapping.
- Keyboard: typing focuses search. ↑↓ move rows. Return opens. ⌘R reveal. Esc closes popover.
- Clicking an already selected chip does nothing (no toggle-off). User switches to `All` to clear a time filter.
- Changing chip or type scrolls list to top.
- File that vanishes while popover is open is removed immediately; selection moves to next row.
- Opening Settings does not clear filters.

---

## 13. Implementation notes

- Reuse existing list/search UI. This spec is a **filter + item-lifecycle** change, not a visual redesign.
- Delete any PDF/Images/Other filter enums and mapping UI.
- Centralize type mapping in one function `typeGroup(for url: URL) -> TypeGroup`.
- Centralize visibility in one function `matches(item, chip, type, query, now) -> Bool` so tests are easy.
- Unit test the matrix below.

Suggested test cases:

1. `.pdf` → docs  
2. `.PNG` → images  
3. `.dmg` → apps  
4. `.crdownload` ignored; after rename to `a.pdf`, item appears unread  
5. chip `1h` hides item arrivedAt = 61 min  
6. chip `today` includes 00:01 local, excludes yesterday 23:59  
7. unread stays true until Open / Reveal  
8. search `pdf` matches `Invoice.PDF`  
9. Type=Images AND chip=Today AND search blank → only today’s images  
10. deleted file disappears from store  

---

## 14. Acceptance

Done when:

- [ ] Old chips PDF / Images / Other are gone
- [ ] Chips are All / 1h / Today / Unread, single-select
- [ ] Type is a separate menu with Any + 5 groups
- [ ] Search placeholder is `Name or type` and matches name + extension
- [ ] Default chip is Today if possible
- [ ] Temp browser files never appear
- [ ] Rename from temp → final file shows up as unread
- [ ] Badge = unread count
- [ ] Open / Show in Finder marks read
- [ ] Opening the popover alone does not mark read
- [ ] List groups by recency only for All / Today
- [ ] Settings can change watched folder and retention
- [ ] Popover still one compact menu-bar panel

Out of scope for this change:

- Browser extension / capturing in-flight HTTP downloads
- Source-app filter chip
- User-pinned “PDF” chip
- Multi-select chips
---
