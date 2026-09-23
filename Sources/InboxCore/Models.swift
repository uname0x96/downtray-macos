import Foundation

/// A file is identified by its POSIX path. Paths are unique per volume and stable until the
/// file moves, which is exactly when the inbox stops caring about the old identity.
public typealias FileID = String

// MARK: - Files

public enum FileKind: String, Codable, Sendable, CaseIterable, Equatable {
    case pdf, image, archive, installer, folder, other

    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "webp", "bmp", "svg", "avif",
    ]
    public static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "7z"]
    public static let installerExtensions: Set<String> = ["dmg", "pkg", "app"]

    public static func forExtension(_ ext: String, isDirectory: Bool = false) -> FileKind {
        let lower = ext.lowercased()
        if installerExtensions.contains(lower) { return .installer }
        if isDirectory { return .folder }
        if lower == "pdf" { return .pdf }
        if imageExtensions.contains(lower) { return .image }
        if archiveExtensions.contains(lower) { return .archive }
        return .other
    }

    /// Short label for the meta line ("PDF", "Image", ...).
    public var label: String {
        switch self {
        case .pdf: return "PDF"
        case .image: return "Image"
        case .archive: return "Archive"
        case .installer: return "Installer"
        case .folder: return "Folder"
        case .other: return "File"
        }
    }
}

/// Where a file came from, when it can be told.
public enum FileSource: Equatable, Codable, Sendable, Hashable {
    /// Downloaded from the web; `host` is the host of `kMDItemWhereFroms` ("dropbox.com").
    case web(host: String)
    /// No where-froms and landed in Downloads moments ago: most likely AirDrop.
    case airDrop
    case unknown

    /// Text shown after the kind in the meta line, or nil when nothing is known.
    public var label: String? {
        switch self {
        case .web(let host): return host
        case .airDrop: return "AirDrop"
        case .unknown: return nil
        }
    }
}

public struct InboxFile: Identifiable, Equatable, Codable, Sendable, Hashable {
    public let path: String
    public var size: Int64
    public var addedAt: Date
    public var modifiedAt: Date
    public var kind: FileKind
    public var source: FileSource
    /// True until the user acts on the file from the inbox (open, preview, reveal, copy, ...).
    public var unread: Bool
    /// The file disappeared from its folder while listed. The row greys out; a tap removes it.
    public var missing: Bool

    public init(
        path: String,
        size: Int64 = 0,
        addedAt: Date,
        modifiedAt: Date? = nil,
        kind: FileKind? = nil,
        source: FileSource = .unknown,
        unread: Bool = true,
        missing: Bool = false
    ) {
        self.path = path
        self.size = size
        self.addedAt = addedAt
        self.modifiedAt = modifiedAt ?? addedAt
        self.kind = kind ?? FileKind.forExtension((path as NSString).pathExtension)
        self.source = source
        self.unread = unread
        self.missing = missing
    }

    public var id: FileID { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var folder: String { (path as NSString).deletingLastPathComponent }
    public var folderName: String { (folder as NSString).lastPathComponent }
    public var fileExtension: String { (path as NSString).pathExtension.lowercased() }
    /// Only `.zip` can be extracted in the MVP.
    public var isZip: Bool { fileExtension == "zip" }
}

// MARK: - Type groups

/// The Type menu's groups. A file belongs to exactly one, by extension (`typeOverrides` in
/// Settings win over the built-in table). `other` is never offered in the menu: uncategorized
/// files show only under Any, or when the search matches them.
public enum TypeGroup: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    case docs, images, media, archives, apps, other

    /// The groups the menu offers, in menu order.
    public static let menuCases: [TypeGroup] = [.docs, .images, .media, .archives, .apps]

    public var title: String {
        switch self {
        case .docs: return "Docs"
        case .images: return "Images"
        case .media: return "Media"
        case .archives: return "Archives"
        case .apps: return "Apps"
        case .other: return "Other"
        }
    }

    /// The built-in extension table, from the filter spec. First match wins, so an extension
    /// is listed once.
    public static let builtIn: [String: TypeGroup] = {
        var table: [String: TypeGroup] = [:]
        let docs = ["pdf", "doc", "docx", "docm", "odt", "rtf", "txt", "md",
                    "xls", "xlsx", "csv", "tsv", "ods", "numbers",
                    "ppt", "pptx", "key", "odp", "pages", "epub", "mobi",
                    "json", "xml", "yaml", "yml"]
        let images = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "svg", "ico", "raw", "dng"]
        let media = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "mpeg", "mpg",
                     "mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg"]
        let archives = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]
        let apps = ["dmg", "pkg", "app", "exe", "msi", "apk"]
        for (group, list) in [(TypeGroup.docs, docs), (.images, images), (.media, media), (.archives, archives), (.apps, apps)] {
            for ext in list where table[ext] == nil { table[ext] = group }
        }
        return table
    }()

    /// The one place that maps an extension to a group: user overrides first, then the table.
    public static func forExtension(_ ext: String, overrides: [String: TypeGroup] = [:]) -> TypeGroup {
        let lower = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if let override = overrides[lower] { return override }
        return builtIn[lower] ?? .other
    }
}

extension InboxFile {
    public func typeGroup(overrides: [String: TypeGroup] = [:]) -> TypeGroup {
        kind == .folder ? .other : TypeGroup.forExtension(fileExtension, overrides: overrides)
    }
}

// MARK: - Filters

/// The chip row: one time or state axis, single-select. Type is a separate menu.
public enum FileFilter: String, CaseIterable, Codable, Sendable, Equatable {
    case all
    case lastHour = "1h"
    case today
    case unread

    public var title: String {
        switch self {
        case .all: return "All"
        case .lastHour: return "1h"
        case .today: return "Today"
        case .unread: return "Unread"
        }
    }

    public func matches(_ file: InboxFile, now: Date, today: Date) -> Bool {
        switch self {
        case .all: return true
        case .lastHour: return now.timeIntervalSince(file.addedAt) <= 3600
        case .today: return file.addedAt >= today
        case .unread: return file.unread
        }
    }
}

/// How long the inbox keeps showing a file after it arrived. History (Pro) keeps everything.
public enum Retention: String, CaseIterable, Codable, Sendable, Equatable {
    case day, week, month

    public var seconds: TimeInterval {
        switch self {
        case .day: return 24 * 3600
        case .week: return 7 * 24 * 3600
        case .month: return 30 * 24 * 3600
        }
    }

    public var title: String {
        switch self {
        case .day: return "24 hours"
        case .week: return "7 days"
        case .month: return "30 days"
        }
    }
}

/// The visual sections of the inbox list, for the All and Today chips. Not a filter.
public enum InboxSection: String, CaseIterable, Sendable, Equatable {
    case justNow, earlierToday, yesterday, thisWeek, earlier

    public static let justNowSeconds: TimeInterval = 15 * 60

    public static func of(_ file: InboxFile, now: Date, today: Date, calendar: Calendar = .current) -> InboxSection {
        if now.timeIntervalSince(file.addedAt) < justNowSeconds { return .justNow }
        if file.addedAt >= today { return .earlierToday }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        if file.addedAt >= yesterday { return .yesterday }
        let weekAgo = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        if file.addedAt >= weekAgo { return .thisWeek }
        return .earlier
    }
}

/// The History panel's segment: whether the file is still where it was.
public enum HistoryFilter: String, CaseIterable, Codable, Sendable, Equatable {
    case all, available, gone

    public var title: String {
        switch self {
        case .all: return "All"
        case .available: return "Available"
        case .gone: return "Gone"
        }
    }

    public func matches(_ file: InboxFile) -> Bool {
        switch self {
        case .all: return true
        case .available: return !file.missing
        case .gone: return file.missing
        }
    }
}

// MARK: - Watched folders

/// Identifies a watched folder. `.downloads` and `.desktop` are the two built-in folders; a
/// custom folder (Pro) is identified by its absolute path, so the raw value round-trips through
/// settings, bookmarks and the command line without a separate id.
public struct FolderKind: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let downloads = FolderKind("downloads")
    public static let desktop = FolderKind("desktop")
    public static let standardKinds: [FolderKind] = [.downloads, .desktop]

    /// A custom folder, identified by its path.
    public static func custom(_ path: String) -> FolderKind { FolderKind(path) }

    public var isCustom: Bool { rawValue.hasPrefix("/") }

    public var title: String {
        switch self {
        case .downloads: return "Downloads"
        case .desktop: return "Desktop"
        default: return (rawValue as NSString).lastPathComponent
        }
    }
}

public enum AccessState: String, Codable, Sendable, Equatable {
    case unknown, granted, denied
}

public struct WatchedFolder: Equatable, Codable, Sendable, Identifiable {
    public var kind: FolderKind
    public var path: String
    public var enabled: Bool
    public var access: AccessState

    public init(kind: FolderKind, path: String, enabled: Bool, access: AccessState = .unknown) {
        self.kind = kind
        self.path = path
        self.enabled = enabled
        self.access = access
    }

    public var id: FolderKind { kind }
    public var title: String { kind.isCustom ? (path as NSString).lastPathComponent : kind.title }

    /// A Pro folder chosen by the user, watched from the moment it is added.
    public static func custom(_ path: String, access: AccessState = .granted) -> WatchedFolder {
        WatchedFolder(kind: .custom(path), path: path, enabled: true, access: access)
    }

    /// The two folders the free tier can watch, at their real locations for the current user.
    ///
    /// Inside the App Sandbox, `FileManager.urls(for:)` and `NSHomeDirectory()` point into the
    /// app's container (`~/Library/Containers/<id>/Data/Downloads`), which the folder watcher
    /// cannot open. The password database gives the real home, and the Downloads entitlement
    /// covers the real `~/Downloads`.
    public static var standard: [WatchedFolder] {
        let home = realHomeDirectory()
        return [
            WatchedFolder(kind: .downloads, path: home + "/Downloads", enabled: true),
            WatchedFolder(kind: .desktop, path: home + "/Desktop", enabled: false),
        ]
    }

    public static func realHomeDirectory() -> String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Deterministic folders for tests and the headless CLI.
    public static func sample(home: String = "/Users/sample") -> [WatchedFolder] {
        [
            WatchedFolder(kind: .downloads, path: home + "/Downloads", enabled: true, access: .granted),
            WatchedFolder(kind: .desktop, path: home + "/Desktop", enabled: false),
        ]
    }
}

// MARK: - Rules (Pro)

public enum RuleTrigger: String, Codable, Sendable, CaseIterable, Equatable {
    /// A new file lands in a watched folder.
    case arrival
    /// The user opened the file from the inbox.
    case opened

    public var title: String {
        switch self {
        case .arrival: return "When a file arrives"
        case .opened: return "After a file is opened"
        }
    }
}

/// Every set field must match. An empty match applies to every file.
public struct RuleMatch: Equatable, Codable, Sendable, Hashable {
    public var kind: FileKind?
    /// Matches `web(host:)` sources whose host is this or ends with "." + this ("stripe.com").
    public var host: String?
    public var nameContains: String?
    public var fileExtension: String?

    public init(kind: FileKind? = nil, host: String? = nil, nameContains: String? = nil, fileExtension: String? = nil) {
        self.kind = kind
        self.host = host?.lowercased()
        self.nameContains = nameContains
        self.fileExtension = fileExtension?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    public func matches(_ file: InboxFile) -> Bool {
        if let kind, file.kind != kind { return false }
        if let host {
            guard case .web(let fileHost) = file.source else { return false }
            let lower = fileHost.lowercased()
            if lower != host && !lower.hasSuffix("." + host) { return false }
        }
        if let nameContains, !nameContains.isEmpty,
           file.name.range(of: nameContains, options: .caseInsensitive) == nil { return false }
        if let fileExtension, !fileExtension.isEmpty, file.fileExtension != fileExtension { return false }
        return true
    }

    public var summary: String {
        var parts: [String] = []
        if let kind { parts.append(kind.label) }
        if let fileExtension, !fileExtension.isEmpty { parts.append(".\(fileExtension)") }
        if let host { parts.append("from \(host)") }
        if let nameContains, !nameContains.isEmpty { parts.append("named “\(nameContains)”") }
        return parts.isEmpty ? "any file" : parts.joined(separator: " ")
    }
}

public enum RuleAction: Equatable, Codable, Sendable, Hashable {
    case moveTo(String)
    case trash
    case markSeen
    /// Shows a notice with a "Trash" button instead of acting on its own.
    case suggestTrash

    public var summary: String {
        switch self {
        case .moveTo(let path): return "move to \((path as NSString).lastPathComponent)"
        case .trash: return "move to Trash"
        case .markSeen: return "mark as seen"
        case .suggestTrash: return "offer to Trash it"
        }
    }
}

public struct Rule: Equatable, Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var trigger: RuleTrigger
    public var match: RuleMatch
    public var action: RuleAction

    public init(
        id: String = UUID().uuidString,
        name: String,
        enabled: Bool = true,
        trigger: RuleTrigger = .arrival,
        match: RuleMatch = RuleMatch(),
        action: RuleAction
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.trigger = trigger
        self.match = match
        self.action = action
    }

    public var summary: String { "\(trigger.title.lowercased()): \(match.summary) → \(action.summary)" }
}

/// A rule asked for confirmation ("offer to Trash it"); shown as a notice with a button.
/// `message` is the English wording the snapshot reports; the app renders its own localized
/// text from `ruleName` and `fileID`.
public struct Suggestion: Equatable, Sendable {
    public var fileID: FileID
    public var ruleName: String
    public var action: RuleAction

    public init(fileID: FileID, ruleName: String, action: RuleAction) {
        self.fileID = fileID
        self.ruleName = ruleName
        self.action = action
    }

    public var fileName: String { (fileID as NSString).lastPathComponent }

    public var message: String {
        switch action {
        case .trash: return "\(ruleName): move \(fileName) to the Trash?"
        case .moveTo(let path): return "\(ruleName): move \(fileName) to \((path as NSString).lastPathComponent)?"
        case .markSeen: return "\(ruleName): mark \(fileName) as seen?"
        case .suggestTrash: return "\(ruleName): move \(fileName) to the Trash?"
        }
    }
}

// MARK: - History (Pro)

/// One arrival, kept after the file is gone so it can be found again.
public struct HistoryEntry: Equatable, Codable, Sendable, Identifiable, Hashable {
    public var path: String
    public var size: Int64
    public var kind: FileKind
    public var source: FileSource
    public var addedAt: Date

    public init(_ file: InboxFile) {
        path = file.path
        size = file.size
        kind = file.kind
        source = file.source
        addedAt = file.addedAt
    }

    public var id: FileID { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var folder: String { (path as NSString).deletingLastPathComponent }

    /// A row for the history list; `missing` when the file is not in the inbox any more.
    public func file(present: InboxFile?) -> InboxFile {
        if let present { return present }
        return InboxFile(path: path, size: size, addedAt: addedAt, kind: kind, source: source, unread: false, missing: true)
    }
}

// MARK: - Settings

/// The languages the app ships. `nil` in `Settings.language` follows macOS.
public enum AppLanguage: String, Codable, Sendable, CaseIterable, Equatable {
    case en, ja, de, fr

    /// The language's own name ("日本語"), which is how every picker on the Mac lists languages.
    public var endonym: String {
        Locale(identifier: rawValue).localizedString(forLanguageCode: rawValue)?.capitalized(with: Locale(identifier: rawValue)) ?? rawValue
    }
}

public struct Settings: Equatable, Codable, Sendable {
    public var launchAtLogin: Bool
    public var hotkey: Hotkey
    public var notificationsEnabled: Bool
    public var watchDesktop: Bool
    public var proUnlocked: Bool
    /// Pro: extra folders to watch, by absolute path.
    public var extraFolders: [String]
    /// Pro: rules applied on arrival or after opening.
    public var rules: [Rule]
    /// UI language chosen in Settings; nil follows macOS. Applied at the next launch.
    public var language: AppLanguage?
    /// Folders inside a watched folder are listed as rows. Off by default: the inbox is for files.
    public var includeFolders: Bool
    /// How long a file stays in the inbox after it arrived.
    public var retention: Retention
    /// Closing the panel marks the rows that were on screen as read.
    public var markReadOnClose: Bool
    /// The menu bar icon shows the unread count.
    public var showBadge: Bool
    /// User's extension → group mapping; wins over the built-in table.
    public var typeOverrides: [String: TypeGroup]
    /// The chip and the Type menu are remembered between launches. The search is not.
    public var selectedChip: FileFilter
    public var selectedType: TypeGroup?
    /// "Clear list": files that arrived before this moment stay out of the inbox.
    public var listClearedAt: Date?

    public init(
        launchAtLogin: Bool = false,
        hotkey: Hotkey = .default,
        notificationsEnabled: Bool = false,
        watchDesktop: Bool = false,
        proUnlocked: Bool = false,
        extraFolders: [String] = [],
        rules: [Rule] = [],
        language: AppLanguage? = nil,
        includeFolders: Bool = false,
        retention: Retention = .week,
        markReadOnClose: Bool = false,
        showBadge: Bool = true,
        typeOverrides: [String: TypeGroup] = [:],
        selectedChip: FileFilter = .today,
        selectedType: TypeGroup? = nil,
        listClearedAt: Date? = nil
    ) {
        self.launchAtLogin = launchAtLogin
        self.hotkey = hotkey
        self.notificationsEnabled = notificationsEnabled
        self.watchDesktop = watchDesktop
        self.proUnlocked = proUnlocked
        self.extraFolders = extraFolders
        self.rules = rules
        self.language = language
        self.includeFolders = includeFolders
        self.retention = retention
        self.markReadOnClose = markReadOnClose
        self.showBadge = showBadge
        self.typeOverrides = typeOverrides
        self.selectedChip = selectedChip
        self.selectedType = selectedType
        self.listClearedAt = listClearedAt
    }

    // Settings saved by older versions have no Pro fields.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        hotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey) ?? .default
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false
        watchDesktop = try c.decodeIfPresent(Bool.self, forKey: .watchDesktop) ?? false
        proUnlocked = try c.decodeIfPresent(Bool.self, forKey: .proUnlocked) ?? false
        extraFolders = try c.decodeIfPresent([String].self, forKey: .extraFolders) ?? []
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language)
        includeFolders = try c.decodeIfPresent(Bool.self, forKey: .includeFolders) ?? false
        retention = try c.decodeIfPresent(Retention.self, forKey: .retention) ?? .week
        markReadOnClose = try c.decodeIfPresent(Bool.self, forKey: .markReadOnClose) ?? false
        showBadge = try c.decodeIfPresent(Bool.self, forKey: .showBadge) ?? true
        typeOverrides = try c.decodeIfPresent([String: TypeGroup].self, forKey: .typeOverrides) ?? [:]
        selectedChip = try c.decodeIfPresent(FileFilter.self, forKey: .selectedChip) ?? .today
        selectedType = try c.decodeIfPresent(TypeGroup.self, forKey: .selectedType)
        listClearedAt = try c.decodeIfPresent(Date.self, forKey: .listClearedAt)
    }
}

/// What Pro unlocks. Used for the typed rejection and for the settings copy.
public enum ProFeature: String, Sendable, Equatable {
    case extraFolders, history, rules

    public var title: String {
        switch self {
        case .extraFolders: return "Extra folders"
        case .history: return "History"
        case .rules: return "Rules"
        }
    }
}

// MARK: - Transient UI state that still lives in the model

/// What a toast says, as data. `message` is the English wording; it is the contract the CLI,
/// the scripts and the tests read through the snapshot, so it never changes with the locale.
/// The app maps each case to its string catalog and shows that instead.
public enum ToastText: Equatable, Sendable {
    /// One or more paths were put on the pasteboard.
    case pathCopied(count: Int)
    /// One or more file names were put on the pasteboard.
    case nameCopied(count: Int)
    /// Files were moved; `names` has one entry per file, `folder` is the destination's name.
    case moved(names: [String], folder: String)
    /// Some of the files could not be moved.
    case moveFailed(failed: Int, total: Int)
    /// A zip was extracted into a folder next to it.
    case extracted(name: String, folder: String)
    case proUnlocked
    /// The user picked a folder that is already in the list.
    case folderAlreadyWatched(name: String)
    /// Text that is final already: a service reported it in the user's language.
    case text(String)

    public var message: String {
        switch self {
        case .pathCopied(let count):
            return count == 1 ? "Path copied" : "\(count) paths copied"
        case .nameCopied(let count):
            return count == 1 ? "Name copied" : "\(count) names copied"
        case .moved(let names, let folder):
            let what = names.count == 1 ? names[0] : "\(names.count) files"
            return "Moved \(what) to \(folder)"
        case .moveFailed(let failed, let total):
            return "Could not move \(failed) of \(total) files"
        case .extracted(let name, let folder):
            return "Extracted \(name) to \(folder)"
        case .proUnlocked:
            return "Pro unlocked. Thank you!"
        case .folderAlreadyWatched(let name):
            return "'\(name)' is already watched"
        case .text(let text):
            return text
        }
    }
}

public struct Toast: Equatable, Sendable {
    public var token: Int
    public var text: ToastText
    public var isError: Bool

    public init(token: Int, text: ToastText, isError: Bool = false) {
        self.token = token
        self.text = text
        self.isError = isError
    }

    /// A toast whose wording is already final (a service error, or a test fixture).
    public init(token: Int, message: String, isError: Bool = false) {
        self.init(token: token, text: .text(message), isError: isError)
    }

    /// The English wording, as reported by the snapshot.
    public var message: String { text.message }
}

/// A file that was moved to the Trash by the inbox, with the location it landed at so it can be
/// put back by "Undo".
public struct TrashedItem: Equatable, Codable, Sendable {
    public var file: InboxFile
    public var trashedPath: String

    public init(file: InboxFile, trashedPath: String) {
        self.file = file
        self.trashedPath = trashedPath
    }
}

public struct TrashUndo: Equatable, Sendable {
    public var token: Int
    /// The rows as they were before trashing, so a failed trash can put them back.
    public var files: [InboxFile]
    /// Filled in once the file system reports where the files went. Empty means "in flight".
    public var items: [TrashedItem]

    public init(token: Int, files: [InboxFile], items: [TrashedItem] = []) {
        self.token = token
        self.files = files
        self.items = items
    }

    public var ready: Bool { !items.isEmpty }
}

public enum SelectionMode: String, Sendable, Equatable {
    case replace, toggle, range
}

/// Which files an action applies to: an explicit list, or whatever is selected (falling back to
/// the focused row).
public enum Target: Equatable, Sendable {
    case selection
    case files([FileID])
}

public enum FocusDirection: String, Sendable, Equatable {
    case up, down
}

public enum EmptyState: String, Sendable, Equatable {
    /// Downloads cannot be read; show the "Grant access to Downloads" button.
    case needsAccess
    /// The inbox holds nothing at all: "No recent downloads."
    case nothingNew
    /// The 1h chip finds nothing: "Nothing in the last hour."
    case nothingLastHour
    /// The Today chip finds nothing: "Nothing today."
    case nothingToday
    /// The Unread chip finds nothing: "You're all caught up."
    case caughtUp
    /// History (Pro) has never recorded a file: "Nothing in history yet."
    case historyEmpty
    /// The search, the Type menu or History's segment leaves nothing: "No matches."
    case noMatches
}

// MARK: - Model

/// Everything the app knows. Every screen, badge and toast is derived from this value.
public struct InboxModel: Equatable, Sendable {
    public var files: [FileID: InboxFile]
    public var panelOpen: Bool
    /// The chip row.
    public var filter: FileFilter
    /// The Type menu; nil is Any.
    public var typeFilter: TypeGroup?
    /// The Type menu's names in the UI language, so a search can match what the user reads
    /// ("Bilder"). Set by the app; empty in tests and the CLI, where the English titles apply.
    public var typeLabels: [TypeGroup: String]
    /// The first scan resolved the launch chip (Today, or All when today is empty).
    public var chipResolved: Bool
    public var selection: Set<FileID>
    public var focused: FileID?
    public var folders: [WatchedFolder]
    public var settings: Settings
    public var toast: Toast?
    public var undo: TrashUndo?
    /// Files waiting for the user to pick a "Move to…" destination.
    public var pendingMove: [FileID]?
    /// The clock, as last reported by the app (`setToday`), not read here, so the reducer stays
    /// pure. `today` is the start of `now`'s day for the Today chip; `now` drives 1h and Just now.
    public var today: Date
    public var now: Date
    /// Rows shown in the list in the free tier.
    public var listLimit: Int
    /// True once persisted settings have been loaded.
    public var loaded: Bool
    /// Source of tokens for toasts and undo timers.
    public var nextToken: Int
    /// Pro: every arrival since the app was installed, newest first, capped at `historyLimit`.
    public var history: [HistoryEntry]
    /// Pro: the list shows history instead of the current folder contents.
    public var historyMode: Bool
    /// History's All / Available / Gone segment.
    public var historyFilter: HistoryFilter
    /// Text typed into the search field; filters rows by name (and history by folder).
    public var query: String
    /// A rule waiting for the user's confirmation.
    public var suggestion: Suggestion?
    /// The Pro sheet is up in the panel (free tier, after "Show older files").
    public var paywallShown: Bool

    public static let proListLimit = 200
    public static let historyLimit = 1000

    public init(
        files: [InboxFile] = [],
        folders: [WatchedFolder] = WatchedFolder.sample(),
        settings: Settings = Settings(),
        today: Date = Calendar.current.startOfDay(for: Date()),
        now: Date? = nil,
        listLimit: Int = 20
    ) {
        self.files = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        self.panelOpen = false
        self.filter = .all
        self.typeFilter = nil
        self.typeLabels = [:]
        self.chipResolved = false
        self.selection = []
        self.focused = nil
        self.folders = folders
        self.settings = settings
        self.toast = nil
        self.undo = nil
        self.pendingMove = nil
        self.today = today
        self.now = now ?? max(today, Date())
        self.listLimit = listLimit
        self.loaded = false
        self.nextToken = 1
        self.history = []
        self.historyMode = false
        self.historyFilter = .all
        self.query = ""
        self.suggestion = nil
        self.paywallShown = false
    }

    // MARK: Derived

    public func folder(_ kind: FolderKind) -> WatchedFolder? {
        folders.first { $0.kind == kind }
    }

    public var downloads: WatchedFolder? { folder(.downloads) }

    /// Folders added by the user (Pro), in the order they were added.
    public var customFolders: [WatchedFolder] { folders.filter { $0.kind.isCustom } }

    public var enabledFolderPaths: Set<String> {
        Set(folders.filter(\.enabled).map(\.path))
    }

    public var isPro: Bool { settings.proUnlocked }

    /// Rows the list can show: 20 in the free tier, more with Pro.
    public var effectiveListLimit: Int { isPro ? max(listLimit, Self.proListLimit) : listLimit }

    /// Everything the inbox could list: files in enabled folders (folders themselves only when
    /// the setting says so), newest first, before retention, the chips and the limit.
    public var inboxCandidates: [InboxFile] {
        let enabled = enabledFolderPaths
        return files.values
            .filter { enabled.contains($0.folder) && (settings.includeFolders || $0.kind != .folder) }
            .sorted(by: Self.newestFirst)
    }

    /// The inbox's files: candidates within the retention window and after the last
    /// "Clear list", newest first, before the chips and the limit.
    public var recentFiles: [InboxFile] {
        let oldest = now.addingTimeInterval(-settings.retention.seconds)
        let cleared = settings.listClearedAt
        return inboxCandidates.filter { file in
            file.addedAt >= oldest && (cleared.map { file.addedAt > $0 } ?? true)
        }
    }

    /// The one place that decides whether an inbox row is on screen: chip, Type menu and
    /// search are AND-combined. History rows use `HistoryFilter` and the search only.
    public static func matches(_ file: InboxFile, chip: FileFilter, type: TypeGroup?, query: String,
                               now: Date, today: Date, overrides: [String: TypeGroup] = [:],
                               typeLabels: [TypeGroup: String] = [:]) -> Bool {
        guard chip.matches(file, now: now, today: today) else { return false }
        if let type, file.typeGroup(overrides: overrides) != type { return false }
        return searchMatches(file, query: query, overrides: overrides, typeLabels: typeLabels)
    }

    /// Case-insensitive, trimmed. Matches the name, the extension (with or without the dot),
    /// the type group's name (English or as shown), or the source host.
    public static func searchMatches(_ file: InboxFile, query: String, overrides: [String: TypeGroup] = [:],
                                     typeLabels: [TypeGroup: String] = [:]) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        if file.name.lowercased().contains(needle) { return true }
        let ext = needle.hasPrefix(".") ? String(needle.dropFirst()) : needle
        if !ext.isEmpty && file.fileExtension == ext { return true }
        let group = file.typeGroup(overrides: overrides)
        if group != .other {
            if group.title.lowercased().contains(needle) || group.rawValue.contains(needle) { return true }
            if let label = typeLabels[group], label.lowercased().contains(needle) { return true }
        }
        if case .web(let host) = file.source, host.lowercased().contains(needle) { return true }
        return false
    }

    /// The inbox rows grouped for the section headers, in order, without empty sections. Only
    /// the All and Today chips group; 1h, Unread and a search show a flat list.
    public var inboxSections: [(section: InboxSection, files: [InboxFile])] {
        guard !historyMode, filter == .all || filter == .today, query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return []
        }
        var sections: [(section: InboxSection, files: [InboxFile])] = []
        for file in visibleFiles {
            let section = InboxSection.of(file, now: now, today: today)
            if sections.last?.section == section {
                sections[sections.count - 1].files.append(file)
            } else {
                sections.append((section, [file]))
            }
        }
        return sections
    }

    /// History rows: every recorded file (folders are left out), newest first, using the live
    /// file when it is still listed and a `missing` row when it is gone.
    public var historyFiles: [InboxFile] {
        history.lazy.filter { $0.kind != .folder }.map { $0.file(present: files[$0.id]) }
    }

    /// The rows on screen. The inbox applies the chip, the Type menu and the search; History
    /// applies its All / Available / Gone segment and the search. Both apply the list limit.
    public var visibleFiles: [InboxFile] {
        if historyMode {
            return Array(historyFiles
                .filter { historyFilter.matches($0) && Self.searchMatches($0, query: query, overrides: settings.typeOverrides, typeLabels: typeLabels) }
                .prefix(effectiveListLimit))
        }
        return Array(recentFiles
            .filter { Self.matches($0, chip: filter, type: typeFilter, query: query, now: now, today: today,
                                   overrides: settings.typeOverrides, typeLabels: typeLabels) }
            .prefix(effectiveListLimit))
    }

    /// How many inbox files a chip would show before the Type menu and the search.
    public func count(for chip: FileFilter) -> Int {
        recentFiles.filter { chip.matches($0, now: now, today: today) }.count
    }

    static func newestFirst(_ lhs: InboxFile, _ rhs: InboxFile) -> Bool {
        if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    public var visibleIDs: [FileID] { visibleFiles.map(\.id) }

    /// The watched folders hold more files than the list shows: the inbox ends with a
    /// "Show older files" row, which opens History (Pro) or the Pro sheet.
    public var hasOlderFiles: Bool {
        !historyMode && (recentFiles.count > effectiveListLimit || inboxCandidates.count > recentFiles.count)
    }

    /// The menu bar badge: unread files in the inbox, or nothing when the setting is off.
    public var badgeCount: Int {
        settings.showBadge ? recentFiles.filter { $0.unread && !$0.missing }.count : 0
    }

    public var unreadCount: Int { files.values.filter { $0.unread && !$0.missing }.count }

    /// Names that appear more than once among visible rows; those rows show their folder.
    public var duplicateNames: Set<String> {
        var seen: Set<String> = []
        var duplicates: Set<String> = []
        for file in visibleFiles {
            if !seen.insert(file.name).inserted { duplicates.insert(file.name) }
        }
        return duplicates
    }

    public var emptyState: EmptyState? {
        if historyMode {
            guard visibleFiles.isEmpty else { return nil }
            return historyFiles.isEmpty ? .historyEmpty : .noMatches
        }
        if let downloads, downloads.access == .denied { return .needsAccess }
        guard visibleFiles.isEmpty else { return nil }
        if recentFiles.isEmpty { return .nothingNew }
        // The search or the Type menu narrowed a non-empty chip to nothing.
        if !query.trimmingCharacters(in: .whitespaces).isEmpty || typeFilter != nil { return .noMatches }
        switch filter {
        case .all: return .nothingNew
        case .lastHour: return .nothingLastHour
        case .today: return .nothingToday
        case .unread: return .caughtUp
        }
    }

    /// Enabled rules for a trigger, in order; the first match wins.
    public func rule(for trigger: RuleTrigger, matching file: InboxFile) -> Rule? {
        guard isPro else { return nil }
        return settings.rules.first { $0.enabled && $0.trigger == trigger && $0.match.matches(file) }
    }

    public func file(_ id: FileID) -> InboxFile? { files[id] }
}
