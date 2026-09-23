import Foundation
import InboxCore

/// Watches one folder and reports arrivals, changes and removals as events.
///
/// A `DispatchSource` on the directory wakes a debounced rescan; the rescan diffs the listing
/// against the last one. New files are held back while they are still being written: partial
/// download extensions are ignored outright, and any other new file must keep the same size
/// for three polls 400 ms apart before it is reported as arrived.
///
/// Date added comes from `.addedToDirectoryDateKey` (the same value Spotlight exposes as
/// `kMDItemDateAdded`) and the source host from the `kMDItemWhereFroms` extended attribute, so
/// no Spotlight query is needed and the watcher works the same on every volume.
@MainActor
final class FolderWatcher {
    let kind: FolderKind
    let url: URL
    private let sink: @MainActor (Event) -> Void

    private var source: (any DispatchSourceFileSystemObject)?
    private var known: [FileID: InboxFile] = [:]
    private var settling: [FileID: Task<Void, Never>] = [:]
    private var rescan: Task<Void, Never>?

    static let partialExtensions: Set<String> = ["download", "crdownload", "part", "aria2", "tmp"]
    /// Names that are never a download: Office lock files and Windows folder metadata. Dotfiles
    /// (`.DS_Store` among them) are already left out by `skipsHiddenFiles`.
    static func isIgnoredName(_ name: String) -> Bool {
        name.hasPrefix("~$") || name.lowercased() == "desktop.ini"
    }
    static let settlePolls = 3
    static let settleInterval: Duration = .milliseconds(400)
    static let debounce: Duration = .milliseconds(150)
    /// Only this many newest files are reported on the first scan; the model lists 20 anyway.
    static let initialLimit = 200

    init(kind: FolderKind, url: URL, sink: @escaping @MainActor (Event) -> Void) {
        self.kind = kind
        self.url = url
        self.sink = sink
    }

    func start() throws {
        let listing = try Self.scan(url, isInitial: true)
        known = listing
        let newest = listing.values.sorted { $0.addedAt > $1.addedAt }.prefix(Self.initialLimit)
        sink(.scanCompleted(kind, Array(newest)))

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { throw ServiceError("Cannot watch \(url.path)") }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRescan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        rescan?.cancel()
        for task in settling.values { task.cancel() }
        settling = [:]
    }

    private func scheduleRescan() {
        rescan?.cancel()
        rescan = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.performRescan()
        }
    }

    private func performRescan() {
        guard let current = try? Self.scan(url, isInitial: false) else { return }

        for id in known.keys where current[id] == nil {
            known[id] = nil
            settling[id]?.cancel()
            settling[id] = nil
            sink(.fileRemoved(id))
        }

        for (id, file) in current {
            if let existing = known[id] {
                if settling[id] != nil { continue }
                if existing.addedAt != file.addedAt {
                    // Same path, new "added" date: the file was downloaded again over the old
                    // one. That is a new arrival (unread again, back at the top), not an edit.
                    settle(file)
                } else if existing.size != file.size || existing.modifiedAt != file.modifiedAt {
                    known[id] = file
                    sink(.fileChanged(file))
                }
            } else if settling[id] == nil {
                settle(file)
            }
        }
    }

    /// Waits until the file's size has been stable for three polls, then reports the arrival.
    private func settle(_ file: InboxFile) {
        settling[file.id] = Task { @MainActor [weak self] in
            var lastSize = file.size
            var stable = 0
            while stable < Self.settlePolls {
                try? await Task.sleep(for: Self.settleInterval)
                guard !Task.isCancelled else { return }
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else {
                    self?.settling[file.id] = nil
                    return
                }
                let size = (attributes[.size] as? Int64) ?? lastSize
                if size == lastSize { stable += 1 } else { stable = 0; lastSize = size }
            }
            guard let self else { return }
            settling[file.id] = nil
            guard var final = try? Self.describe(URL(fileURLWithPath: file.path), isInitial: false) else { return }
            final.size = lastSize
            known[file.id] = final
            sink(.fileArrived(final))
        }
    }

    // MARK: Listing

    private static let keys: [URLResourceKey] = [
        .addedToDirectoryDateKey, .contentModificationDateKey, .fileSizeKey,
        .isDirectoryKey, .isPackageKey, .isHiddenKey,
    ]

    private static func scan(_ url: URL, isInitial: Bool) throws -> [FileID: InboxFile] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )
        var result: [FileID: InboxFile] = [:]
        for item in contents {
            if partialExtensions.contains(item.pathExtension.lowercased()) { continue }
            if isIgnoredName(item.lastPathComponent) { continue }
            if let file = try? describe(item, isInitial: isInitial) { result[file.id] = file }
        }
        return result
    }

    private static func describe(_ item: URL, isInitial: Bool) throws -> InboxFile {
        let values = try item.resourceValues(forKeys: Set(keys))
        let isDirectory = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        let modified = values.contentModificationDate ?? Date()
        let added = values.addedToDirectoryDate ?? modified
        let kind = FileKind.forExtension(item.pathExtension, isDirectory: isDirectory && !isPackage)
        var source = FileSource.unknown
        if let host = whereFromHost(item) {
            source = .web(host: host)
        } else if !isInitial && item.deletingLastPathComponent().lastPathComponent == "Downloads"
                    && Date().timeIntervalSince(added) < 60 {
            // No where-froms and just landed in Downloads: most likely AirDrop.
            source = .airDrop
        }
        return InboxFile(
            path: item.path,
            size: Int64(values.fileSize ?? 0),
            addedAt: added,
            modifiedAt: modified,
            kind: kind,
            source: source
        )
    }

    /// Host of the first URL in `com.apple.metadata:kMDItemWhereFroms`, without "www.".
    private static func whereFromHost(_ item: URL) -> String? {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let length = getxattr(item.path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard getxattr(item.path, name, &buffer, length, 0, 0) == length else { return nil }
        guard let list = try? PropertyListSerialization.propertyList(from: Data(buffer), format: nil) as? [String] else {
            return nil
        }
        for entry in list {
            if let host = URL(string: entry)?.host, !host.isEmpty {
                return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
        }
        return nil
    }
}
