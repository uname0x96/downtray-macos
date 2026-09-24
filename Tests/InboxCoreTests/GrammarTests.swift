import Foundation
import Testing
@testable import InboxCore

@Suite struct GrammarTests {
    private var context: ParseContext {
        let m = model([file("a.pdf"), file("b.zip", minutesAgo: 1)])
        return ParseContext(model: m, now: today)
    }

    @Test func userCommandsRoundTripThroughTheirTextForm() throws {
        let lines = [
            "panel open", "panel close", "hotkey", "filter today", "select a.pdf", "select a.pdf toggle",
            "select b.zip range", "focus a.pdf", "up", "down", "deselect", "open", "open a.pdf b.zip", "ql a.pdf",
            "reveal", "copy a.pdf", "move", "unzip b.zip", "trash a.pdf", "undo", "dismiss a.pdf", "seen",
            "finder downloads", "folder change", "login off", "notify on", "language ja", "language system", "hotkey-set ctrl+alt+d",
            "filter 1h", "filter unread", "type docs", "type any", "type map foo docs", "type map foo none", "type reset",
            "copy-name a.pdf", "read a.pdf", "unread", "clear-list", "restore-list", "folders on", "keep month", "keep forever", "read-on-close on", "badge off",
            "older", "paywall off", "history gone", "forget a.pdf",
            "grant downloads", "unlock", "today 2026-09-23", "vanish b.zip",
        ]
        for line in lines {
            let event = try Event.parse(line, context: context)
            let again = try Event.parse(event.commandLine, context: context)
            #expect(again == event, "\(line) -> \(event.commandLine)")
        }
    }

    @Test func arriveBuildsAFileInTheRightFolder() throws {
        let web = try Event.parse("arrive invoice.pdf 120k stripe.com", context: context)
        guard case .fileArrived(let f) = web else { Issue.record("not an arrival"); return }
        #expect(f.path == downloads + "/invoice.pdf")
        #expect(f.size == 120 * 1024)
        #expect(f.source == .web(host: "stripe.com"))
        #expect(f.kind == .pdf)

        let dropped = try Event.parse("arrive \(scans)/photo.heic 2m airdrop", context: context)
        guard case .fileArrived(let d) = dropped else { Issue.record("not an arrival"); return }
        #expect(d.path == scans + "/photo.heic")
        #expect(d.source == .airDrop)
        #expect(d.kind == .image)
    }

    @Test func errorsAreSpecific() {
        #expect(throws: Event.ParseError.unknownCommand("fly")) { try Event.parse("fly", context: context) }
        #expect(throws: Event.ParseError.missingArgument("filter")) { try Event.parse("filter", context: context) }
        #expect(throws: Event.ParseError.invalidArgument("huge")) { try Event.parse("filter huge", context: context) }
        #expect(throws: Event.ParseError.unknownFile("c.txt")) { try Event.parse("open c.txt", context: context) }
        #expect(throws: Event.ParseError.empty) { try Event.parse("   ", context: context) }
    }

    @Test func hotkeysParseAndDisplay() {
        #expect(Hotkey.parse("ctrl+alt+d") == .default)
        #expect(Hotkey.default.display == "⌃⌥D")
        #expect(Hotkey.parse("cmd+shift+space")?.display == "⇧⌘Space")
        #expect(Hotkey.parse("d") == nil)          // no modifier
        #expect(Hotkey.parse("hyper+d") == nil)    // unknown modifier
        #expect(Hotkey.parse("cmd+💥") == nil)     // unknown key
        #expect(Hotkey.parse("control+option+f5")?.commandLine == "ctrl+alt+f5")
    }

    @Test func snapshotIsStableJSON() {
        let m = model([file("a.pdf", size: 2048, source: .web(host: "example.com"))], open: true)
        let snapshot = m.snapshot
        #expect(snapshot.rows.count == 1)
        #expect(snapshot.rows[0].source == "example.com")
        #expect(snapshot.rows[0].kind == "pdf")
        #expect(snapshot.settings.hotkey == "⌃⌥D")
        let decoded = try? JSONDecoder().decode(Snapshot.self, from: Data(snapshot.json().utf8))
        #expect(decoded == snapshot)
        #expect(snapshot.rows[0].type == "docs")
        #expect(snapshot.summary == "[open] all: 1 rows, 1 unread, badge 1")
    }

    @Test func bridgeResponseRoundTrips() throws {
        let response = BridgeResponse(ok: false, error: "nothing selected", snapshot: model().snapshot)
        #expect(try BridgeResponse.decode(response.json()) == response)
    }
}
