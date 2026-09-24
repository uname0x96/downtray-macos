import Foundation

/// Everything that can happen to the app. User actions, agent commands and outcomes of effects
/// are all events, so there is exactly one way to change state.
public enum Event: Equatable, Sendable {
    // MARK: Environment (never rejected; the world is always allowed to report what it saw)

    /// The app (or CLI) started; asks for persisted settings once.
    case launched
    case settingsLoaded(Settings, folders: [WatchedFolder])
    case folderAccessChanged(FolderKind, AccessState, path: String?)
    /// The complete listing of one folder. Used for the first scan; existing files are not new.
    case scanCompleted(FolderKind, [InboxFile])
    case fileArrived(InboxFile)
    case fileChanged(InboxFile)
    case fileRemoved(FileID)
    case setToday(Date)
    case panelOpened
    case panelClosed

    // MARK: Panel

    case hotkeyPressed
    /// The chip row. Remembered in settings.
    case setFilter(FileFilter)
    /// The Type menu; nil is Any. Remembered in settings.
    case setTypeFilter(TypeGroup?)
    case select(FileID, SelectionMode)
    case focus(FileID)
    case moveFocus(FocusDirection)
    case clearSelection
    case markAllSeen
    /// Settings > Danger: files that arrived up to this moment leave the inbox (they stay on
    /// disk). Carries the clock because Settings is used while the panel, which refreshes
    /// `now`, may have been closed for hours.
    case clearList(Date)
    /// Settings > Danger: undoes "Clear List"; the files it hid are listed again.
    case restoreList
    case openWatchedFolder(FolderKind)
    case dismissToast
    /// The "Show older files" row: History with Pro, the Pro sheet without.
    case showOlderFiles
    case dismissPaywall

    // MARK: File actions

    case open(Target)
    case quickLook(Target)
    case reveal(Target)
    case copyPath(Target)
    case copyName(Target)
    case markRead(Target)
    case markUnread(Target)
    case moveTo(Target)
    case unzip(Target)
    case trash(Target)
    case undoTrash
    /// Removes a greyed-out row whose file vanished.
    case dismiss(FileID)

    // MARK: Outcomes of effects

    case destinationChosen(String)
    case moveCancelled
    case moved(succeeded: [FileID], failed: [FileID], destination: String)
    case unzipped(FileID, outputPath: String)
    case trashed(token: Int, items: [TrashedItem])
    case trashFailed(token: Int, message: String)
    case restored(token: Int, files: [InboxFile])
    case undoExpired(token: Int)
    case toastExpired(token: Int)
    case actionFailed(FileID?, message: String)
    case launchAtLoginChanged(Bool)
    case folderChosen(String)
    case folderChooserCancelled
    case historyLoaded([HistoryEntry])
    /// The store reported whether Pro is owned (after a purchase, a restore, or at launch).
    case proStatusChanged(Bool)
    case purchaseFailed(String)

    // MARK: Settings

    case setWatchDesktop(Bool)
    case setLaunchAtLogin(Bool)
    case setHotkey(Hotkey)
    case setNotifications(Bool)
    /// UI language; nil follows macOS. Takes effect at the next launch.
    case setLanguage(AppLanguage?)
    case setIncludeFolders(Bool)
    case setRetention(Retention)
    case setMarkReadOnClose(Bool)
    case setShowBadge(Bool)
    /// Maps an extension to a Type group; nil removes the override.
    case setTypeOverride(String, TypeGroup?)
    case resetTypeOverrides
    case grantAccess(FolderKind)
    case unlockPro
    case restorePurchases

    // MARK: Pro

    /// Asks the system for a folder to watch; the outcome is `folderChosen`.
    case addFolder
    case removeFolder(FolderKind)
    case setHistoryMode(Bool)
    case setHistoryFilter(HistoryFilter)
    case setQuery(String)
    case clearHistory
    /// The one action on a Gone history row: forget it.
    case removeFromHistory(FileID)
    case addRule(Rule)
    case updateRule(Rule)
    case removeRule(String)
    case acceptSuggestion
    case dismissSuggestion
}

/// Why a command did not apply. Typed so an agent can tell "nothing selected" from "no such
/// file" instead of guessing from an unchanged snapshot.
public enum EventError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownFile(FileID)
    case fileMissing(FileID)
    case nothingSelected
    case nothingToFocus
    case nothingToUndo
    case notAZip(FileID)
    case noPendingMove
    case unknownFolder(FolderKind)
    case folderNotWatched(FolderKind)
    case proRequired(ProFeature)
    case folderAlreadyWatched(String)
    case unknownRule(String)
    case duplicateRule(String)
    case noSuggestion
    case invalidExtension(String)

    public var description: String {
        switch self {
        case .unknownFile(let id): return "no file at '\(id)'"
        case .fileMissing(let id): return "'\((id as NSString).lastPathComponent)' is no longer in its folder"
        case .nothingSelected: return "nothing selected"
        case .nothingToFocus: return "no rows to focus"
        case .nothingToUndo: return "nothing to undo"
        case .notAZip(let id): return "'\((id as NSString).lastPathComponent)' is not a .zip archive"
        case .noPendingMove: return "no move in progress"
        case .unknownFolder(let kind): return "unknown folder \(kind.rawValue)"
        case .folderNotWatched(let kind): return "\(kind.title) is not being watched"
        case .proRequired(let feature): return "\(feature.title) needs Pro"
        case .folderAlreadyWatched(let path): return "'\((path as NSString).lastPathComponent)' is already watched"
        case .unknownRule(let name): return "no rule named '\(name)'"
        case .duplicateRule(let name): return "a rule named '\(name)' already exists"
        case .noSuggestion: return "no suggestion to act on"
        case .invalidExtension(let ext): return "'\(ext)' is not a file extension"
        }
    }
}
