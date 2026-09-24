import AppKit
import CryptoKit
import Quartz
import QuickLookThumbnailing
import SwiftUI
import InboxCore

/// The popover's root view. A click in a window that is not yet key normally only makes it
/// key; answering `acceptsFirstMouse` lets that same click reach the row (rule: one click,
/// one action, whatever the app was doing before).
final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Hosts the popover content and answers Quick Look's responder-chain handshake. While the
/// preview panel is up the popover must stay open, so the delegate switches its behavior.
final class PopoverHostingController: NSViewController, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    private var previewURLs: [URL] = []
    private let rootView: AnyView
    var onWillPreview: (() -> Void)?
    var onPreviewEnded: (() -> Void)?

    init(rootView: AnyView) {
        self.rootView = rootView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = FirstMouseHostingView(rootView: rootView)
    }

    func preview(_ urls: [URL]) {
        previewURLs = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        onWillPreview?()
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Closes the preview panel if this controller is showing it. Closing hands control back
    /// through `endPreviewPanelControl`, so the popover becomes transient again.
    func endPreview() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
              panel.isVisible, panel.dataSource === self else { return }
        panel.orderOut(nil)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        onPreviewEnded?()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURLs[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Arrow keys in the panel step through the items; everything else goes to the panel.
        false
    }
}

// MARK: - Thumbnails

/// Quick Look thumbnails with a memory cache and a disk cache capped at 100 MB.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let memory = NSCache<NSString, NSImage>()
    private let directory: URL
    private nonisolated static let capBytes: Int64 = 100 * 1024 * 1024
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = caches.appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 200
    }

    func thumbnail(for file: InboxFile, side: CGFloat) async -> NSImage? {
        let key = Self.key(for: file, side: side)
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let task = inFlight[key] { return await task.value }
        let task = Task<NSImage?, Never> { [directory] in
            let onDisk = directory.appendingPathComponent(key + ".png")
            if let image = NSImage(contentsOf: onDisk) { return image }
            guard let image = await Self.generate(path: file.path, side: side) else { return nil }
            Self.store(image, at: onDisk)
            Self.prune(directory)
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { memory.setObject(image, forKey: key as NSString) }
        return image
    }

    private static func key(for file: InboxFile, side: CGFloat) -> String {
        let text = "\(file.path)|\(file.modifiedAt.timeIntervalSince1970)|\(file.size)|\(Int(side))"
        return SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func generate(path: String, side: CGFloat) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .thumbnail
        )
        request.iconMode = false
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return representation.nsImage
        } catch {
            return nil
        }
    }

    private nonisolated static func store(_ image: NSImage, at url: URL) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url, options: .atomic)
    }

    /// Removes the least recently modified files once the cache exceeds the cap.
    private nonisolated static func prune(_ directory: URL) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return }
        var entries = items.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > capBytes else { return }
        entries.sort { $0.2 < $1.2 }
        for entry in entries where total > capBytes * 3 / 4 {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
    }
}

/// Finder icon at once, replaced by the Quick Look thumbnail when it is ready.
struct ThumbnailView: View {
    let file: InboxFile
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .task(id: "\(file.path)|\(file.modifiedAt.timeIntervalSince1970)") {
            guard !file.missing, file.kind != .folder else { return }
            thumbnail = await ThumbnailCache.shared.thumbnail(for: file, side: 36)
        }
    }
}
