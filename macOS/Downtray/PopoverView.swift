import AppKit
import SwiftUI
import InboxCore

/// The panel (~360 × 520 pt): header, the filter row (chips and the Type menu), the list of
/// recent files, and a footer. The view only sends events; focus, selection, toast and undo all
/// come from the model.
struct PopoverView: View {
    @Environment(InboxPresenter.self) private var presenter
    @FocusState private var focused: Bool
    @FocusState private var searchFocused: Bool
    /// What the search field shows; the model's `query` follows it 150 ms after the last key.
    @State private var draft = ""
    @State private var queryDebounce: Task<Void, Never>?
    let openSettings: () -> Void

    private var model: InboxModel { presenter.model }
    private static let searchDebounce: Duration = .milliseconds(150)

    var body: some View {
        VStack(spacing: 0) {
            if model.historyMode {
                // History is another job (look up what arrived earlier), so it gets its own
                // chrome: back + title + Done, search, its own segment, no chips, no footer.
                historyHeader
                searchField
                historySegments
                Divider()
                content
            } else {
                header
                filterRow
                // Pro lists 200 files, which is too many to scan by eye; free stops at 20.
                if model.isPro { searchField }
                Divider()
                content
                Divider()
                footer
            }
        }
        .frame(width: 360, height: 520)
        .overlay(alignment: .bottom) { notices }
        .overlay { if model.paywallShown { PaywallView(presenter: presenter) } }
        .background(hiddenShortcuts)
        .background(SettingsOpener())
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in handle(press) }
        .onAppear { focused = true }
        // The model clears the query when the panel closes or leaves History; follow it.
        .onChange(of: model.query) { _, query in if query != draft { draft = query } }
        .accessibilityIdentifier("popover")
    }

    // MARK: Header

    /// The inbox header: the brand and a gear button that opens Settings.
    private var header: some View {
        HStack(spacing: 10) {
            Text(appName)
                .font(.headline)
            Spacer()
            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "inbox.settings", defaultValue: "Settings", comment: "Tooltip on the gear button that opens Settings."))
            .accessibilityIdentifier("gear")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// `‹ Inbox   History   Done`. Both ends return to the inbox; there is no gear here.
    private var historyHeader: some View {
        ZStack {
            Text(String(localized: "history.title", defaultValue: "History", comment: "Title of the History panel (Pro)."))
                .font(.headline)
            HStack {
                Button {
                    presenter.dispatch(.setHistoryMode(false))
                } label: {
                    Label(String(localized: "history.back", defaultValue: "Inbox", comment: "Back button on the History panel; returns to the inbox."), systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
                .navigationGlass()
                .accessibilityIdentifier("historyBack")
                Spacer()
                Button(String(localized: "history.done", defaultValue: "Done", comment: "Trailing button on the History panel; returns to the inbox.")) {
                    presenter.dispatch(.setHistoryMode(false))
                }
                .navigationGlass()
                .accessibilityIdentifier("historyDone")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// All / Available / Gone: whether the file is still where it was. Not the inbox's chips.
    private var historySegments: some View {
        Picker("", selection: Binding(get: { presenter.model.historyFilter }, set: { presenter.dispatch(.setHistoryFilter($0)) })) {
            ForEach(HistoryFilter.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .accessibilityIdentifier("historyFilter")
    }

    /// All / 1h / Today / Unread on one row, then the Type menu. A chip hugs its label and
    /// never wraps or truncates, so a label that does not fit is shortened in the catalog.
    /// Clicking the selected chip does nothing; a change scrolls the list back to the top.
    private var filterRow: some View {
        HStack(spacing: 6) {
            ForEach(FileFilter.allCases, id: \.self) { filter in
                FilterChip(title: filter.localizedTitle, id: filter.rawValue, selected: model.filter == filter) {
                    if model.filter != filter { presenter.dispatch(.setFilter(filter)) }
                }
            }
            Spacer(minLength: 0)
            typeMenu
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    /// `Type ▾`: Any, then the five groups, with a checkmark on the current one. The button
    /// reads "Type" while Any is selected and the group's name otherwise. Liquid Glass on
    /// macOS 26 and later, like the History buttons; a tinted capsule before that.
    private var typeMenu: some View {
        let selected = model.typeFilter
        let title = selected?.localizedTitle ?? String(localized: "type.menu", defaultValue: "Type", comment: "Label of the type menu button while no type is selected. Keep short.")
        let menu = Menu {
            Picker("", selection: Binding(get: { presenter.model.typeFilter }, set: { presenter.dispatch(.setTypeFilter($0)) })) {
                Text(String(localized: "type.any", defaultValue: "Any", comment: "First item of the Type menu: no type filter.")).tag(TypeGroup?.none)
                Divider()
                ForEach(TypeGroup.menuCases, id: \.self) { Text($0.localizedTitle).tag(TypeGroup?.some($0)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityIdentifier("typeMenu")
        return typeMenuStyle(menu, selected: selected != nil)
    }

    @ViewBuilder
    private func typeMenuStyle(_ menu: some View, selected: Bool) -> some View {
        if #available(macOS 26, *) {
            if selected {
                menu.menuStyle(.button).buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.small)
            } else {
                menu.menuStyle(.button).buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
            }
        } else {
            // The borderless menu style rebuilds its label from text and image, so the chip
            // look (capsule, tint) is applied to the menu itself, not to the label.
            menu.menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .frame(minHeight: 28)
                .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.08)))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .contentShape(Capsule())
        }
    }

    /// Filters the list: on History by name, on the inbox (Pro) by name, extension, type group
    /// or source host. The model gets the text 150 ms after the last key, so a fast typist does
    /// not re-filter 200 rows per character.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(
                model.historyMode
                    ? String(localized: "history.search", defaultValue: "Search history", comment: "Placeholder of the search field on the History panel.")
                    : String(localized: "inbox.search.placeholder", defaultValue: "Name or type", comment: "Placeholder of the search field on the inbox (Pro): it matches file names and type names such as pdf or Images."),
                text: $draft
            )
            .textFieldStyle(.plain)
            .focused($searchFocused)
            .onChange(of: draft) { _, text in scheduleQuery(text) }
            .onSubmit { if model.focused != nil { presenter.dispatch(.open(.selection)) } }
            .onKeyPress(.upArrow) { presenter.dispatch(.moveFocus(.up)); return .handled }
            .onKeyPress(.downArrow) { presenter.dispatch(.moveFocus(.down)); return .handled }
            .onKeyPress(.escape) {
                guard !draft.isEmpty else { return .ignored }
                clearQuery()
                return .handled
            }
            .accessibilityIdentifier("search")
            if !draft.isEmpty {
                Button(action: clearQuery) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "search.clear", defaultValue: "Clear search", comment: "Accessibility label of the × in the search field."))
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func scheduleQuery(_ text: String) {
        queryDebounce?.cancel()
        guard text != model.query else { return }
        queryDebounce = Task { @MainActor in
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled else { return }
            presenter.dispatch(.setQuery(text))
        }
    }

    private func clearQuery() {
        queryDebounce?.cancel()
        draft = ""
        presenter.dispatch(.setQuery(""))
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        if let empty = model.emptyState {
            EmptyStateView(
                state: empty,
                inHistory: model.historyMode,
                folderName: primaryFolderName,
                grant: { presenter.dispatch(.grantAccess(.downloads)) },
                openDownloads: { presenter.dispatch(.openWatchedFolder(.downloads)) }
            )
        } else if model.historyMode {
            historyList
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        Color.clear.frame(height: 0).id(Self.topAnchor)
                        ForEach(inboxItems) { item in
                            switch item {
                            case .header(let title, let id):
                                sectionHeader(title).accessibilityIdentifier(id)
                            case .file(let file):
                                inboxRow(file)
                            }
                        }
                        if model.hasOlderFiles {
                            Button {
                                presenter.dispatch(.showOlderFiles)
                            } label: {
                                HStack {
                                    Spacer()
                                    Text(String(localized: "inbox.olderFiles", defaultValue: "Show older files", comment: "Last row of the inbox when the folders hold more than the list shows. Opens History (Pro) or the Pro sheet."))
                                    Image(systemName: "chevron.right").font(.caption2)
                                    Spacer()
                                }
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("olderFiles")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .onChange(of: model.focused) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
                }
                .onChange(of: model.filter) { _, _ in proxy.scrollTo(Self.topAnchor, anchor: .top) }
                .onChange(of: model.typeFilter) { _, _ in proxy.scrollTo(Self.topAnchor, anchor: .top) }
            }
        }
    }

    private static let topAnchor = "top"

    /// Headers and rows as one flat list for one `ForEach`. Nested `ForEach`es (one per
    /// section) gave a file that moved to another section, say from Just now to Yesterday on
    /// reopening after midnight, a second row with the same id in a new container, and the
    /// `LazyVStack` kept drawing the old one: its unread dot survived Mark all seen. With one
    /// container the row keeps one identity and just moves. 1h, Unread and a search show a
    /// flat list: no headers.
    private var inboxItems: [ListItem] {
        let sections = model.inboxSections
        if sections.isEmpty { return model.visibleFiles.map(ListItem.file) }
        return sections.flatMap { section in
            [.header(section.section.localizedTitle, id: "section-\(section.section.rawValue)")]
                + section.files.map(ListItem.file)
        }
    }

    private var historyItems: [ListItem] {
        historySections.flatMap { section in
            [.header(Self.sectionTitle(for: section.day, today: model.today), id: "day-\(section.day.timeIntervalSince1970)")]
                + section.files.map(ListItem.file)
        }
    }

    enum ListItem: Identifiable {
        case header(String, id: String)
        case file(InboxFile)

        var id: String {
            switch self {
            case .header(_, let id): return id
            case .file(let file): return file.id
            }
        }
    }

    /// No explicit `.id()`: the `ForEach` identifies the row by the file's path, which is what
    /// `scrollTo` uses.
    private func inboxRow(_ file: InboxFile) -> some View {
        FileRowView(
            file: file,
            now: model.now,
            showFolder: model.duplicateNames.contains(file.name),
            selected: model.selection.contains(file.id),
            focused: model.focused == file.id,
            actions: RowActions(presenter: presenter, file: file, selection: model.selection)
        )
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    /// History rows grouped by the local calendar day they arrived, newest first. An Available
    /// row is an inbox row without the dot; a Gone row is smaller and only removes itself.
    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: []) {
                    ForEach(historyItems) { item in
                        switch item {
                        case .header(let title, _):
                            sectionHeader(title)
                        case .file(let file) where file.missing:
                            GoneRowView(file: file, focused: model.focused == file.id) {
                                presenter.dispatch(.removeFromHistory(file.id))
                            }
                        case .file(let file):
                            FileRowView(
                                file: file,
                                now: model.now,
                                showFolder: model.duplicateNames.contains(file.name),
                                showUnread: false,
                                selected: model.selection.contains(file.id),
                                focused: model.focused == file.id,
                                actions: RowActions(presenter: presenter, file: file, selection: model.selection)
                            )
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .onChange(of: model.focused) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    private var historySections: [(day: Date, files: [InboxFile])] {
        let calendar = Calendar.current
        var sections: [(day: Date, files: [InboxFile])] = []
        for file in model.visibleFiles {
            let day = calendar.startOfDay(for: file.addedAt)
            if sections.last?.day == day {
                sections[sections.count - 1].files.append(file)
            } else {
                sections.append((day, [file]))
            }
        }
        return sections
    }

    /// "Today", "Yesterday", the weekday within the last six days, else a medium date. All from
    /// Foundation, so each language gets its own words and date order.
    static func sectionTitle(for day: Date, today: Date) -> String {
        let calendar = Calendar.current
        let daysAgo = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: today)).day ?? 0
        if daysAgo >= 2 && daysAgo <= 6 {
            return day.formatted(.dateTime.weekday(.wide))
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: day)
    }

    // MARK: Footer

    private var primaryFolderName: String {
        model.downloads?.localizedTitle ?? FolderKind.downloads.localizedTitle
    }

    /// Exactly two text buttons: History (Pro; a lock in the free tier, where it opens the Pro
    /// sheet) and Mark all seen.
    private var footer: some View {
        HStack {
            Button {
                presenter.dispatch(model.isPro ? .setHistoryMode(true) : .showOlderFiles)
            } label: {
                Label(String(localized: "inbox.footer.history", defaultValue: "History", comment: "Footer link button, leading: opens the History list (Pro). Shares one line with 'Mark all seen'."),
                      systemImage: model.isPro ? "clock.arrow.circlepath" : "lock.fill")
            }
            .accessibilityIdentifier("historyToggle")
            Spacer()
            Button(String(localized: "inbox.footer.markAllSeen", defaultValue: "Mark all seen", comment: "Footer button: clears the unread dots and the badge.")) { presenter.dispatch(.markAllSeen) }
                .disabled(model.unreadCount == 0)
        }
        .buttonStyle(.link)
        .foregroundStyle(.secondary)
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Toast and undo

    @ViewBuilder
    private var notices: some View {
        if let suggestion = model.suggestion {
            NoticeView(
                message: suggestion.localizedMessage,
                isError: false,
                action: (String(localized: "notice.yes", defaultValue: "Yes", comment: "Button that confirms a rule's suggestion."), { presenter.dispatch(.acceptSuggestion) }),
                dismiss: { presenter.dispatch(.dismissSuggestion) }
            )
            .accessibilityIdentifier("suggestion")
        } else if let undo = model.undo {
            NoticeView(
                message: undo.files.count == 1
                    ? String(localized: "undo.trashedOne", defaultValue: "Moved \(undo.files[0].name) to Trash", comment: "Notice with an Undo button. Placeholder: file name.")
                    : String(localized: "undo.trashedMany", defaultValue: "Moved \(undo.files.count) files to Trash", comment: "Notice with an Undo button. Placeholder: number of files."),
                isError: false,
                action: undo.ready ? (String(localized: "notice.undo", defaultValue: "Undo", comment: "Button that puts trashed files back."), { presenter.dispatch(.undoTrash) }) : nil
            )
            .accessibilityIdentifier("undoToast")
        } else if let toast = model.toast {
            NoticeView(message: toast.text.localized, isError: toast.isError, action: nil)
                .onTapGesture { presenter.dispatch(.dismissToast) }
                .accessibilityIdentifier("toast")
        }
    }

    // MARK: Keyboard

    /// Return, Space, arrows and ⌫ act on the focused/selected rows; typing a character starts a
    /// search (Pro). ⌘R/⌘C/⌘M/⌘U are declared as hidden buttons so they also show up in the
    /// menu bar's key equivalents.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) { return .ignored }
        switch press.key {
        case .return: presenter.dispatch(.open(.selection)); return .handled
        case .space: presenter.dispatch(.quickLook(.selection)); return .handled
        case .upArrow: presenter.dispatch(.moveFocus(.up)); return .handled
        case .downArrow: presenter.dispatch(.moveFocus(.down)); return .handled
        case .delete, .deleteForward:
            // On a Gone history row ⌫ is "Remove from history"; there is nothing to trash.
            if model.historyMode, let focused = model.focused, model.file(focused)?.missing == true {
                presenter.dispatch(.removeFromHistory(focused))
            } else {
                presenter.dispatch(.trash(.selection))
            }
            return .handled
        case .escape:
            if model.paywallShown {
                presenter.dispatch(.dismissPaywall)
                return .handled
            }
            if model.selection.isEmpty { return .ignored }
            presenter.dispatch(.clearSelection)
            return .handled
        default:
            return startSearch(with: press) ? .handled : .ignored
        }
    }

    /// A letter or digit typed over the list goes into the search field, which takes focus.
    /// The text is added after the focus change, since a field that becomes first responder
    /// selects its contents and the next character would replace them.
    private func startSearch(with press: KeyPress) -> Bool {
        guard model.isPro || model.historyMode, !searchFocused, !model.paywallShown else { return false }
        let text = press.characters
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              press.key.character.isLetter || press.key.character.isNumber || press.key.character.isPunctuation else { return false }
        searchFocused = true
        DispatchQueue.main.async { draft += text }
        return true
    }

    private var hiddenShortcuts: some View {
        Group {
            Button(String(localized: "action.showInFinder", defaultValue: "Show in Finder", comment: "Menu item and ⌘R: selects the file in a Finder window.")) { presenter.dispatch(.reveal(.selection)) }.keyboardShortcut("r", modifiers: .command)
            Button(String(localized: "action.copyPath", defaultValue: "Copy Path", comment: "Menu item and ⌘C: puts the file's path on the clipboard.")) { presenter.dispatch(.copyPath(.selection)) }.keyboardShortcut("c", modifiers: .command)
            Button(String(localized: "action.copyName", defaultValue: "Copy Name", comment: "Menu item and ⇧⌘C: puts the file's name on the clipboard.")) { presenter.dispatch(.copyName(.selection)) }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button(String(localized: "action.move", defaultValue: "Move to…", comment: "Menu item and ⌘M: opens a folder picker.")) { presenter.dispatch(.moveTo(.selection)) }.keyboardShortcut("m", modifiers: .command)
            Button(String(localized: "action.unzip", defaultValue: "Unzip Here", comment: "Menu item and ⌘U: extracts a zip next to itself.")) { presenter.dispatch(.unzip(.selection)) }.keyboardShortcut("u", modifiers: .command)
            Button(String(localized: "action.selectAll", defaultValue: "Select All", comment: "⌘A.")) { selectAll() }.keyboardShortcut("a", modifiers: .command)
            Button(String(localized: "app.quit", defaultValue: "Quit Downtray", comment: "Menu item and ⌘Q. Keep the brand name as is.")) { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func selectAll() {
        guard let first = model.visibleIDs.first, let last = model.visibleIDs.last else { return }
        presenter.dispatch(.select(first, .replace))
        presenter.dispatch(.select(last, .range))
    }
}

// MARK: - Settings

/// Captures SwiftUI's `openSettings` action (macOS 14+, the only public way to open the
/// `Settings` scene) so AppKit code and the debug bridge can call it.
struct SettingsOpener: View {
    @Environment(\.openSettings) private var openSettings
    @MainActor static var action: (() -> Void)?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { Self.action = { openSettings() } }
    }
}

// MARK: - Row

/// The events one row can send. Actions apply to the whole selection when the row is part of it.
@MainActor
struct RowActions {
    let presenter: InboxPresenter
    let file: InboxFile
    let selection: Set<FileID>

    private var target: Target {
        selection.contains(file.id) && selection.count > 1 ? .selection : .files([file.id])
    }

    func click() {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if file.missing {
            return
        } else if flags.contains(.command) {
            presenter.dispatch(.select(file.id, .toggle))
        } else if flags.contains(.shift) {
            presenter.dispatch(.select(file.id, .range))
        } else {
            // Primary click = Open, as the spec asks; the row is also focused and selected.
            presenter.dispatch(.select(file.id, .replace))
            presenter.dispatch(.open(.files([file.id])))
        }
    }

    func open() { presenter.dispatch(.open(target)) }
    func quickLook() { presenter.dispatch(.quickLook(target)) }
    func reveal() { presenter.dispatch(.reveal(target)) }
    func copyPath() { presenter.dispatch(.copyPath(target)) }
    func copyName() { presenter.dispatch(.copyName(target)) }
    func markRead() { presenter.dispatch(.markRead(target)) }
    func markUnread() { presenter.dispatch(.markUnread(target)) }
    /// A drag carries this one file (a drag item has one provider), so only it is marked read.
    func dragStarted() { if file.unread { presenter.dispatch(.markRead(.files([file.id]))) } }
    func moveTo() { presenter.dispatch(.moveTo(target)) }
    func unzip() { presenter.dispatch(.unzip(target)) }
    func trash() { presenter.dispatch(.trash(target)) }
    func dismiss() { presenter.dispatch(.dismiss(file.id)) }
}

struct FileRowView: View {
    let file: InboxFile
    /// The moment the panel opened. The meta line's relative time is formatted from the clock,
    /// so this is here only to make the row render again on reopen instead of keeping "now".
    let now: Date
    let showFolder: Bool
    /// History shows no dots; the column stays so both lists share one row shape.
    var showUnread = true
    let selected: Bool
    let focused: Bool
    let actions: RowActions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            // The dot keeps its column when hidden, so rows do not shift as files are seen.
            let dot = showUnread && file.unread && !file.missing
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
                .opacity(dot ? 1 : 0)
                .accessibilityLabel(String(localized: "row.unread", defaultValue: "Unread", comment: "Accessibility label of the dot on a file the user has not acted on."))
                .accessibilityHidden(!dot)
            ThumbnailView(file: file)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // The system kind when the line fits, the extension when it does not
                // ("Image disque" after a French "la semaine dernière" is one line too many).
                ViewThatFits(in: .horizontal) {
                    metaText(kind: file.rowKind)
                    metaText(kind: file.shortKind)
                }
            }
            Spacer(minLength: 4)
            // Rows for gone files exist only in History; they carry no actions.
            if !file.missing {
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(hovering || selected ? 1 : 0)
                .accessibilityIdentifier("rowMenu")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // The pointer highlights a row the same way keyboard focus does; selection adds a fill.
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.22) : (hovering ? Color.accentColor.opacity(0.10) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(focused || hovering ? 0.9 : 0), lineWidth: 1.5)
        )
        .opacity(file.missing ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture { actions.click() }
        // The row is a file: it can be dragged into Finder, Mail, a browser upload field or
        // anywhere else that takes a file. Dragging counts as using the file, so it is read.
        .onDrag {
            actions.dragStarted()
            return NSItemProvider(contentsOf: URL(fileURLWithPath: file.path)) ?? NSItemProvider()
        }
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(file.name)
        .accessibilityIdentifier("row")
    }

    private func metaText(kind: String?) -> some View {
        Text(meta(kind: kind))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// `relative time · size · kind`. The source is not here (it truncated the line); it is in
    /// the tooltip and the menu. A duplicate name adds its folder, a gone History row its note.
    private func meta(kind: String?) -> String {
        var parts: [String] = []
        parts.append(file.addedAt.formatted(.relative(presentation: .named)))
        if file.kind != .folder { parts.append(file.size.formatted(.byteCount(style: .file))) }
        if let kind { parts.append(kind) }
        if showFolder { parts.append(file.folderName) }
        return parts.joined(separator: " · ")
    }

    private var tooltip: String {
        [file.source.localizedDescription, file.path].compactMap { $0 }.joined(separator: "\n")
    }

    @ViewBuilder
    private var menuItems: some View {
        if !file.missing {
            if let source = file.source.localizedDescription {
                Text(source)
                Divider()
            }
            Button(String(localized: "action.open", defaultValue: "Open", comment: "Menu item: open the file in its default app.")) { actions.open() }
            Button(String(localized: "action.quickLook", defaultValue: "Quick Look", comment: "Menu item: the macOS Quick Look preview. Use the system's name for it.")) { actions.quickLook() }
            Button(String(localized: "action.showInFinder", defaultValue: "Show in Finder")) { actions.reveal() }
            Divider()
            // History rows have no unread state, so no toggle there.
            if showUnread {
                if file.unread {
                    Button(String(localized: "action.markRead", defaultValue: "Mark as Read", comment: "Menu item: clears the row's unread dot.")) { actions.markRead() }
                } else {
                    Button(String(localized: "action.markUnread", defaultValue: "Mark as Unread", comment: "Menu item: puts the unread dot back.")) { actions.markUnread() }
                }
            }
            Button(String(localized: "action.copyPath", defaultValue: "Copy Path")) { actions.copyPath() }
            Button(String(localized: "action.copyName", defaultValue: "Copy Name")) { actions.copyName() }
            Divider()
            Button(String(localized: "action.move", defaultValue: "Move to…")) { actions.moveTo() }
            if file.isZip {
                Button(String(localized: "action.unzip", defaultValue: "Unzip Here")) { actions.unzip() }
            }
            Divider()
            Button(String(localized: "action.trash", defaultValue: "Move to Trash", comment: "Menu item and ⌫.")) { actions.trash() }
        }
    }
}

// MARK: - Pieces

/// One filter chip: hugs its label, 28 pt tall, filled accent when selected.
struct FilterChip: View {
    let title: String
    /// Locale-independent id for the accessibility identifier ("filter-pdf").
    let id: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
                .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.08)))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("filter-\(id)")
    }
}

/// A History row for a file that has moved or been deleted: smaller, secondary, a symbol
/// instead of a blank document icon, and one action, which is to forget it.
struct GoneRowView: View {
    let file: InboxFile
    let focused: Bool
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 6, height: 6)
            Image(systemName: "questionmark.folder")
                .font(.system(size: 17))
                .foregroundStyle(.tertiary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(file.addedAt.formatted(.relative(presentation: .named))) · \(String(localized: "history.gone", defaultValue: "Moved or deleted", comment: "Meta line of a History row whose file is gone."))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Menu {
                Button(removeTitle, action: remove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0)
            .accessibilityIdentifier("rowMenu")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor.opacity(focused ? 0.9 : 0), lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture(perform: remove)
        .onHover { hovering = $0 }
        .contextMenu { Button(removeTitle, action: remove) }
        .help(file.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(file.name)
        .accessibilityIdentifier("goneRow")
    }

    private var removeTitle: String {
        String(localized: "history.remove", defaultValue: "Remove from history", comment: "The only action on a gone History row: click, ⌫ or the menu.")
    }
}

struct EmptyStateView: View {
    let state: EmptyState
    /// History keeps its own wording for "No matches"; the inbox adds a hint.
    var inHistory = false
    /// The primary folder's name, for the wording of "nothing new" and "open folder".
    var folderName = "Downloads"
    let grant: () -> Void
    var openDownloads: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            switch state {
            case .noMatches:
                Text(String(localized: "empty.noMatches", defaultValue: "No matches.", comment: "Inbox (Pro) or History while the search finds nothing."))
                    .font(.headline)
                if !inHistory {
                    Text(String(localized: "empty.noMatches.hint", defaultValue: "Try a file name or type like pdf.", comment: "Under 'No matches' on the inbox: what the search understands."))
                        .foregroundStyle(.secondary)
                }
            case .historyEmpty:
                Text(String(localized: "history.empty", defaultValue: "Nothing in history yet.", comment: "History panel before any file has been recorded."))
                    .font(.headline)
            case .nothingNew:
                Text(String(localized: "empty.noRecent.title", defaultValue: "No recent downloads", comment: "Empty state of the inbox when the watched folders hold nothing recent."))
                    .font(.headline)
                Text(String(localized: "empty.noRecent.body", defaultValue: "New files in \(folderName) will show up here.", comment: "Placeholder: the primary folder's name, usually Downloads."))
                    .foregroundStyle(.secondary)
                if let openDownloads {
                    Button(String(localized: "empty.openDownloads", defaultValue: "Open \(folderName) Folder", comment: "Button under the empty inbox: opens the folder in Finder. Placeholder: the primary folder's name, usually Downloads."), action: openDownloads)
                        .accessibilityIdentifier("openDownloads")
                }
            case .nothingLastHour:
                Text(String(localized: "empty.lastHour", defaultValue: "Nothing in the last hour", comment: "Empty state of the 1h chip."))
                    .font(.headline)
            case .nothingToday:
                Text(String(localized: "empty.today", defaultValue: "Nothing today", comment: "Empty state of the Today chip."))
                    .font(.headline)
            case .caughtUp:
                Text(String(localized: "empty.caughtUp", defaultValue: "You’re all caught up", comment: "Empty state of the Unread chip: every file has been opened or marked read."))
                    .font(.headline)
            case .needsAccess:
                Text(String(localized: "inbox.permission.title", defaultValue: "Downtray can't see your Downloads folder.", comment: "Empty state when macOS denied access. Keep the brand name."))
                    .multilineTextAlignment(.center)
                Button(String(localized: "inbox.permission.button", defaultValue: "Grant access to Downloads", comment: "Opens the folder picker that grants access."), action: grant)
                    .accessibilityIdentifier("grantAccess")
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("emptyState")
    }

    private var symbol: String {
        switch state {
        case .needsAccess: "lock.circle"
        case .noMatches: "magnifyingglass"
        case .historyEmpty: "clock"
        case .nothingNew: "tray"
        case .nothingLastHour: "clock"
        case .nothingToday: "calendar"
        case .caughtUp: "checkmark.circle"
        }
    }
}

/// The Pro sheet, drawn inside the panel (a popover cannot host a window sheet). One sentence,
/// a purchase button, a way out, and the App Store's Restore.
struct PaywallView: View {
    let presenter: InboxPresenter
    @State private var price: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .onTapGesture { presenter.dispatch(.dismissPaywall) }
            VStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                Text(String(localized: "paywall.title", defaultValue: "Downtray Pro", comment: "Title of the Pro sheet. Keep the brand name."))
                    .font(.headline)
                Text(String(localized: "paywall.body", defaultValue: "History, extra folders, and rules. Pay once.", comment: "The one sentence on the Pro sheet."))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button(price.map { String(localized: "pro.unlock.buttonWithPrice", defaultValue: "Unlock Pro — \($0)") }
                       ?? String(localized: "pro.unlock.button", defaultValue: "Unlock Pro…")) {
                    presenter.dispatch(.unlockPro)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("paywallUnlock")
                Button(String(localized: "paywall.notNow", defaultValue: "Not now", comment: "Secondary button on the Pro sheet: closes it.")) {
                    presenter.dispatch(.dismissPaywall)
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("paywallDismiss")
                Button(String(localized: "pro.restore", defaultValue: "Restore Purchases")) { presenter.dispatch(.restorePurchases) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let toast = presenter.model.toast, toast.isError {
                    Text(toast.text.localized)
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .frame(width: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
        }
        .task { price = await (presenter.services as? MacServices)?.proPrice() }
        .accessibilityIdentifier("paywall")
    }
}

struct NoticeView: View {
    let message: String
    let isError: Bool
    let action: (String, () -> Void)?
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.orange : Color.green)
            Text(message)
                .lineLimit(2)
            if let (title, act) = action {
                Button(title, action: act)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "notice.dismiss", defaultValue: "Dismiss", comment: "Accessibility label of the × on a notice."))
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .padding(.bottom, 44)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private extension View {
    /// The History panel's navigation buttons: Liquid Glass capsules on macOS 26 and later,
    /// plain link buttons before that (the deployment target is macOS 14).
    @ViewBuilder
    func navigationGlass() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .font(.callout)
        } else {
            self.buttonStyle(.link)
                .font(.callout)
        }
    }
}
