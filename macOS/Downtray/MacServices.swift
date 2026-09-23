import AppKit
import OSLog
import ServiceManagement
import StoreKit
import UserNotifications
import InboxCore

/// The real world: file system, Finder, Quick Look, login items, hotkeys, notifications.
/// Every method is one effect; results go back to the loop as events through the presenter.
@MainActor
final class MacServices: InboxServices {
    weak var panelController: (any PanelController)?
    weak var quickLookHost: PopoverHostingController?
    var onHotkey: (() -> Void)?
    var onNotificationOpen: ((FileID) -> Void)?
    #if DEBUG
    /// Set by the debug bridge so a script can answer the "Move to…" panel without a human.
    var scriptedDestination: String?
    /// Same for the "Add Folder…" panel (used once, then cleared).
    var scriptedFolder: String?
    #endif

    private let defaults = UserDefaults.standard
    private nonisolated static let log = Logger(subsystem: "app.downtray.mac", category: "services")
    private var watchers: [FolderKind: FolderWatcher] = [:]
    private let hotkeys = HotkeyCenter()
    private let notifications = NotificationRelay()
    /// Security-scoped URLs currently being accessed, per folder (Desktop; Downloads if re-granted).
    private var scopedURLs: [FolderKind: URL] = [:]

    private enum Keys {
        static let settings = "settings"
        static let bookmarks = "folderBookmarks"
        static let destinations = "destinationBookmarks"
        static let appleLanguages = "AppleLanguages"
    }

    /// The one-time Pro purchase (App Store Connect product id).
    static let proProductID = "app.downtray.mac.pro"
    /// Destinations (rule targets, "Move to…" folders) whose security scope is open.
    private var scopedDestinations: [String: URL] = [:]

    init() {
        notifications.onOpen = { [weak self] path in self?.onNotificationOpen?(path) }
        hotkeys.onPress = { [weak self] in self?.onHotkey?() }
    }

    // MARK: Persistence

    func loadSettings() -> (Settings, [WatchedFolder]) {
        var settings = Settings()
        if let data = defaults.data(forKey: Keys.settings),
           let stored = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = stored
        }
        // The system is the source of truth for the login item.
        settings.launchAtLogin = SMAppService.mainApp.status == .enabled
        // A per-app language chosen in System Settings shows up in the picker as well.
        if settings.language == nil, let override = languageOverride { settings.language = override }

        var folders = WatchedFolder.standard
        for index in folders.indices {
            let kind = folders[index].kind
            if let url = resolveBookmark(for: kind) {
                folders[index].path = url.path
                folders[index].access = .granted
            } else {
                folders[index].access = kind == .downloads
                    ? (Self.isReadable(folders[index].path) ? .granted : .denied)
                    : .unknown
            }
        }
        // Pro folders: watchable only while their bookmark still resolves.
        for path in settings.extraFolders {
            let resolved = resolveBookmark(for: .custom(path)) != nil || Self.isReadable(path)
            folders.append(.custom(path, access: resolved ? .granted : .denied))
        }
        return (settings, folders)
    }

    func saveSettings(_ settings: Settings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Keys.settings)
        }
        // Foundation reads `AppleLanguages` from the app's defaults at launch; System Settings >
        // Language & Region > Applications writes the same key, so both routes agree.
        if let language = settings.language {
            defaults.set([language.rawValue], forKey: Keys.appleLanguages)
        } else {
            defaults.removeObject(forKey: Keys.appleLanguages)
        }
    }

    /// The language System Settings (or an earlier save) put in the app's own defaults domain.
    /// `object(forKey:)` would fall through to the global list of system languages.
    private var languageOverride: AppLanguage? {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let languages = defaults.persistentDomain(forName: bundleID)?[Keys.appleLanguages] as? [String],
              let first = languages.first else { return nil }
        return AppLanguage(rawValue: String(first.prefix(2)))
    }

    private static func isReadable(_ path: String) -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: path)
            return true
        } catch {
            log.error("cannot list \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: Bookmarks (security-scoped)

    private var bookmarks: [String: Data] {
        get { defaults.dictionary(forKey: Keys.bookmarks) as? [String: Data] ?? [:] }
        set { defaults.set(newValue, forKey: Keys.bookmarks) }
    }

    private func resolveBookmark(for kind: FolderKind) -> URL? {
        if let url = scopedURLs[kind] { return url }
        guard let data = bookmarks[kind.rawValue] else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope]) {
            var all = bookmarks
            all[kind.rawValue] = fresh
            bookmarks = all
        }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        scopedURLs[kind] = url
        return url
    }

    private func storeBookmark(_ url: URL, for kind: FolderKind) {
        guard let data = try? url.bookmarkData(options: [.withSecurityScope]) else { return }
        var all = bookmarks
        all[kind.rawValue] = data
        bookmarks = all
        scopedURLs[kind]?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        scopedURLs[kind] = url
    }

    // MARK: Watching

    func startWatching(_ folders: [WatchedFolder], sink: @escaping @MainActor (Event) -> Void) {
        for folder in folders {
            watchers[folder.kind]?.stop()
            let url = resolveBookmark(for: folder.kind) ?? URL(fileURLWithPath: folder.path)
            let watcher = FolderWatcher(kind: folder.kind, url: url, sink: sink)
            do {
                try watcher.start()
                watchers[folder.kind] = watcher
            } catch {
                Self.log.error("cannot watch \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                sink(.folderAccessChanged(folder.kind, .denied, path: nil))
            }
        }
    }

    func stopWatching(_ kind: FolderKind) {
        watchers[kind]?.stop()
        watchers[kind] = nil
    }

    func requestAccess(_ kind: FolderKind) async -> (AccessState, path: String?) {
        let standard = WatchedFolder.standard.first { $0.kind == kind }?.path
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = String(localized: "access.prompt", defaultValue: "Grant Access", comment: "Folder picker button. Keep short.")
        panel.message = String(localized: "access.message", defaultValue: "Downtray needs access to your \(kind.localizedTitle) folder to list new files.", comment: "Folder picker heading. Placeholder: Downloads or Desktop. Keep the brand name.")
        if let standard { panel.directoryURL = URL(fileURLWithPath: standard) }
        NSApp.activate()
        let response = await panel.begin()
        guard response == .OK, let url = panel.url else { return (.denied, nil) }
        storeBookmark(url, for: kind)
        return (.granted, url.path)
    }

    // MARK: File actions

    func open(_ files: [InboxFile]) {
        // Quarantined files go through Gatekeeper as they would from Finder.
        for file in files { NSWorkspace.shared.open(URL(fileURLWithPath: file.path)) }
    }

    func quickLook(_ files: [InboxFile]) {
        quickLookHost?.preview(files.map { URL(fileURLWithPath: $0.path) })
    }

    func reveal(_ files: [InboxFile]) {
        NSWorkspace.shared.activateFileViewerSelecting(files.map { URL(fileURLWithPath: $0.path) })
    }

    func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func openFolder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func chooseDestination() async -> String? {
        #if DEBUG
        if let scripted = scriptedDestination { return scripted }
        #endif
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "move.prompt", defaultValue: "Move", comment: "Folder picker button. Keep short.")
        panel.message = String(localized: "move.message", defaultValue: "Choose where to move the selected files.", comment: "Folder picker heading.")
        NSApp.activate()
        let response = await panel.begin()
        guard response == .OK, let url = panel.url else { return nil }
        rememberDestination(url)
        return url.path
    }

    /// Reopens the security scope of a remembered destination (a rule target, or a folder
    /// picked in an earlier session). Returns nil when there is no bookmark for it.
    private func accessDestination(_ path: String) -> URL? {
        if let url = scopedDestinations[path] { return url }
        guard let stored = defaults.dictionary(forKey: Keys.destinations) as? [String: Data],
              let data = stored[path] else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        scopedDestinations[path] = url
        return url
    }

    /// Keeps a security-scoped bookmark for each destination so later moves to the same folder
    /// do not need a new grant. Static so the rule editor (no presenter access) can use it too.
    static func rememberDestination(_ url: URL, in defaults: UserDefaults = .standard) {
        guard let data = try? url.bookmarkData(options: [.withSecurityScope]) else { return }
        var stored = defaults.dictionary(forKey: Keys.destinations) as? [String: Data] ?? [:]
        stored[url.path] = data
        if stored.count > 50, let oldest = stored.keys.sorted().first { stored[oldest] = nil }
        defaults.set(stored, forKey: Keys.destinations)
    }

    private func rememberDestination(_ url: URL) { Self.rememberDestination(url, in: defaults) }

    func move(_ files: [InboxFile], to destination: String) async -> (succeeded: [FileID], failed: [FileID]) {
        let folder = accessDestination(destination) ?? URL(fileURLWithPath: destination, isDirectory: true)
        var succeeded: [FileID] = []
        var failed: [FileID] = []
        for file in files {
            let source = URL(fileURLWithPath: file.path)
            let target = Self.uniqueURL(folder.appendingPathComponent(file.name))
            do {
                try FileManager.default.moveItem(at: source, to: target)
                succeeded.append(file.id)
            } catch {
                failed.append(file.id)
            }
        }
        return (succeeded, failed)
    }

    func unzip(_ file: InboxFile) async -> Result<String, ServiceError> {
        let archive = URL(fileURLWithPath: file.path)
        let output = Self.uniqueURL(archive.deletingPathExtension())
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        } catch {
            return .failure(ServiceError(String(localized: "error.createFolder", defaultValue: "Could not create \(output.lastPathComponent)", comment: "Error toast. Placeholder: folder name.")))
        }
        // `ditto` preserves resource forks and permissions the way Finder's Archive Utility does.
        // It runs inside the app's sandbox, so it can only write where the app can.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, output.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
        if status == 0 { return .success(output.path) }
        try? FileManager.default.removeItem(at: output)
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(ServiceError(message.isEmpty ? String(localized: "error.extract", defaultValue: "Could not extract \(file.name)", comment: "Error toast. Placeholder: archive name.") : message))
    }

    func trash(_ files: [InboxFile]) async -> Result<[TrashedItem], ServiceError> {
        var items: [TrashedItem] = []
        for file in files {
            var trashedURL: NSURL?
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: &trashedURL)
                items.append(TrashedItem(file: file, trashedPath: trashedURL?.path ?? ""))
            } catch {
                // All or nothing: put back what was already moved so the rows match the disk.
                for item in items {
                    try? FileManager.default.moveItem(atPath: item.trashedPath, toPath: item.file.path)
                }
                return .failure(ServiceError(String(localized: "error.trash", defaultValue: "Could not move \(file.name) to the Trash", comment: "Error toast. Placeholder: file name.")))
            }
        }
        return .success(items)
    }

    func restore(_ items: [TrashedItem]) async -> [InboxFile] {
        var restored: [InboxFile] = []
        for item in items where !item.trashedPath.isEmpty {
            if (try? FileManager.default.moveItem(atPath: item.trashedPath, toPath: item.file.path)) != nil {
                restored.append(item.file)
            }
        }
        return restored
    }

    private static func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var counter = 2
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    // MARK: System

    func setLaunchAtLogin(_ enabled: Bool) async -> Result<Bool, ServiceError> {
        let service = SMAppService.mainApp
        do {
            if enabled { try service.register() } else { try await service.unregister() }
        } catch {
            return .failure(ServiceError(error.localizedDescription))
        }
        if enabled && service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        return .success(service.status == .enabled)
    }

    func registerHotkey(_ hotkey: Hotkey) {
        hotkeys.register(hotkey)
    }

    func showPanel() { panelController?.showPopover() }
    func hidePanel() { panelController?.closePopover() }

    func notify(_ file: InboxFile) {
        notifications.enqueue(file)
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: Pro

    func chooseFolder() async -> String? {
        #if DEBUG
        if let scripted = scriptedFolder {
            scriptedFolder = nil
            return scripted
        }
        #endif
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "watch.prompt", defaultValue: "Watch", comment: "Folder picker button. Keep short.")
        panel.message = String(localized: "watch.message", defaultValue: "Choose a folder to watch. New files landing there will show up in the inbox.", comment: "Folder picker heading.")
        NSApp.activate(ignoringOtherApps: true)
        let response = await panel.begin()
        guard response == .OK, let url = panel.url else { return nil }
        storeBookmark(url, for: .custom(url.path))
        return url.path
    }

    private var historyURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = support.appendingPathComponent("Downtray", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("history.json")
    }

    func loadHistory() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    func saveHistory(_ history: [HistoryEntry]) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }

    /// The store's current entitlements decide; the saved flag is only a cache for the UI.
    func proStatus() async -> Bool {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == Self.proProductID,
               transaction.revocationDate == nil {
                return true
            }
        }
        return false
    }

    func purchasePro() async -> Result<Bool, ServiceError> {
        do {
            guard let product = try await Product.products(for: [Self.proProductID]).first else {
                return .failure(ServiceError(String(localized: "pro.error.unavailable", defaultValue: "Pro is not available in this build.", comment: "Purchase error when the store has no product.")))
            }
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    return .failure(ServiceError(String(localized: "pro.error.unverified", defaultValue: "The purchase could not be verified.", comment: "Purchase error.")))
                }
                await transaction.finish()
                return .success(true)
            case .userCancelled:
                return .failure(ServiceError(String(localized: "pro.error.cancelled", defaultValue: "Purchase cancelled.", comment: "Shown when the user closes the purchase sheet.")))
            case .pending:
                return .failure(ServiceError(String(localized: "pro.error.pending", defaultValue: "The purchase is waiting for approval.", comment: "Purchase needs Ask to Buy approval.")))
            @unknown default:
                return .failure(ServiceError(String(localized: "pro.error.incomplete", defaultValue: "The purchase did not complete.", comment: "Purchase error.")))
            }
        } catch {
            return .failure(ServiceError(error.localizedDescription))
        }
    }

    func restorePurchases() async -> Result<Bool, ServiceError> {
        do {
            try await AppStore.sync()
        } catch {
            return .failure(ServiceError(error.localizedDescription))
        }
        let owned = await proStatus()
        return owned ? .success(true) : .failure(ServiceError(String(localized: "pro.error.notFound", defaultValue: "No Pro purchase found for this Apple Account.", comment: "Restore Purchases found nothing. 'Apple Account' is Apple's term.")))
    }

    /// Localized price of the Pro product, for the settings button; nil until the store answers.
    func proPrice() async -> String? {
        try? await Product.products(for: [Self.proProductID]).first?.displayPrice
    }
}

/// One banner per burst: arrivals within 3 s collapse into a single notification whose title is
/// the latest file name and whose "Open" action opens it.
@MainActor
final class NotificationRelay: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((FileID) -> Void)?
    private var burst: [InboxFile] = []
    private var timer: Task<Void, Never>?
    private static let category = "newFile"
    private static let openAction = "open"

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: Self.openAction, title: String(localized: "notification.open", defaultValue: "Open", comment: "Button on a notification."), options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [open], intentIdentifiers: [], options: []),
        ])
    }

    func enqueue(_ file: InboxFile) {
        burst.append(file)
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        guard let latest = burst.last else { return }
        let content = UNMutableNotificationContent()
        content.title = latest.name
        content.body = burst.count == 1
            ? String(localized: "notification.newIn", defaultValue: "New in \(latest.folderName)", comment: "Notification body. Placeholder: folder name.")
            : String(localized: "notification.more", defaultValue: "and \(burst.count - 1) more new files", comment: "Notification body under the newest file's name. Placeholder: how many others arrived. Plural: 1 → 'and 1 more new file'.")
        content.categoryIdentifier = Self.category
        content.userInfo = ["path": latest.path]
        burst = []
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let path = response.notification.request.content.userInfo["path"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            guard let path, action == Self.openAction || action == UNNotificationDefaultActionIdentifier else { return }
            onOpen?(path)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
