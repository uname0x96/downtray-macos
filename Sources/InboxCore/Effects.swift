import Foundation

/// Side effects the loop can ask for. The update function only names them; handlers live in
/// `InboxPresenter` behind the `InboxServices` protocol, so the update stays pure and testable.
public enum InboxEffect: Equatable, Sendable {
    /// The event did not apply. Mobius updates cannot throw, so rejection is an effect; the
    /// presenter turns it back into a typed error for `send`.
    case reject(EventError)

    case loadSettings
    case saveSettings(Settings)
    case startWatching([WatchedFolder])
    case stopWatching(FolderKind)
    case requestAccess(FolderKind)

    case openFiles([InboxFile])
    case quickLook([InboxFile])
    case reveal([InboxFile])
    case copyToPasteboard(String)
    case chooseDestination
    case move([InboxFile], to: String)
    case unzip(InboxFile)
    case trash(token: Int, [InboxFile])
    case restore(token: Int, [TrashedItem])
    case openFolder(String)

    case scheduleUndoExpiry(token: Int)
    case scheduleToastDismiss(token: Int)

    case setLaunchAtLogin(Bool)
    case registerHotkey(Hotkey)
    case showPanel
    case hidePanel
    case notify(InboxFile)
    case requestNotificationPermission

    // Pro
    case chooseFolder
    case loadHistory
    case saveHistory([HistoryEntry])
    case checkProStatus
    case purchasePro
    case restorePurchases
}
