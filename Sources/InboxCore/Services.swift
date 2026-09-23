import Foundation

/// A failure reported by a service, carried back into the loop as an event.
public struct ServiceError: Error, Equatable, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Everything the loop needs from the outside world. The presenter owns one implementation and
/// routes every `InboxEffect` to it; results come back as `Event`s.
///
/// The app provides `MacServices` (AppKit, file system, Carbon hotkeys). Tests and the headless
/// CLI use `FakeServices`, an in-memory world that answers synchronously.
@MainActor
public protocol InboxServices: AnyObject {
    // Persistence
    func loadSettings() -> (Settings, [WatchedFolder])
    func saveSettings(_ settings: Settings)

    // Folder watching. `sink` receives environment events (scanCompleted, fileArrived, ...).
    func startWatching(_ folders: [WatchedFolder], sink: @escaping @MainActor (Event) -> Void)
    func stopWatching(_ kind: FolderKind)
    func requestAccess(_ kind: FolderKind) async -> (AccessState, path: String?)

    // File actions
    func open(_ files: [InboxFile])
    func quickLook(_ files: [InboxFile])
    func reveal(_ files: [InboxFile])
    func copyToPasteboard(_ text: String)
    func chooseDestination() async -> String?
    func move(_ files: [InboxFile], to destination: String) async -> (succeeded: [FileID], failed: [FileID])
    func unzip(_ file: InboxFile) async -> Result<String, ServiceError>
    func trash(_ files: [InboxFile]) async -> Result<[TrashedItem], ServiceError>
    func restore(_ items: [TrashedItem]) async -> [InboxFile]
    func openFolder(_ path: String)

    // System integration
    func setLaunchAtLogin(_ enabled: Bool) async -> Result<Bool, ServiceError>
    func registerHotkey(_ hotkey: Hotkey)
    func showPanel()
    func hidePanel()
    func notify(_ file: InboxFile)
    func requestNotificationPermission()

    // Pro
    /// Folder panel for an extra folder to watch; the app keeps a security-scoped bookmark.
    func chooseFolder() async -> String?
    func loadHistory() -> [HistoryEntry]
    func saveHistory(_ history: [HistoryEntry])
    /// Whether the Pro purchase is owned, from the store's current entitlements.
    func proStatus() async -> Bool
    func purchasePro() async -> Result<Bool, ServiceError>
    func restorePurchases() async -> Result<Bool, ServiceError>
}
