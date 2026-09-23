#if DEBUG
import AppKit
import Foundation
import Network
import OSLog
import InboxCore

/// Attached presenter bridge, debug builds only. A persistent local connection forwards events
/// to the running app, each response waits for SwiftUI to apply the new state, and the UI still
/// updates on screen. This is what lets `inbox-cli --remote` and the shell scripts drive the
/// real app the same way they drive the headless presenter.
///
/// Protocol: one line per request, one JSON line per response (`BridgeResponse`).
/// Requests are `Event` grammar lines or one of the session commands:
///   state          return the current snapshot without sending an event
///   reset          fresh model, keeping settings and folders (re-scans the watched folders)
///   settle         wait (max 2 s) for in-flight effects to report back
///   dest <path>    answer the next "Move to…" panel with <path> instead of showing it
///   pick <path>    answer the next "Add Folder…" panel with <path> instead of showing it
///   settings       open the Settings window (what the gear button does)
///   windows        list visible windows (for checking that Settings opened)
///   frames         status item and popover rectangles, top-left origin, as JSON in `error`
/// Listens on 127.0.0.1 only. The debug entitlements add `network.server` for this.
@MainActor
final class DebugBridge {
    private let presenter: InboxPresenter
    private weak var panel: (any PanelController)?
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private nonisolated static let log = Logger(subsystem: "app.arrivals.mac", category: "bridge")

    init(presenter: InboxPresenter, panel: any PanelController) {
        self.presenter = presenter
        self.panel = panel
    }

    func start(port: UInt16 = BridgeResponse.defaultPort) {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredInterfaceType = .loopback
            // Bind to 127.0.0.1 explicitly: a wildcard bind can succeed on IPv6 while another
            // process already owns the IPv4 port, and every client then talks to that process.
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    Self.log.error("listener failed on port \(port): \(error.localizedDescription, privacy: .public)")
                default:
                    Self.log.info("listener \(String(describing: state), privacy: .public) on port \(port)")
                }
            }
            listener.newConnectionHandler = { connection in
                MainActor.assumeIsolated { self.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            Self.log.error("failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self.connections[key] = nil
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive(on: connection, pending: [])
    }

    private func receive(on connection: NWConnection, pending: [UInt8]) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            MainActor.assumeIsolated {
                var buffer = pending
                if let data { buffer.append(contentsOf: data) }
                Task { @MainActor in
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = String(decoding: buffer[..<newline], as: UTF8.self)
                        buffer.removeSubrange(...newline)
                        let response = await self.handle(line)
                        connection.send(content: Data((response + "\n").utf8), completion: .contentProcessed { _ in })
                    }
                    if isComplete || error != nil {
                        connection.cancel()
                        return
                    }
                    self.receive(on: connection, pending: buffer)
                }
            }
        }
    }

    private func handle(_ line: String) async -> String {
        let request = line.trimmingCharacters(in: .whitespacesAndNewlines)
        var failure: String?
        switch request {
        case "state":
            break
        case "reset":
            presenter.resetKeepingEnvironment()
            presenter.dispatch(.settingsLoaded(presenter.model.settings, folders: presenter.model.folders))
            await Self.waitForRender()
        case "settle":
            await presenter.settle(timeout: .seconds(2))
            if presenter.isBusy { failure = "still busy after 2 s (a panel may be waiting for a human)" }
            await Self.waitForRender()
        case "settings":
            panel?.openSettings()
            await Self.waitForRender()
        case "frames":
            func text(_ rect: CGRect?) -> String {
                guard let rect else { return "null" }
                return "{\"x\":\(Int(rect.minX)),\"y\":\(Int(rect.minY)),\"w\":\(Int(rect.width)),\"h\":\(Int(rect.height))}"
            }
            let json = "{\"statusItem\":\(text(panel?.statusItemFrame)),\"panel\":\(text(panel?.panelFrame))}"
            return BridgeResponse(ok: true, error: json, snapshot: presenter.model.snapshot).json()
        case "windows":
            let titles = NSApp.windows.filter(\.isVisible).map {
                "\(type(of: $0)):\($0.title)\($0.toolbar == nil ? "" : " [toolbar]")"
            }
            failure = nil
            return BridgeResponse(ok: true, error: titles.joined(separator: " | "), snapshot: presenter.model.snapshot).json()
        default:
            if request.hasPrefix("dest ") {
                (presenter.services as? MacServices)?.scriptedDestination =
                    String(request.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                break
            }
            if request.hasPrefix("pick ") {
                (presenter.services as? MacServices)?.scriptedFolder =
                    String(request.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                break
            }
            do {
                let event = try Event.parse(request, context: ParseContext(model: presenter.model))
                try presenter.send(event)
            } catch {
                failure = "\(error)"
            }
            await Self.waitForRender()
            await waitForPanelSync()
        }
        return BridgeResponse(ok: failure == nil, error: failure, snapshot: presenter.model.snapshot).json()
    }

    /// SwiftUI commits state changes on the next run loop turn. Waiting two turns means the
    /// response describes a state the view hierarchy has already picked up.
    private static func waitForRender() async {
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    /// Returns once the popover is shown or hidden as the model says (max 1 s), so a script can
    /// send the next command as soon as the panel is really there.
    private func waitForPanelSync() async {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            guard let panel else { return }
            if panel.isPanelShown == presenter.model.panelOpen { return }
            try? await Task.sleep(for: .milliseconds(16))
        }
        Self.log.info("panel did not sync with the model within 1 s")
    }
}
#endif
