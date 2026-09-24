import Foundation

/// An in-memory world for tests and the headless CLI. File actions succeed immediately, the
/// "watcher" reports whatever the test puts in `world`, and every call is recorded so a test can
/// assert what the app asked the system to do.
@MainActor
public final class FakeServices: InboxServices {
    /// Files the fake file system knows about, by path.
    public var world: [FileID: InboxFile] = [:]
    public var settings = Settings()
    public var folders: [WatchedFolder]
    public var accessGrants: [FolderKind: AccessState] = [.downloads: .granted]
    /// What the next "Move to…" panel answers. nil cancels.
    public var nextDestination: String?
    /// What the next folder panel ("Add Folder…", or "Change…" on the primary folder) answers.
    /// nil cancels the former and keeps the primary folder where it is.
    public var nextFolder: String?
    /// Whether the fake store owns Pro; `purchasePro` sets it unless `purchaseShouldFail`.
    public var proOwned = false
    public var purchaseShouldFail = false
    public private(set) var history: [HistoryEntry] = []
    public var launchAtLoginSupported = true
    public var trashShouldFail = false
    public var unzipShouldFail = false
    /// Everything the app asked for, in order, as short strings ("open a.pdf", "trash 2").
    public private(set) var log: [String] = []
    public var pasteboard: String?
    public private(set) var registeredHotkey: Hotkey?
    public private(set) var panelShown = false
    public private(set) var sink: (@MainActor (Event) -> Void)?
    private var trashCounter = 0

    public init(folders: [WatchedFolder] = WatchedFolder.sample()) {
        self.folders = folders
    }

    private func record(_ entry: String) { log.append(entry) }

    // MARK: Persistence

    public func loadSettings() -> (Settings, [WatchedFolder]) {
        record("loadSettings")
        var folders = self.folders
        for index in folders.indices {
            folders[index].access = accessGrants[folders[index].kind] ?? (folders[index].kind.isCustom ? .granted : .unknown)
        }
        return (settings, folders)
    }

    public func saveSettings(_ settings: Settings) {
        self.settings = settings
        record("saveSettings")
    }

    // MARK: Watching

    public func startWatching(_ folders: [WatchedFolder], sink: @escaping @MainActor (Event) -> Void) {
        self.sink = sink
        for folder in folders {
            record("watch \(folder.kind.rawValue)")
            let listing = world.values.filter { $0.folder == folder.path }.sorted { $0.addedAt < $1.addedAt }
            sink(.scanCompleted(folder.kind, listing))
        }
    }

    public func stopWatching(_ kind: FolderKind) {
        record("unwatch \(kind.rawValue)")
    }

    public func requestAccess(_ kind: FolderKind) async -> (AccessState, path: String?) {
        record("requestAccess \(kind.rawValue)")
        return (accessGrants[kind] ?? .denied, nextFolder)
    }

    /// Simulates a file landing in a watched folder.
    public func arrive(_ file: InboxFile) {
        world[file.id] = file
        sink?(.fileArrived(file))
    }

    /// Simulates a file being moved away by something else.
    public func vanish(_ id: FileID) {
        world[id] = nil
        sink?(.fileRemoved(id))
    }

    // MARK: File actions

    public func open(_ files: [InboxFile]) { record("open \(names(files))") }
    public func quickLook(_ files: [InboxFile]) { record("quicklook \(names(files))") }
    public func reveal(_ files: [InboxFile]) { record("reveal \(names(files))") }
    public func copyToPasteboard(_ text: String) { pasteboard = text; record("copy") }
    public func openFolder(_ path: String) { record("openFolder \((path as NSString).lastPathComponent)") }

    public func chooseDestination() async -> String? {
        record("chooseDestination")
        return nextDestination
    }

    public func move(_ files: [InboxFile], to destination: String) async -> (succeeded: [FileID], failed: [FileID]) {
        record("move \(names(files)) -> \((destination as NSString).lastPathComponent)")
        var succeeded: [FileID] = []
        for file in files {
            world[file.id] = nil
            var moved = file
            moved = InboxFile(path: destination + "/" + file.name, size: file.size, addedAt: file.addedAt,
                              modifiedAt: file.modifiedAt, kind: file.kind, source: file.source)
            world[moved.id] = moved
            succeeded.append(file.id)
        }
        return (succeeded, [])
    }

    public func unzip(_ file: InboxFile) async -> Result<String, ServiceError> {
        record("unzip \(file.name)")
        if unzipShouldFail { return .failure(ServiceError("Could not extract \(file.name)")) }
        let output = file.folder + "/" + (file.name as NSString).deletingPathExtension
        return .success(output)
    }

    public func trash(_ files: [InboxFile]) async -> Result<[TrashedItem], ServiceError> {
        record("trash \(names(files))")
        if trashShouldFail { return .failure(ServiceError("Could not move to Trash")) }
        return .success(files.map { file in
            trashCounter += 1
            world[file.id] = nil
            return TrashedItem(file: file, trashedPath: "/Users/sample/.Trash/\(trashCounter)-\(file.name)")
        })
    }

    public func restore(_ items: [TrashedItem]) async -> [InboxFile] {
        record("restore \(names(items.map(\.file)))")
        for item in items { world[item.file.id] = item.file }
        return items.map(\.file)
    }

    // MARK: System

    public func setLaunchAtLogin(_ enabled: Bool) async -> Result<Bool, ServiceError> {
        record("launchAtLogin \(enabled)")
        return launchAtLoginSupported ? .success(enabled) : .failure(ServiceError("Login items are unavailable"))
    }

    public func registerHotkey(_ hotkey: Hotkey) {
        registeredHotkey = hotkey
        record("hotkey \(hotkey.commandLine)")
    }

    public func showPanel() { panelShown = true; record("showPanel") }
    public func hidePanel() { panelShown = false; record("hidePanel") }
    public func notify(_ file: InboxFile) { record("notify \(file.name)") }
    public func requestNotificationPermission() { record("notificationPermission") }

    // MARK: Pro

    public func chooseFolder() async -> String? {
        record("chooseFolder")
        return nextFolder
    }

    public func loadHistory() -> [HistoryEntry] {
        record("loadHistory")
        return history
    }

    public func saveHistory(_ history: [HistoryEntry]) {
        self.history = history
    }

    public func proStatus() async -> Bool {
        record("proStatus")
        return proOwned
    }

    public func purchasePro() async -> Result<Bool, ServiceError> {
        record("purchasePro")
        if purchaseShouldFail { return .failure(ServiceError("Purchase cancelled")) }
        proOwned = true
        return .success(true)
    }

    public func restorePurchases() async -> Result<Bool, ServiceError> {
        record("restorePurchases")
        return .success(proOwned)
    }

    private func names(_ files: [InboxFile]) -> String {
        files.map(\.name).joined(separator: ",")
    }
}
