# Downtray — Localization Spec (v1)

Hand this file to an implementer. It is the source of truth for languages.
Product: **Downtray**, a macOS 14+ menu bar inbox for newly arrived files.
Bundle ID: `app.downtray.mac` (if already created under another ID, do not change it).

## Goal

Ship v1 with a fully internationalized UI and four locales.
Do not add more languages until App Store Connect analytics show demand.

English is the development language and the fallback.

## Locales

### Ship in v1 (required)

| Locale | Xcode / `.lproj` | App Store Connect | Notes |
|---|---|---|---|
| English (United States) | `en` | English (U.S.) | Source of truth. All strings authored here first. |
| Japanese | `ja` | Japanese | Highest-value non-English Mac market. Native review required. |
| German | `de` | German | Verbose — leave UI room. Native review required. |
| French | `fr` | French | Covers France + fallback for fr-CA. |

Do **not** create separate `en-GB`, `en-AU`, `en-CA`, or `fr-CA` in v1.
One `en` and one `fr` is enough.

### Explicitly out of v1

Do not add these unless a later spec says so:

- Vietnamese (`vi`)
- Korean (`ko`)
- Spanish (`es`)
- Simplified Chinese (`zh-Hans`) — mainland listing also has ICP implications
- Traditional Chinese (`zh-Hant`)
- Italian, Portuguese, Dutch, Russian, Arabic, Thai, Hindi, or any other locale

## What must be localized

1. Every user-visible string in the app: popover, settings, empty states, permission CTAs, toasts, menus, IAP copy, error text.
2. App Store Connect metadata: subtitle, promotional text, description, keywords. **Not** the app name.
3. Accessibility labels / `help` tooltips if present.
4. Plural-aware strings (`%lld files`, “1 file” vs “2 files”).

## What must NOT be translated

- Brand name **Downtray** — keep Latin script in every locale, including Japanese and German listings.
- Bundle ID, URL scheme, entitlement names.
- File-system names the user already has (`Downloads`, `Desktop`) when shown as folder names from the system. The *label* “Watch Downloads” is localized; the folder name itself is not rewritten.
- File extensions (`.pdf`, `.dmg`, `.zip`).
- Keyboard shortcut glyphs (`⌘R`, `⌫`, `⌃⌥D`). Localize the action name, not the chord.
- Default hotkey. It stays `⌃⌥D` in every locale.
- Log / debug strings.

## Technical requirements

- Use a single Xcode **String Catalog** (`Localizable.xcstrings`). No leftover `.strings` files.
- Every UI string goes through `String(localized:)` / `LocalizedStringResource` / SwiftUI `Text("…")` with a catalog key. No raw user-facing literals in code after this work.
- Keys: stable, English, dotted. Example: `inbox.empty.title`, `action.reveal`, `settings.launchAtLogin`.
- Add a translator comment on every key that is not obvious (where it appears, character limit, what a placeholder is).
- Plurals: use catalog plural variants (`one` / `other`; Japanese still needs `other` only). Never concatenate `"file" + count`.
- Dates, relative time, and file sizes: **only** Foundation formatters.

```swift
file.dateAdded.formatted(.relative(presentation: .named))
file.size.formatted(.byteCount(style: .file))
```

Do not hand-write “2 hours ago” or “1.2 MB”.
- Locale follows the **app** language (System Settings → Apps → Downtray), then system language. Do not invent a language picker in v1.
- Layout: German strings run 20–40% longer. No fixed-width labels that clip. Filter chips may wrap one line; they must not truncate mid-word.
- RTL is out of scope (no Arabic/Hebrew in v1). Assume LTR.
- No network calls for translation. No runtime download of language packs.

## App Store listing (per locale)

Name in every storefront: `Downtray` (do not localize).

English (U.S.) source:

| Field | Max | Copy |
|---|---|---|
| Name | 30 | Downtray |
| Subtitle | 30 | Inbox for new downloads |
| Keywords | 100 | files, organize, AirDrop, finder, pdf, unzip, desktop, tray |

Translate subtitle, description, and keywords into `ja`, `de`, `fr`.
Keywords must be comma-separated, no spaces after commas if that is the project convention — match App Store Connect: comma-separated, no duplicate of words already in name/subtitle.

Do not put “Downtray” in keywords.
Do not use English keywords in the Japanese/German/French keyword fields; use native search terms for “downloads”, “files”, “menu bar”, “organize”.

Screenshots in v1 may stay English. Optional: caption overlay translated for JP/DE/FR. Not a blocker.

## Tone

- Short, plain, native. Not marketing-speak.
- Address the user as “you” in EN/DE/FR. Japanese: polite です/ます, not casual だ/である, not keigo-heavy.
- Buttons stay verbs: Open, Move, Trash, Unzip — not sentences.
- Errors say what happened and what to do. “Downtray doesn’t have access to Downloads. Grant access to continue.”

## Suggested first keys (minimum set)

Implementers should extract from the real UI rather than invent a parallel vocabulary. This list is the expected surface, not an exhaustive catalog.

- `app.name` = Downtray (untranslated)
- `inbox.title`
- `inbox.empty.title` / `inbox.empty.body`
- `inbox.permission.title` / `inbox.permission.button`
- `inbox.footer.openDownloads` / `inbox.footer.markAllSeen`
- `filter.all` `filter.today` `filter.pdf` `filter.images` `filter.archives` `filter.installers`
- `action.open` `action.quickLook` `action.reveal` `action.copyPath` `action.move` `action.unzip` `action.trash`
- `row.unread` (accessibility)
- `settings.folders` `settings.watchDownloads` `settings.watchDesktop` `settings.launchAtLogin` `settings.hotkey` `settings.notifications` `settings.pro`
- `pro.unlock.title` `pro.unlock.body` `pro.unlock.button`
- `toast.undone` `toast.trashed`

If a string is missing from this list but visible in the UI, it still must be in the catalog.

## Translation process

1. Freeze English source in the catalog.
2. Machine-translate `ja` / `de` / `fr` into the same catalog.
3. A native speaker (or a human review pass) must edit JP and DE before ship. FR can ship machine+spot-check if time is tight; JP and DE cannot.
4. Pseudo-localize once (`Åççéñţéð` or Xcode’s accented pseudolocale) and click every screen to find clipping.
5. Run the app under each of the four languages via Scheme → Options → App Language.

## Acceptance

v1 localization is done when:

- Switching system/app language to EN, JA, DE, or FR changes every visible string except “Downtray”.
- No English leftovers in JA/DE/FR except the brand name, extensions, and shortcut glyphs.
- Relative dates and file sizes follow the active locale.
- German popover at default width (360 pt) does not clip filter chips or row actions.
- App Store Connect has subtitle + description + keywords filled for EN, JA, DE, FR.
- Building with a missing translation falls back to English, not a raw key.

## Do not do

- Do not add a language settings page.
- Do not localize SF Symbols names.
- Do not ship 10 locales “to look international.”
- Do not translate the brand.
- Do not hardcode locale with `Locale(identifier: "en")` except in tests.
