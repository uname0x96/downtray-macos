# Downtray — History UI spec

Hand this to an implementer. It replaces the current History panel.
History is **Pro only**. Free users never see this surface (they see the paywall sheet instead).

Inbox and History are different jobs:

- Inbox = act on files that just arrived.
- History = look up what arrived earlier, including files that have since moved or been deleted.

Do not clone the inbox chrome into History.

## Surfaces

History is the same popover width (~360 pt), not a standalone window.

Entry (Pro only):

- Gear → **History…**
- Last-row hint on the inbox, if present: **Show older files**

Exit:

- Leading control **Inbox** (or a back chevron + “Inbox”)
- Trailing **Done** also returns to the inbox

No gear on the History panel. Settings stay on the inbox gear.

## Layout (top → bottom)

```
[ ‹ Inbox              History              Done ]
[ 🔍 Search history                              ]
[ All ] [ Available ] [ Gone ]

  Today
  [ rows ]

  Yesterday
  [ rows ]

  Last week
  [ rows ]
```

No inbox filter chips (Today / PDF / Images / Other).
No footer.
No “Open Downloads in Finder”.
No “Mark all seen”.

## Scope of the list

- Files only. Hide directories (`ui-shots`, `i18n-shots`, and any other folder).
- Default cap: 200 most recent file events, or 30 days, whichever the IAP spec already says. If unspecified: 200 files.
- Newest first, grouped by local calendar day.

Section headers (use Foundation relative/date formatting, localized):

- Today
- Yesterday
- weekday name if within the last 6 days
- otherwise a medium date (`Sep 18, 2026` in EN)

Empty section headers are omitted.

## Segmented filter

Single-select, three segments, one row:

| Segment | Shows |
|---|---|
| All | available + gone |
| Available | file still exists at the last known path (or was found by bookmark) |
| Gone | moved, renamed away, or deleted |

This is not the inbox type filter. Do not bring PDF / Images back.

## Search

Placeholder: `Search history` (localized).

Filters by filename. Case-insensitive. Applies on top of the All / Available / Gone segment.

Empty query + empty history: `Nothing in history yet.`
Query with no hits: `No matches.`

Do not reuse the inbox empty copy (“Nothing new…”).

## Two row types

### Available

Same visual language as an inbox row, except:

- No unread dot. History does not participate in the badge.
- Meta line: `relative time · size · kind` (kind rules from the popover spec: never show “File”, fall back to uppercase extension).
- Primary click = Open.
- `…` / shortcuts: Open, Quick Look, Reveal, Copy path, Move, Unzip (zip only), Trash.
- If Open/Reveal fails because the file vanished between render and click, convert the row to Gone in place.

### Gone (`moved or deleted`)

Visually secondary. Must not look like a broken inbox row.

- No large blank document thumbnail.
- 16–20 pt symbol: `questionmark.folder` or `trash` (SF Symbol, tertiary label color).
- Filename in secondary/tertiary label color, 1 line, truncate middle.
- Meta: `relative time · Moved or deleted` (localized). Do not show a stale size/kind as if the file were still there.
- Entire row is non-openable.
- Single action: **Remove from history**. Available via click, `⌫`, or `…`.
- No Quick Look, Reveal, Open, Move, Unzip on Gone rows.

Gone rows are slightly shorter than Available rows (~44 pt vs ~56 pt) so the list does not look like a stack of dead tiles.

## Footer

There is no footer on History.

Do not add “Clear history” in v1. Removing one Gone row is enough.

## State after leaving History

Returning to Inbox does not mark files seen.
Unread dots and the menu-bar badge are unchanged.

## Pro gating (do not regress)

- Free + tap History in the gear: show the Pro sheet, do not push the History panel.
- Gear must not show a greyed-out History item that does nothing useful. Either omit it for free users or have it open the Pro sheet labeled **Downtray Pro…**.
- After purchase, the same control opens History.

## Out of scope

- Re-adding type chips
- Showing folders
- Restoring a gone file
- Syncing history across Macs
- Search-by-source / search-by-kind
- A separate History window
- Unread dots in History

## Acceptance

Done when:

- History has back + title + Done, search, and All / Available / Gone only.
- Inbox footer and inbox type chips are gone from History.
- Folders do not appear.
- Available rows open files; Gone rows cannot open and only remove themselves from the list.
- Gone rows have no empty white document icon.
- Day section headers exist and empty ones do not.
- Search empty states are History-specific.
- Free users cannot open this panel.
