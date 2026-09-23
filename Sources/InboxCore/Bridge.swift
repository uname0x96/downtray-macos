import Foundation

/// Wire format for the attached presenter bridge.
///
/// Protocol: one request line per event using the `Event` grammar, or a session command
/// (`state`, `reset`, `settle`, `dest <path>`). Each response is one JSON line encoding a
/// `BridgeResponse`. The response is sent only after the running app has applied the new state,
/// so a reader can trust the snapshot it receives.
public struct BridgeResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let error: String?
    public let snapshot: Snapshot

    public init(ok: Bool, error: String?, snapshot: Snapshot) {
        self.ok = ok
        self.error = error
        self.snapshot = snapshot
    }

    public static let defaultPort: UInt16 = 8791

    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{\"ok\":false,\"error\":\"encoding failed\"}" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ line: String) throws -> BridgeResponse {
        try JSONDecoder().decode(BridgeResponse.self, from: Data(line.utf8))
    }
}
