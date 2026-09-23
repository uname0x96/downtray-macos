# Downtray — Popover UI update spec

Hand this to an implementer. It overrides the current popover layout where they conflict.
Product: Downtray. Popover ≈ 360 × 520 pt. Do not widen the panel to “make chips fit.”

Screenshot to match against: menu-bar popover, dark mode, title + gear, filter chips, file rows, footer.

## Problems to fix

The current build is the right product, but:

1. Six filter chips wrap as **5 + 1**. `Installers` sits alone on row 2.
2. A Search field sits on the main inbox (only ~20 files). It steals vertical space.
3. Footer has three actions: Open Downloads / History / Mark all seen. History is a Pro feature and must not look free.
4. Rows have no unread dot. Badge on the menu bar has nothing to point at in the list.
5. Meta line is `time · size · kind · source` and source truncates as `contribution.u…`.
6. Generic UTI shows as “File” for `.md` / `.csv`.

## Layout (top → bottom)

```
[ Downtray                          ⚙ ]
[ All ] [ Today ] [ PDF ] [ Images ] [ Other ]
[ list of rows, scroll ]
[ Open Downloads in Finder     Mark all seen ]
```

No search field on this surface.
No History link in the footer.
No sixth chip.

## Filters

Single-select chips. Exactly **five**, one row, no wrap.

| Chip | Matches |
|---|---|
| All | everything in the inbox window |
| Today | date-added is today (local calendar) |
| PDF | `.pdf` |
| Images | common images (`png jpg jpeg webp heic gif tiff`) |
| Other | everything else: archives, installers, docs, csv, md, zip, dmg, … |

Drop the visible **Archives** and **Installers** chips. Those files still appear under All / Today / Other. Do not delete unzip-for-zip or installer detection in the row kind — only the chips go away.

Chip sizing: hug content, equal vertical padding, wrap **forbidden**. If a translated label overflows in German, shorten the label (`Andere`, not a second row).

Selected chip: filled accent. Unselected: secondary fill. Hit target ≥ 28 pt tall.

## Search

- **Inbox (free list of 20):** no search field.
- **History (Pro):** search field is allowed at the top of the History surface only.

Do not leave a hidden/collapsed search on the inbox. Remove it.

## Footer (free popover)

Exactly two items, one row:

| Side | Label | Action |
|---|---|---|
| Leading | Open Downloads in Finder | Reveal `~/Downloads` in Finder |
| Trailing | Mark all seen | Clear unread dots + menu-bar badge |

Use `Text` buttons, not competing filled buttons. Secondary tint. History is not here.

## History (Pro only)

History is **not** part of the free popover chrome.

Free user:

- List stops at the latest 20 files that still exist.
- No “History” button in the footer.
- Optional last-row hint, only if the user has more than 20 files in watched folders:  
  `Show older files` → opens the Pro paywall sheet.  
  One sentence: “History, extra folders, and rules. Pay once.”  
  Primary button unlocks Pro. Secondary dismisses.  
  If they already own Pro, the hint is not a paywall — it opens History.

Pro user:

- Gear menu contains **History**, or the last-row hint opens History directly.
- History is a separate panel/sheet (same width), not a third footer link.
- History may show the last 200 files or 30 days, whichever is specified in the IAP spec. Default if unspecified: 200 files.
- Search belongs on this panel only.
- Same row component as the inbox (dot is always off in History unless you also track “seen” there — default: no unread dots in History).

Do not gate Open / Quick Look / Trash / Unzip behind Pro.

## Row

Left → right:

1. Unread dot (6 pt, accent color). Hidden when seen. Reserve the column so rows don’t jump when the dot appears.
2. Thumbnail 32 pt (Quick Look / icon services).
3. Text stack:
   - Line 1: filename, 1 line, truncate **middle**.
   - Line 2: `relative time · size · kind` only.

Kind rules:

- Prefer a short system kind (`PDF`, `Disk Image`, `ZIP archive`).
- If the kind is the generic “Document” / “File” / “Unix executable”, show the **uppercase extension** instead (`MD`, `CSV`, `DMG`).
- Never show “File” as the visible kind.

Source (`kMDItemWhereFroms` host, AirDrop):

- Not on line 2.
- Show as tooltip on the row, or on hover in the `…` menu as a caption.
- If unknown, omit. Do not show `…` leftovers.

Relative time and size: Foundation formatters (see i18n spec). Do not invent “2 hours ago”.

Unread definition (unchanged product rule):

- New file in a watched folder → unread.
- Opening the popover does **not** mark seen by itself.
- Seen when the user: Open, Quick Look, Reveal, Move, Unzip, Trash, or Mark all seen.
- Menu bar badge = count of unread, cap `9+`.

Primary click still Opens. Hover/`…` actions unchanged from the main spec (Open, Quick Look, Reveal, Copy path, Move, Unzip zip, Trash).

## Gear

Keep the gear top-trailing.

Menu / settings still includes folders, login item, hotkey, notifications, Pro.

Add one item for Pro owners: **History…**

Free users see **Downtray Pro…** (or the existing unlock row) instead of a dead History item. Do not show a locked History item that only exists to tease.

## Empty / permission states

Unchanged. Do not add a search field to empty states.

## Out of scope

- Wider popover
- Sidebar
- Two-line chip wrap “by design”
- Color-coded file-type icons instead of real thumbnails
- In-inbox search
- Localizing the brand name
- New filters beyond the five above

## Acceptance

Done when:

- Five chips sit on one row in EN, JA, DE, FR at 360 pt.
- Inbox has no search field.
- Footer has exactly Open Downloads + Mark all seen.
- History is unreachable from the free footer.
- Free user tapping “Show older files” (if shown) gets the Pro sheet, not an empty History.
- Every unread file has a dot; Mark all seen clears dots and badge.
- No row displays the kind “File”.
- Source is not in the subtitle line.
- Popover width is still ~360 pt.
