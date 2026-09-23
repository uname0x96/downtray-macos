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
            Text("Arrivals")
                .font(.headline)
            Spacer()
            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityIdentifier("settings")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(FileFilter.allCases, id: \.self) { filter in
                    FilterChip(title: filter.title, selected: model.filter == filter) {
                        presenter.dispatch(.setFilter(filter))
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.bottom, 8)
    }

    /// Pro: filters the visible list (recent or history) by file name.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(
                model.historyMode ? String(localized: "Search history") : String(localized: "Search"),
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
            Button("Open Downloads in Finder") { presenter.dispatch(.openWatchedFolder(.downloads)) }
            Spacer()
            if model.isPro {
                Button(model.historyMode ? String(localized: "Recent") : String(localized: "History")) {
                    presenter.dispatch(.setHistoryMode(!model.historyMode))
                }
                .accessibilityIdentifier("historyToggle")
            }
            Button("Mark all seen") { presenter.dispatch(.markAllSeen) }
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
                message: suggestion.message,
                isError: false,
                action: (String(localized: "Yes"), { presenter.dispatch(.acceptSuggestion) }),
                dismiss: { presenter.dispatch(.dismissSuggestion) }
            )
            .accessibilityIdentifier("suggestion")
        } else if let undo = model.undo {
            NoticeView(
                message: undo.files.count == 1
                    ? String(localized: "Moved \(undo.files[0].name) to Trash")
                    : String(localized: "Moved \(undo.files.count) files to Trash"),
                isError: false,
                action: undo.ready ? (String(localized: "Undo"), { presenter.dispatch(.undoTrash) }) : nil
            )
            .accessibilityIdentifier("undoToast")
        } else if let toast = model.toast {
            NoticeView(message: toast.message, isError: toast.isError, action: nil)
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
            Button("Reveal in Finder") { presenter.dispatch(.reveal(.selection)) }.keyboardShortcut("r", modifiers: .command)
            Button("Copy Path") { presenter.dispatch(.copyPath(.selection)) }.keyboardShortcut("c", modifiers: .command)
            Button("Move to…") { presenter.dispatch(.moveTo(.selection)) }.keyboardShortcut("m", modifiers: .command)
            Button("Unzip Here") { presenter.dispatch(.unzip(.selection)) }.keyboardShortcut("u", modifiers: .command)
            Button("Select All") { selectAll() }.keyboardShortcut("a", modifiers: .command)
            Button("Quit Arrivals") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
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
                    .accessibilityLabel("Unread")
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
        .help(file.missing ? String(localized: "This file was moved or deleted. History keeps it so you can see where it came from.") : file.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(file.name)
        .accessibilityIdentifier("row")
    }

    private var meta: String {
        var parts: [String] = []
        parts.append(file.addedAt.formatted(.relative(presentation: .named)))
        if file.kind != .folder { parts.append(file.size.formatted(.byteCount(style: .file))) }
        parts.append(file.kind.label)
        if let source = file.source.label { parts.append(source) }
        if showFolder { parts.append(file.folderName) }
        if file.missing { parts.append(String(localized: "moved or deleted")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var menuItems: some View {
        if !file.missing {
            Button("Open") { actions.open() }
            Button("Quick Look") { actions.quickLook() }
            Button("Reveal in Finder") { actions.reveal() }
            Button("Copy Path") { actions.copyPath() }
            Divider()
            Button("Move to…") { actions.moveTo() }
            if file.isZip {
                Button("Unzip Here") { actions.unzip() }
            }
            Divider()
            Button("Move to Trash") { actions.trash() }
        }
    }
}

// MARK: - Pieces

struct FilterChip: View {
    let title: String
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
        .accessibilityIdentifier("filter-\(title)")
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
                Text("No matches.")
                    .font(.headline)
            case .nothingNew where history:
                Text("No history yet.")
                    .font(.headline)
                Text("Every file that lands in a watched folder is remembered here.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .nothingNew:
                Text("Nothing new.")
                    .font(.headline)
                Text("New downloads will show up here.")
                    .foregroundStyle(.secondary)
            case .needsAccess:
                Text("Arrivals can't see your Downloads folder.")
                    .multilineTextAlignment(.center)
                Button("Grant access to Downloads", action: grant)
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
                    .accessibilityLabel("Dismiss")
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
