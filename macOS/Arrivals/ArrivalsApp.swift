import AppKit
import SwiftUI
import InboxCore

/// Accessory app (`LSUIElement`): no main window, a status item with a popover, and a standard
/// Settings scene. Everything the UI does goes through `InboxPresenter`; the views only send
/// events and render the model.
@main
struct ArrivalsApp: App {
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
    private let popover = NSPopover()
    private var hosting: PopoverHostingController?
    #if DEBUG
    private var bridge: DebugBridge?
    #endif

    override init() {
        presenter = InboxPresenter(model: InboxModel(folders: WatchedFolder.standard), services: services)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One instance only. macOS stops the same bundle from launching twice, but two copies
        // at different paths (an Xcode run and a build from `.build`) both get a status item and
        // both fight over the debug bridge port. The newcomer hands over and quits.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let other = others.first {
            other.activate()
            NSApp.terminate(nil)
            return
        }
        services.panelController = self
        services.onHotkey = { [weak self] in self?.presenter.dispatch(.hotkeyPressed) }
        services.onNotificationOpen = { [weak self] path in self?.presenter.dispatch(.open(.files([path]))) }
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
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
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
        image?.accessibilityDescription = "Arrivals"
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
        let settings = NSMenuItem(title: String(localized: "Settings…"), action: #selector(menuOpenSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Quit Arrivals"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

    private func renderBadge(_ count: Int) {
        guard let button = statusItem?.button else { return }
        button.title = count == 0 ? "" : (count > 9 ? "9+" : "\(count)")
        button.toolTip = count == 0 ? "Arrivals" : "\(count) new file\(count == 1 ? "" : "s")"
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
    }

    func showPopover() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        presenter.dispatch(.setToday(Calendar.current.startOfDay(for: Date())))
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
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.title.localizedCaseInsensitiveContains("settings") }) {
            // The Settings scene comes with an empty unified toolbar, which pushes the title to
            // the left on macOS 26+. Without a toolbar the title is centered.
            window.toolbar = nil
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
}
