import AppKit
import SwiftUI
import InboxCore

/// The panel (~360 × 520 pt): header with filter chips, the list of latest files, and a footer.
/// The view only sends events; focus, selection, toast and undo all come from the model.
struct PopoverView: View {
    @Environment(InboxPresenter.self) private var presenter
    @FocusState private var focused: Bool
    let openSettings: () -> Void

    private var model: InboxModel { presenter.model }

    var body: some View {
        VStack(spacing: 0) {
            header
            chips
            if model.isPro { searchField }
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 360, height: 520)
        .overlay(alignment: .bottom) { notices }
        .background(hiddenShortcuts)
        .background(SettingsOpener())
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in handle(press) }
        .onAppear { focused = true }
        .accessibilityIdentifier("popover")
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text(appName)
                .font(.headline)
            Spacer()
            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "inbox.settings", defaultValue: "Settings", comment: "Tooltip on the gear button that opens Settings."))
            .accessibilityIdentifier("settings")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// Chips wrap to a second line when a locale's labels do not fit in one (French does
    /// at 360 pt); a chip is never truncated or scrolled out of view.
    private var chips: some View {
        FlowLayout(spacing: 6) {
            ForEach(FileFilter.allCases, id: \.self) { filter in
                FilterChip(title: filter.localizedTitle, id: filter.rawValue, selected: model.filter == filter) {
                    presenter.dispatch(.setFilter(filter))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    /// Pro: filters the visible list (recent or history) by file name.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(
                model.historyMode
                    ? String(localized: "inbox.search.history", defaultValue: "Search history", comment: "Placeholder of the search field while History is shown.")
                    : String(localized: "inbox.search", defaultValue: "Search", comment: "Placeholder of the search field."),
                text: Binding(get: { presenter.model.query }, set: { presenter.dispatch(.setQuery($0)) })
            )
            .textFieldStyle(.plain)
            .accessibilityIdentifier("search")
            if !model.query.isEmpty {
                Button { presenter.dispatch(.setQuery("")) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        if let empty = model.emptyState {
            EmptyStateView(state: empty, searching: !model.query.isEmpty, history: model.historyMode) {
                presenter.dispatch(.grantAccess(.downloads))
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.visibleFiles) { file in
                            FileRowView(
                                file: file,
                                showFolder: model.duplicateNames.contains(file.name),
                                selected: model.selection.contains(file.id),
                                focused: model.focused == file.id,
                                actions: RowActions(presenter: presenter, file: file, selection: model.selection)
                            )
                            .id(file.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .onChange(of: model.focused) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button(String(localized: "inbox.footer.openDownloads", defaultValue: "Open Downloads in Finder", comment: "Footer link button. Keep short: it shares one line with two other buttons.")) { presenter.dispatch(.openWatchedFolder(.downloads)) }
            Spacer()
            if model.isPro {
                Button(model.historyMode
                       ? String(localized: "inbox.footer.recent", defaultValue: "Recent", comment: "Footer button: switch from History back to the current files.")
                       : String(localized: "inbox.footer.history", defaultValue: "History", comment: "Footer button: show every file that ever arrived (Pro).")) {
                    presenter.dispatch(.setHistoryMode(!model.historyMode))
                }
                .accessibilityIdentifier("historyToggle")
            }
            Button(String(localized: "inbox.footer.markAllSeen", defaultValue: "Mark all seen", comment: "Footer button: clears the unread dots and the badge.")) { presenter.dispatch(.markAllSeen) }
                .disabled(model.unreadCount == 0 && model.badgeCount == 0)
        }
        .buttonStyle(.link)
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

    /// Return, Space, arrows and ⌫ act on the focused/selected rows. ⌘R/⌘C/⌘M/⌘U are declared as
    /// hidden buttons so they also show up in the menu bar's key equivalents.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) { return .ignored }
        switch press.key {
        case .return: presenter.dispatch(.open(.selection)); return .handled
        case .space: presenter.dispatch(.quickLook(.selection)); return .handled
        case .upArrow: presenter.dispatch(.moveFocus(.up)); return .handled
        case .downArrow: presenter.dispatch(.moveFocus(.down)); return .handled
        case .delete, .deleteForward: presenter.dispatch(.trash(.selection)); return .handled
        case .escape:
            if model.selection.isEmpty { return .ignored }
            presenter.dispatch(.clearSelection)
            return .handled
        default: return .ignored
        }
    }

    private var hiddenShortcuts: some View {
        Group {
            Button(String(localized: "action.reveal", defaultValue: "Reveal in Finder", comment: "Menu item and ⌘R.")) { presenter.dispatch(.reveal(.selection)) }.keyboardShortcut("r", modifiers: .command)
            Button(String(localized: "action.copyPath", defaultValue: "Copy Path", comment: "Menu item and ⌘C: puts the file's path on the clipboard.")) { presenter.dispatch(.copyPath(.selection)) }.keyboardShortcut("c", modifiers: .command)
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
    func moveTo() { presenter.dispatch(.moveTo(target)) }
    func unzip() { presenter.dispatch(.unzip(target)) }
    func trash() { presenter.dispatch(.trash(target)) }
    func dismiss() { presenter.dispatch(.dismiss(file.id)) }
}

struct FileRowView: View {
    let file: InboxFile
    let showFolder: Bool
    let selected: Bool
    let focused: Bool
    let actions: RowActions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(file: file)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if file.unread && !file.missing {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(String(localized: "row.unread", defaultValue: "Unread", comment: "Accessibility label of the dot on a file the user has not acted on."))
            }
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
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
        .help(file.missing ? String(localized: "row.missing.help", defaultValue: "This file was moved or deleted. History keeps it so you can see where it came from.", comment: "Tooltip on a greyed-out History row.") : file.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(file.name)
        .accessibilityIdentifier("row")
    }

    private var meta: String {
        var parts: [String] = []
        parts.append(file.addedAt.formatted(.relative(presentation: .named)))
        if file.kind != .folder { parts.append(file.size.formatted(.byteCount(style: .file))) }
        parts.append(file.kind.localizedLabel)
        if let source = file.source.label { parts.append(source) }
        if showFolder { parts.append(file.folderName) }
        if file.missing { parts.append(String(localized: "row.missing", defaultValue: "moved or deleted", comment: "Meta line fragment on a History row whose file is gone.")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var menuItems: some View {
        if !file.missing {
            Button(String(localized: "action.open", defaultValue: "Open", comment: "Menu item: open the file in its default app.")) { actions.open() }
            Button(String(localized: "action.quickLook", defaultValue: "Quick Look", comment: "Menu item: the macOS Quick Look preview. Use the system's name for it.")) { actions.quickLook() }
            Button(String(localized: "action.reveal", defaultValue: "Reveal in Finder")) { actions.reveal() }
            Button(String(localized: "action.copyPath", defaultValue: "Copy Path")) { actions.copyPath() }
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

/// Left to right, wrapping to the next line when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = arrange(width: bounds.width, subviews: subviews).origins
        for (subview, origin) in zip(subviews, origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            widest = max(widest, x - spacing)
        }
        // Fill the proposed width so the rows stay left-aligned inside a wider container.
        return (CGSize(width: width.isFinite ? width : widest, height: y + rowHeight), origins)
    }
}

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
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.08)))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("filter-\(id)")
    }
}

struct EmptyStateView: View {
    let state: EmptyState
    var searching = false
    var history = false
    let grant: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: state == .needsAccess ? "lock.circle" : (searching ? "magnifyingglass" : "tray"))
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            switch state {
            case .nothingNew where searching:
                Text(String(localized: "inbox.empty.noMatches", defaultValue: "No matches.", comment: "Empty state while a search finds nothing."))
                    .font(.headline)
            case .nothingNew where history:
                Text(String(localized: "inbox.empty.history.title", defaultValue: "No history yet.", comment: "Empty state of the History list."))
                    .font(.headline)
                Text(String(localized: "inbox.empty.history.body", defaultValue: "Every file that lands in a watched folder is remembered here."))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .nothingNew:
                Text(String(localized: "inbox.empty.title", defaultValue: "Nothing new.", comment: "Empty state of the inbox."))
                    .font(.headline)
                Text(String(localized: "inbox.empty.body", defaultValue: "New downloads will show up here."))
                    .foregroundStyle(.secondary)
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
