import Foundation

/// A flattened, agent-friendly view of `InboxModel`. Derived fields are precomputed so a reader
/// does not need to know the model's internals to answer "what is in the inbox right now?".
/// Everything the UI shows is derivable from this value; the CLI, the bridge, the shell script
/// and any UI test assert against it.
public struct Snapshot: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable {
        public let id: FileID
        public let name: String
        /// Parent folder name, shown when another visible row has the same name.
        public let folder: String
        public let showFolder: Bool
        public let size: Int64
        public let kind: String
        /// "docs", "images", "media", "archives", "apps" or "other".
        public let type: String
        public let source: String?
        public let addedAt: String
        public let unread: Bool
        public let missing: Bool
        public let selected: Bool
        public let focused: Bool
    }

    public struct Folder: Codable, Equatable, Sendable {
        public let kind: String
        public let title: String
        public let path: String
        public let enabled: Bool
        public let access: String
        public let custom: Bool
    }

    public struct RuleView: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let enabled: Bool
        public let summary: String
    }

    public struct SuggestionView: Codable, Equatable, Sendable {
        public let file: String
        public let message: String
    }

    public struct SettingsView: Codable, Equatable, Sendable {
        public let launchAtLogin: Bool
        public let hotkey: String
        public let notifications: Bool
        public let watchDesktop: Bool
        public let includeFolders: Bool
        /// "day", "week", "month" or "forever".
        public let retention: String
        /// True while "Clear List" hides files; `restore-list` brings them back.
        public let listCleared: Bool
        public let markReadOnClose: Bool
        public let showBadge: Bool
        public let typeOverrides: [String: String]
        /// The remembered chip and Type menu ("any" when none).
        public let selectedChip: String
        public let selectedType: String
        public let pro: Bool
        public let extraFolders: [String]
        public let rules: [RuleView]
        /// "en", "ja", "de", "fr", or nil when the app follows macOS.
        public let language: String?
    }

    public struct ToastView: Codable, Equatable, Sendable {
        public let message: String
        public let isError: Bool
    }

    public struct UndoView: Codable, Equatable, Sendable {
        public let count: Int
        public let ready: Bool
        public let files: [String]
    }

    public let panelOpen: Bool
    /// The chip: "all", "1h", "today" or "unread".
    public let filter: String
    public let filters: [String]
    /// The Type menu: "any", or a group.
    public let type: String
    public let types: [String]
    /// Inbox files per chip, before the Type menu and the search (the chip badges).
    public let counts: [String: Int]
    /// Unread files in the inbox (0 when the badge is switched off).
    public let badge: Int
    public let unread: Int
    /// "needsAccess", "nothingNew", "nothingLastHour", "nothingToday", "caughtUp",
    /// "historyEmpty", "noMatches", or nil when rows are shown.
    public let emptyState: String?
    /// Section header before each row in the inbox (All and Today chips), else nil.
    public let sections: [String]?
    public let rows: [Row]
    public let selection: [FileID]
    public let focused: FileID?
    public let toast: ToastView?
    public let undo: UndoView?
    public let pendingMove: [String]?
    public let folders: [Folder]
    public let settings: SettingsView
    public let historyMode: Bool
    /// "all", "available" or "gone".
    public let historyFilter: String
    public let historyCount: Int
    public let query: String
    public let suggestion: SuggestionView?
    /// The list ends with a "Show older files" row.
    public let olderFiles: Bool
    /// The Pro sheet is up.
    public let paywall: Bool

    public init(_ model: InboxModel) {
        panelOpen = model.panelOpen
        filter = model.filter.rawValue
        filters = FileFilter.allCases.map(\.rawValue)
        type = model.typeFilter?.rawValue ?? "any"
        types = ["any"] + TypeGroup.menuCases.map(\.rawValue)
        counts = Dictionary(uniqueKeysWithValues: FileFilter.allCases.filter { $0 != .all }.map { ($0.rawValue, model.count(for: $0)) })
        let grouped = model.inboxSections
        sections = grouped.isEmpty ? nil : grouped.flatMap { section in section.files.map { _ in section.section.rawValue } }
        badge = model.badgeCount
        unread = model.unreadCount
        emptyState = model.emptyState?.rawValue
        let duplicates = model.duplicateNames
        rows = model.visibleFiles.map { file in
            Row(
                id: file.id,
                name: file.name,
                folder: file.folderName,
                showFolder: duplicates.contains(file.name),
                size: file.size,
                kind: file.kind.rawValue,
                type: file.typeGroup(overrides: model.settings.typeOverrides).rawValue,
                source: file.source.label,
                addedAt: file.addedAt.formatted(.iso8601),
                unread: file.unread,
                missing: file.missing,
                selected: model.selection.contains(file.id),
                focused: model.focused == file.id
            )
        }
        selection = model.visibleIDs.filter { model.selection.contains($0) }
        focused = model.focused
        toast = model.toast.map { ToastView(message: $0.message, isError: $0.isError) }
        undo = model.undo.map { UndoView(count: $0.files.count, ready: $0.ready, files: $0.files.map(\.name)) }
        pendingMove = model.pendingMove?.map { ($0 as NSString).lastPathComponent }
        folders = model.folders.map {
            Folder(kind: $0.kind.rawValue, title: $0.title, path: $0.path, enabled: $0.enabled,
                   access: $0.access.rawValue, custom: $0.kind.isCustom)
        }
        settings = SettingsView(
            launchAtLogin: model.settings.launchAtLogin,
            hotkey: model.settings.hotkey.display,
            notifications: model.settings.notificationsEnabled,
            watchDesktop: model.settings.watchDesktop,
            includeFolders: model.settings.includeFolders,
            retention: model.settings.retention.rawValue,
            listCleared: model.settings.listClearedAt != nil,
            markReadOnClose: model.settings.markReadOnClose,
            showBadge: model.settings.showBadge,
            typeOverrides: model.settings.typeOverrides.mapValues(\.rawValue),
            selectedChip: model.settings.selectedChip.rawValue,
            selectedType: model.settings.selectedType?.rawValue ?? "any",
            pro: model.settings.proUnlocked,
            extraFolders: model.settings.extraFolders,
            rules: model.settings.rules.map { RuleView(id: $0.id, name: $0.name, enabled: $0.enabled, summary: $0.summary) },
            language: model.settings.language?.rawValue
        )
        historyMode = model.historyMode
        historyFilter = model.historyFilter.rawValue
        historyCount = model.history.count
        query = model.query
        suggestion = model.suggestion.map { SuggestionView(file: ($0.fileID as NSString).lastPathComponent, message: $0.message) }
        olderFiles = model.hasOlderFiles
        paywall = model.paywallShown
    }

    public func json(pretty: Bool = true) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// One-line human readable summary.
    public var summary: String {
        var text = "[\(panelOpen ? "open" : "closed")] \(historyMode ? "history " : "")\(filter)"
        if type != "any" { text += " \(type)" }
        text += ": "
        if let emptyState {
            switch emptyState {
            case "needsAccess": text += "needs access to Downloads"
            case "historyEmpty": text += "nothing in history"
            case "noMatches": text += "no matches"
            case "nothingLastHour": text += "nothing in the last hour"
            case "nothingToday": text += "nothing today"
            case "caughtUp": text += "all caught up"
            default: text += "no recent downloads"
            }
        } else {
            text += "\(rows.count) rows"
            let unreadRows = rows.filter(\.unread).count
            if unreadRows > 0 { text += ", \(unreadRows) unread" }
        }
        if badge > 0 { text += ", badge \(badge)" }
        if let focused { text += ", focus \((focused as NSString).lastPathComponent)" }
        if selection.count > 1 { text += ", \(selection.count) selected" }
        if let undo { text += ", undo \(undo.count)\(undo.ready ? "" : " (pending)")" }
        if let toast { text += ", toast \"\(toast.message)\"" }
        if let suggestion { text += ", suggests \"\(suggestion.message)\"" }
        if paywall { text += ", pro sheet" }
        if settings.pro { text += ", pro" }
        return text
    }
}

extension InboxModel {
    public var snapshot: Snapshot { Snapshot(self) }
}
