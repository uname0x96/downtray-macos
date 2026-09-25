# Shipping to the Mac App Store

What the repository already provides, what still happens in App Store Connect, and the text
to paste there. Everything below the checklist is a draft to edit, not a decision.

## Build and upload

```sh
cd macOS
xcodegen generate
xcodebuild -project Downtray.xcodeproj -scheme Downtray -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath ../.build/DerivedData \
  -archivePath ../.build/Downtray.xcarchive CODE_SIGN_STYLE=Automatic archive
xcodebuild -exportArchive -archivePath ../.build/Downtray.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath ../.build/export -allowProvisioningUpdates
```

`-allowProvisioningUpdates` lets Xcode create the "3rd Party Mac Developer Installer"
certificate and the Mac App Store provisioning profile on first use (it did on this machine).
The result is `.build/export/Downtray.pkg`, signed for App Store Connect. Upload it with
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
- [x] StoreKit 2 for the non-consumable `app.downtray.mac.pro`, with a local
      `Pro.storekit` for testing from the Xcode scheme.
- [x] Release archive and App Store export succeed with automatic signing.

Only possible in App Store Connect (account owner):

- [ ] Accept the Paid Apps Agreement and fill in banking and tax forms. Without this the
      in-app purchase never leaves "Missing Metadata" and the app cannot be sold.
- [ ] Create the app record: name "Downtray", bundle id `app.downtray.mac`,
      primary category Productivity, SKU of your choice.
- [ ] Create the in-app purchase: Non-Consumable, product id `app.downtray.mac.pro`,
      reference name "Pro", price tier for $7.99, display name "Downtray Pro",
      description from `Pro.storekit`, a 1024×1024 promotional image is optional. Attach it
      to the first version under "In-App Purchases and Subscriptions" so it is reviewed with
      the app.
- [ ] Add a Sandbox tester account (Users and Access > Sandbox) and buy Pro once on a
      TestFlight or development build signed for the store, to confirm the store path outside
      the local `.storekit` file.
- [x] Privacy policy URL (required because of the in-app purchase), support URL and
      marketing URL. The site is live at https://uname0x96.github.io/downtray/ (GitHub Pages
      from the `uname0x96/downtray` repository): use `/privacy.html`, `/support.html` and the
      root. The pages still carry the `SUPPORT_EMAIL` and `APP_STORE_URL` placeholders; fill
      them in before submitting.
- [ ] App privacy questionnaire: "Data not collected".
- [ ] Screenshots: at least one 1280×800 or 1440×900 (or the 2560×1600 / 2880×1800 Retina
      sizes) of the popover with a few files, one of Settings, one of the rule editor.
- [ ] Age rating: none of the content flags apply (4+).
- [ ] Export compliance: the app uses no encryption beyond what macOS provides; answer "No"
      to the custom encryption question.

Still worth doing before submitting:

- [ ] Run the Release build on a second Mac or a fresh user account: first-launch Downloads
      prompt, moving the primary folder with Change…, login item approval, notification
      permission, a purchase with a
      Sandbox tester.
- [ ] Look at the Pro screens (Settings > Rules, the rule editor sheet, and the Pro sheet in
      the popover) and adjust spacing and copy. The History panel was reworked per
      `specs/history-spec.md` and checked in four languages.
- [x] Localization: `Localizable.xcstrings` carries English, Japanese, German and French for
      every UI string; `scripts/check-strings.sh` keeps code and catalog in step. The Japanese
      and German texts were machine-drafted and need a native speaker's pass before the first
      submission (French can ship with a spot check, per `specs/i18n-spec.md`).
- [ ] Add the Japanese, German and French listings below in App Store Connect (subtitle,
      promotional text, description, keywords, What's New). The name stays "Downtray" in every
      storefront.
- [ ] Replace the placeholder copyright holder ("Downtray") with the legal name.

## Review notes (paste into "Notes" for App Review)

> Downtray is a menu bar utility (it has no Dock icon). After launch, press
> Control-Option-D or click the tray icon in the menu bar to open the inbox. The first time,
> macOS asks for access to the Downloads folder; please allow it, then drop any file into
> ~/Downloads and it appears at the top of the list.
>
> The gear button opens Settings. The Pro in-app purchase ("Downtray Pro",
> non-consumable) is on the Settings window and on a sheet inside the popover; it unlocks
> extra watched folders, a longer list, a searchable history, and rules. Rules act only on files that land in folders the user
> chose to watch, with actions the user configured (move to a folder the user picked, move to
> Trash with undo, mark as seen, or ask first). The app has no network access and collects no
> data.

## App Store description (draft)

One listing per language: English (U.S.) is the source; Japanese, German and French follow.
Keywords are comma-separated without spaces, never repeat the name or the subtitle, and never
contain "Downtray".

### English (U.S.)

**Subtitle** (30 chars): Inbox for new downloads

**Promotional text**: Press ⌃⌥D and act on what just landed in Downloads: open, Quick Look,
move, unzip or trash it, without leaving what you were doing.

**Description**

Downtray puts the files that just arrived in your Downloads folder one keystroke away.
Press ⌃⌥D and the newest files are there, newest first, with a Quick Look thumbnail and where
they came from.

Act on a file with one key: Return opens it, Space previews it, ⌘R reveals it in Finder, ⌘C
copies its path, ⌘M moves it to a folder, ⌘U unzips it in place, and ⌫ moves it to the Trash
with a five-second undo, or drag it straight out of the list into any app. Narrow the list to the last hour, today, or what you have not
opened yet, pick a type (Docs, Images, Media, Archives, Apps), or search by name or type. A
badge on the menu bar icon counts the files you have not opened, and an optional
notification tells you the moment a download finishes.

Downtray Pro (one-time purchase) adds:
• Extra folders: watch your Desktop, a scanner folder, an AirDrop target, anything.
• A longer list, 200 files.
• History: every file that ever landed, even after you moved it, with search.
• Rules: sort arrivals automatically. Receipts from a shop into Receipts, installers
  straight to the Trash once opened, or just ask first.

Private by design: no account, no network, no analytics. Everything stays on your Mac, inside
the App Sandbox.

**Keywords** (100 chars): files,organize,AirDrop,finder,pdf,unzip,desktop,tray,menu bar,history

**What's New (1.0.0)**: First release.

### Japanese

**Subtitle**: 新しいダウンロードの受信箱

**Promotional text**: ⌃⌥D を押すだけで、ダウンロードに届いたばかりのファイルをその場で処理できます。開く、クイックルック、移動、解凍、ゴミ箱へ。作業を中断せずに。

**Description**

Downtray は、ダウンロードフォルダに届いたばかりのファイルをキー 1 つで手元に呼び出します。⌃⌥D を押すと、新しい順に並んだファイルが、クイックルックのサムネイルと入手元とともに表示されます。

キー 1 つでファイルを操作できます。Return で開く、Space でプレビュー、⌘R で Finder に表示、⌘C でパスをコピー、⌘M でフォルダへ移動、⌘U でその場に解凍、⌫ でゴミ箱へ (5 秒間は取り消し可能)。「1時間」「今日」「未読」で絞り込み、種類 (書類、画像、メディア、アーカイブ、アプリ) を選び、名前や種類で検索できます。まだ開いていないファイルの数はメニューバーアイコンのバッジに表示され、必要ならダウンロード完了時に通知も受け取れます。

Downtray Pro (買い切り) で追加されるもの:
• 追加のフォルダ: デスクトップ、スキャナの保存先、AirDrop の保存先など、どのフォルダでも監視できます。
• 長いリスト (200 件)。
• 履歴: 移動したあとも、届いたファイルをすべて記録し、検索できます。
• ルール: 新着を自動で整理します。ショップの領収書は「領収書」フォルダへ、開いたインストーラはそのままゴミ箱へ、または先に確認するだけ。

プライバシー第一の設計: アカウント不要、ネットワーク接続なし、分析なし。すべては App Sandbox の中の、あなたの Mac に留まります。

**Keywords**: ファイル,整理,AirDrop,Finder,PDF,解凍,デスクトップ,メニューバー,zip,履歴

**What's New (1.0.0)**: 初回リリース。

### German

**Subtitle**: Eingang für neue Downloads

**Promotional text**: Drücke ⌃⌥D und erledige, was gerade in Downloads gelandet ist: öffnen, Übersicht, bewegen, entpacken oder in den Papierkorb, ohne deine Arbeit zu unterbrechen.

**Description**

Downtray bringt die Dateien, die gerade in deinem Downloads-Ordner gelandet sind, mit einem Tastendruck zu dir. Drücke ⌃⌥D und die neuesten Dateien sind da, die jüngste zuoberst, mit Übersicht-Vorschau und Herkunft.

Erledige eine Datei mit einer Taste: Zeilenschalter öffnet sie, Leertaste zeigt die Vorschau, ⌘R zeigt sie im Finder, ⌘C kopiert ihren Pfad, ⌘M bewegt sie in einen Ordner, ⌘U entpackt sie an Ort und Stelle und ⌫ legt sie in den Papierkorb, mit fünf Sekunden zum Widerrufen. Zeige nur die letzte Stunde, nur heute oder nur Ungelesenes, wähle einen Typ (Dokumente, Bilder, Medien, Archive, Apps) oder suche nach Name oder Typ. Ein Badge am Menüleistensymbol zählt die Dateien, die du noch nicht geöffnet hast, und auf Wunsch meldet eine Mitteilung den Moment, in dem ein Download fertig ist.

Downtray Pro (einmaliger Kauf) ergänzt:
• Weitere Ordner: überwache deinen Schreibtisch, einen Scanner-Ordner, ein AirDrop-Ziel, was du willst.
• Eine längere Liste, 200 Dateien.
• Verlauf: jede Datei, die je angekommen ist, auch nachdem du sie bewegt hast, mit Suche.
• Regeln: neue Dateien automatisch sortieren. Belege eines Shops nach „Belege“, Installer nach dem Öffnen direkt in den Papierkorb, oder einfach erst nachfragen.

Privat von Grund auf: kein Account, kein Netzwerk, keine Analyse. Alles bleibt auf deinem Mac, in der App-Sandbox.

**Keywords**: Dateien,ordnen,AirDrop,Finder,PDF,entpacken,Schreibtisch,Menüleiste,zip,Verlauf

**What's New (1.0.0)**: Erste Version.

### French

**Subtitle**: Vos nouveaux téléchargements

**Promotional text**: Appuyez sur ⌃⌥D et agissez sur ce qui vient d’arriver dans Téléchargements : ouvrir, Coup d’œil, déplacer, décompresser ou jeter, sans quitter votre travail.

**Description**

Downtray met les fichiers qui viennent d’arriver dans votre dossier Téléchargements à une touche de vous. Appuyez sur ⌃⌥D et les fichiers les plus récents sont là, du plus récent au plus ancien, avec une vignette Coup d’œil et leur provenance.

Agissez sur un fichier avec une seule touche : Retour l’ouvre, Espace l’affiche en aperçu, ⌘R l’affiche dans le Finder, ⌘C copie son chemin, ⌘M le déplace vers un dossier, ⌘U le décompresse sur place et ⌫ le place dans la corbeille, avec cinq secondes pour annuler. Limitez la liste à la dernière heure, à aujourd’hui ou aux fichiers non lus, choisissez un type (Documents, Images, Médias, Archives, Apps) ou cherchez par nom ou par type. Un badge sur l’icône de la barre des menus compte les fichiers que vous n’avez pas encore ouverts, et une notification facultative vous prévient dès qu’un téléchargement se termine.

Downtray Pro (achat unique) ajoute :
• D’autres dossiers : surveillez votre Bureau, un dossier de scanner, une cible AirDrop, ce que vous voulez.
• Une liste plus longue, 200 fichiers.
• L’historique : chaque fichier jamais arrivé, même après l’avoir déplacé, avec recherche.
• Les règles : triez automatiquement les nouveaux fichiers. Les reçus d’une boutique vers « Reçus », les installateurs directement à la corbeille une fois ouverts, ou simplement demander d’abord.

Privé par conception : pas de compte, pas de réseau, pas d’analyse. Tout reste sur votre Mac, dans le bac à sable de l’app.

**Keywords**: fichiers,ranger,AirDrop,Finder,PDF,décompresser,bureau,barre des menus,zip,historique

**What's New (1.0.0)**: Première version.

## Privacy policy (draft; the live text is `privacy.html` on the website)

> Downtray does not collect, store or transmit any personal data. The app runs entirely
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
