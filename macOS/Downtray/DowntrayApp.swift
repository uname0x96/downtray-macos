import AppKit
import os
import SwiftUI
import InboxCore

/// Accessory app (`LSUIElement`): no main window, a status item with a popover, and a standard
/// Settings scene. Everything the UI does goes through `InboxPresenter`; the views only send
/// events and render the model.
@main
struct DowntrayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(delegate.presenter)
        }
    }
}

/// Owns the status item, the popover and the presenter. This is the only place that knows both
/// AppKit windows and the loop.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, PanelController {
    let services = MacServices()
    let presenter: InboxPresenter

    private var statusItem: NSStatusItem?
    private var badgeView: StatusBadgeView?
    private let popover = NSPopover()
    private var hosting: PopoverHostingController?
    private var outsideClickMonitor: Any?
    #if DEBUG
    private var bridge: DebugBridge?
    #endif

    override init() {
        var model = InboxModel(folders: WatchedFolder.standard)
        // The search field matches the group names the user sees ("Bilder"), not only the
        // English ones the core knows.
        model.typeLabels = Dictionary(uniqueKeysWithValues: TypeGroup.allCases.map { ($0, $0.localizedTitle) })
        presenter = InboxPresenter(model: model, services: services)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One instance only. macOS stops the same bundle from launching twice, but two copies
        // at different paths (an Xcode run and a build from `.build`) both get a status item and
        // both fight over the debug bridge port. The newcomer hands over and quits, unless it is
        // the second half of `relaunch()`: then the old instance is on its way out, and this one
        // waits for it (the status item and the bridge port must be free) rather than quitting.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        let leaving = UserDefaults.standard.integer(forKey: Self.relaunchingKey)
        Self.log.info("launch pid \(ProcessInfo.processInfo.processIdentifier, privacy: .public) others=\(others.map(\.processIdentifier), privacy: .public) leaving=\(leaving, privacy: .public)")
        guard let other = others.first else { return finishLaunching() }
        guard other.processIdentifier == leaving else {
            other.activate()
            NSApp.terminate(nil)
            return
        }
        Task { @MainActor in
            for _ in 0..<30 where !other.isTerminated { try? await Task.sleep(for: .milliseconds(100)) }
            if !other.isTerminated {
                // It said it was leaving; a quit stuck behind a closing sheet gets a push.
                other.forceTerminate()
                for _ in 0..<20 where !other.isTerminated { try? await Task.sleep(for: .milliseconds(100)) }
            }
            Self.log.info("old instance \(other.processIdentifier, privacy: .public) terminated=\(other.isTerminated, privacy: .public)")
            if other.isTerminated {
                finishLaunching()
            } else {
                other.activate()
                NSApp.terminate(nil)
            }
        }
    }

    /// Defaults key holding the pid of an instance that is quitting in favor of the one it just
    /// launched. Shared through the container, unlike launch arguments, which LaunchServices
    /// does not deliver to a sandboxed app.
    private static let relaunchingKey = "relaunchingFromPID"
    private nonisolated static let log = Logger(subsystem: "app.downtray.mac", category: "launch")
    private nonisolated static let popoverLog = Logger(subsystem: "app.downtray.mac", category: "popover")

    private func finishLaunching() {
        UserDefaults.standard.removeObject(forKey: Self.relaunchingKey)
        services.panelController = self
        services.onHotkey = { [weak self] in self?.presenter.dispatch(.hotkeyPressed) }
        services.onNotificationOpen = { [weak self] path in self?.presenter.dispatch(.open(.files([path]))) }
        services.onFileVanished = { [weak self] id in self?.presenter.dispatch(.fileRemoved(id)) }
        setUpStatusItem()
        setUpPopover()
        presenter.start()
        observeBadge()
        #if DEBUG
        let bridge = DebugBridge(presenter: presenter, panel: self)
        bridge.start()
        self.bridge = bridge
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !presenter.model.panelOpen { presenter.dispatch(.hotkeyPressed) }
        return false
    }

    // MARK: Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.menuBarIcon
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked)
            // Right click too: a small menu, the only place an accessory app can offer Quit.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityIdentifier("statusItem")
        }
        statusItem = item
    }

    /// The glyph from the asset catalog, drawn as a template so macOS tints it for light and
    /// dark menu bars and for the pressed state.
    private static var menuBarIcon: NSImage? {
        let image = NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        image?.accessibilityDescription = appName
        return image
    }

    /// The status item is one more way to send the toggle; the model decides, the popover follows.
    /// One exception: a click on the status item while the popover is open closes it twice.
    /// The mouse-down lands outside the transient popover, so AppKit closes it and the delegate
    /// reports `panelClosed`; the mouse-up then fires this action, which would toggle it back
    /// open. `popoverDidClose` notes a close with the mouse over the button, and that one
    /// action is dropped.
    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closedByStatusItemClick = false
            showStatusMenu()
            return
        }
        if closedByStatusItemClick {
            closedByStatusItemClick = false
            return
        }
        presenter.dispatch(.hotkeyPressed)
    }

    private func showStatusMenu() {
        guard let button = statusItem?.button else { return }
        closePopover()
        let menu = NSMenu()
        let settings = NSMenuItem(title: String(localized: "menu.settings", defaultValue: "Settings…", comment: "Status item menu."), action: #selector(menuOpenSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "app.quit", defaultValue: "Quit Downtray"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func menuOpenSettings() { openSettings() }

    private var closedByStatusItemClick = false

    private var mouseIsOverStatusItem: Bool {
        guard let button = statusItem?.button, let window = button.window else { return false }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        return rect.contains(NSEvent.mouseLocation)
    }

    /// Re-runs whenever the badge count changes (Observation tracking).
    private func observeBadge() {
        withObservationTracking {
            renderBadge(presenter.model.badgeCount)
        } onChange: {
            Task { @MainActor [weak self] in self?.observeBadge() }
        }
    }

    /// The unread count is a small red disc on the glyph's lower right corner, like an app
    /// icon badge, so the item stays one compact glyph. It is an overlay view rather than part
    /// of the image so the glyph keeps its template tint.
    private func renderBadge(_ count: Int) {
        guard let button = statusItem?.button else { return }
        if badgeView == nil {
            let badge = StatusBadgeView()
            button.addSubview(badge)
            badgeView = badge
        }
        badgeView?.count = count
        if let badge = badgeView {
            let size = badge.intrinsicContentSize
            // Bottom-right of the glyph; the button is a little wider than the 18 pt image.
            badge.frame = CGRect(x: button.bounds.maxX - size.width - 2, y: 1, width: size.width, height: size.height)
            badge.autoresizingMask = [.minXMargin, .maxYMargin]
        }
        button.toolTip = count == 0
            ? appName
            : String(localized: "statusItem.unreadFiles", defaultValue: "\(count) unread files", comment: "Tooltip on the menu bar icon while the badge shows. Plural: 1 → '1 unread file'.")
    }

    // MARK: Popover

    private func setUpPopover() {
        let root = PopoverView(openSettings: { [weak self] in self?.openSettings() })
            .environment(presenter)
        let hosting = PopoverHostingController(rootView: AnyView(root))
        hosting.onWillPreview = { [weak self] in self?.popover.behavior = .applicationDefined }
        hosting.onPreviewEnded = { [weak self] in self?.popover.behavior = .transient }
        services.quickLookHost = hosting
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: 360, height: 520)
        popover.behavior = .transient
        // No animation: show and close then complete synchronously, so the popover is exactly
        // where the model says by the time an effect returns (a close requested during an
        // animated show is otherwise dropped, and the late `popoverDidShow` re-opens the model).
        popover.animates = false
        popover.delegate = self
        self.hosting = hosting
        // A transient popover closes on a click outside only while this app has no other
        // window. Once Settings has been opened, a click in another app deactivates Downtray
        // but AppKit leaves the popover on screen, so the deactivation closes it here. Quick
        // Look switches the behavior to `.applicationDefined` and is left alone.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeIfTransient("app resigned active") }
        }
        // Deactivation is not enough. The cooperative `activate()` in `showPopover` can be
        // refused, and then there is nothing to resign: a click in another app, or on a system
        // overlay that never activates anything (the screenshot thumbnail, a notification),
        // leaves the popover hanging over whatever the user is now doing. A global monitor
        // sees the mouse-down that went to the other app, and the workspace reports the app
        // that took over, so either one closes the popover.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.closeIfTransient("click in another app") }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.closeIfTransient("\(app?.bundleIdentifier ?? "?") activated") }
        }
    }

    /// The user is doing something outside the popover; close it unless Quick Look has it.
    private func closeIfTransient(_ reason: String) {
        guard popover.isShown else { return }
        Self.popoverLog.info("\(reason, privacy: .public): behavior=\(self.popover.behavior.rawValue, privacy: .public)")
        guard popover.behavior == .transient else { return }
        closePopover()
    }

    func showPopover() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        // The moment of opening: "1h", "Just now" and the day boundary all count from it.
        presenter.dispatch(.setToday(Date()))
        // A status-item click does not activate an accessory app, and the cooperative
        // `activate()` may be refused while another app is frontmost. Without activation the
        // popover window cannot become key, and the first click inside it is spent on that
        // instead of reaching the row.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = popover.contentViewController?.view.window {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(popover.contentViewController?.view)
        }
    }

    func closePopover() {
        // Quick Look belongs to the popover. A hotkey or a script hiding the panel while the
        // preview is up would otherwise leave an empty preview panel on screen.
        hosting?.endPreview()
        guard popover.isShown else { return }
        // `close()` rather than `performClose(nil)`: no close animation, so a hide followed at
        // once by a show (hotkey twice, a script) cannot interleave their delegate callbacks.
        popover.close()
    }

    var isPanelShown: Bool { popover.isShown }

    var statusItemFrame: CGRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return Self.flipped(window.convertToScreen(button.convert(button.bounds, to: nil)))
    }

    var panelFrame: CGRect? {
        guard popover.isShown, let window = popover.contentViewController?.view.window else { return nil }
        return Self.flipped(window.frame)
    }

    var panelContentView: NSView? { popover.isShown ? popover.contentViewController?.view : nil }

    /// AppKit screen coordinates have their origin at the bottom left of the main screen.
    private static func flipped(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    // Programmatic shows and hides are already in the model. The delegate only has two jobs:
    // report a close the user caused (click outside, Escape, another app activating), and
    // reconcile the popover if it ended up disagreeing with the model.
    func popoverDidShow(_ notification: Notification) {
        if !presenter.model.panelOpen { closePopover() }
    }

    func popoverDidClose(_ notification: Notification) {
        Self.popoverLog.info("popover closed; model panelOpen=\(self.presenter.model.panelOpen, privacy: .public)")
        guard presenter.model.panelOpen else { return }
        if mouseIsOverStatusItem {
            closedByStatusItemClick = true
            // If the mouse-up never reaches the button (the user dragged off it), the flag
            // must not swallow a later, unrelated click.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.closedByStatusItemClick = false
            }
        }
        presenter.dispatch(.panelClosed)
    }

    // MARK: Relaunch

    /// Starts a second instance and quits this one once it is running. Used after the language
    /// changed: Foundation picks the UI language at launch. The marker in defaults tells the new
    /// instance to wait for this one to exit instead of treating it as the instance to hand over to.
    static func relaunch() {
        UserDefaults.standard.set(ProcessInfo.processInfo.processIdentifier, forKey: relaunchingKey)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
            log.info("relaunch: new pid \(app?.processIdentifier ?? -1, privacy: .public) error=\(error.map { "\($0)" } ?? "none", privacy: .public)")
            guard error == nil else {
                UserDefaults.standard.removeObject(forKey: relaunchingKey)
                return
            }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    // MARK: Settings

    func openSettings() {
        closePopover()
        // An accessory app has to activate itself, or the window opens behind the front app.
        NSApp.activate(ignoringOtherApps: true)
        if let action = SettingsOpener.action {
            action()
        } else if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            // Pre-macOS 14 fallbacks; private selectors, so only tried when the action is missing.
            _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        let title = String(localized: "settings.title", defaultValue: "Downtray Settings", comment: "Window title. Keep the brand name.")
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.title == title }) {
            // The Settings scene comes with an empty unified toolbar, which pushes the title to
            // the left on macOS 26+. Without a toolbar the title is centered.
            window.toolbar = nil
            // The Pro badge sits at the trailing end of the title bar, not in a row of the form.
            // It is a title bar accessory rather than a toolbar item so the title stays centered.
            if window.titlebarAccessoryViewControllers.isEmpty {
                let badge = NSHostingView(rootView: ProBadge().environment(presenter))
                let accessory = NSTitlebarAccessoryViewController()
                accessory.layoutAttribute = .trailing
                accessory.view = badge
                window.addTitlebarAccessoryViewController(accessory)
            }
            // The accessory takes the size its view has when the window shows; the hosting
            // view is measured here so a purchase since the last visit is reflected.
            if let badge = window.titlebarAccessoryViewControllers.first?.view {
                // As tall as the title bar, so the capsule centers on the title instead of
                // sitting on the bar's bottom edge.
                let titleBarHeight = window.frame.height - window.contentLayoutRect.height
                badge.frame.size = CGSize(width: badge.fittingSize.width, height: max(titleBarHeight, badge.fittingSize.height))
            }
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// What the services need from the window layer to show or hide the panel.
@MainActor
protocol PanelController: AnyObject {
    func openSettings()
    func showPopover()
    func closePopover()
    var isPanelShown: Bool { get }
    /// Screen rectangles in top-left-origin coordinates (what `CGEvent` uses), for scripts
    /// that drive the app with real mouse clicks. Nil when not on screen.
    var statusItemFrame: CGRect? { get }
    var panelFrame: CGRect? { get }
    /// The popover's content view while it is on screen (its window is not in `NSApp.windows`).
    var panelContentView: NSView? { get }
}

/// The red unread badge over the status item's glyph. Draws nothing at zero and never takes
/// the click: mouse events fall through to the button.
final class StatusBadgeView: NSView {
    var count = 0 {
        didSet {
            isHidden = count == 0
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }
    }

    private var text: String { count > 99 ? "99+" : "\(count)" }
    private let font = NSFont.systemFont(ofSize: 8, weight: .bold)
    private let height: CGFloat = 12

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var intrinsicContentSize: NSSize {
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: max(height, ceil(width) + 6), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard count > 0 else { return }
        let pill = NSBezierPath(roundedRect: bounds, xRadius: height / 2, yRadius: height / 2)
        NSColor.systemRed.setFill()
        pill.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}
