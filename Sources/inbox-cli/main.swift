import Foundation
import InboxCore

// Presenter CLI. Drives Downtray' logic either headlessly in this process (default,
// against an in-memory file system) or attached to the running app through the debug bridge.
//
//   inbox-cli state                        print the current state
//   inbox-cli send "arrive a.pdf" hotkey   apply events in order, print the final state
//   inbox-cli send --trace ...             also print the state after every event
//   inbox-cli repl                         read one line per event from stdin, print state after each
//   inbox-cli bench [n]                    arrive n files, then focus/open/trash/undo each; print timings
//   inbox-cli events                       list the event grammar
//
// Session commands accepted by `send`/`repl` in both modes, besides the event grammar:
//   state          the current snapshot without sending an event
//   reset          fresh model, keeping settings and folders
//   settle         wait for in-flight effects (trash, move, unzip) to report back
//   dest <path>    answer the next "Move to…" panel with <path> instead of showing it
//   pick <path>    answer the next "Add Folder…" panel with <path> instead of showing it
//
// Flags: --compact (single-line JSON), --summary (one-line text), --trace,
//        --remote [host:port] (talk to a running app instead of a local presenter).

enum Output { case pretty, compact, summary }

struct Options {
    var output: Output = .pretty
    var trace = false
    var remote: String?
    var positional: [String] = []

    init(_ args: [String]) {
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--compact": output = .compact
            case "--summary": output = .summary
            case "--trace": trace = true
            case "--remote":
                if index + 1 < args.count, !args[index + 1].hasPrefix("--"), args[index + 1].contains(":") {
                    index += 1
                    remote = args[index]
                } else {
                    remote = "127.0.0.1:\(BridgeResponse.defaultPort)"
                }
            default: positional.append(arg)
            }
            index += 1
        }
    }
}

struct DriverError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
protocol AppDriver {
    var name: String { get }
    func state() throws -> Snapshot
    func send(_ line: String) async throws -> Snapshot
}

/// Headless: the presenter runs inside this process against `FakeServices`. No window, no app.
@MainActor
final class LocalDriver: AppDriver {
    let name = "local presenter"
    private let services = FakeServices()
    private let presenter: InboxPresenter

    init() {
        var model = InboxModel(folders: services.folders)
        model.today = Calendar.current.startOfDay(for: Date())
        presenter = InboxPresenter(model: model, services: services)
        presenter.start()
    }

    func state() -> Snapshot { presenter.model.snapshot }

    func send(_ line: String) async throws -> Snapshot {
        let request = line.trimmingCharacters(in: .whitespacesAndNewlines)
        switch request {
        case "state":
            return state()
        case "reset":
            presenter.resetKeepingEnvironment()
            return state()
        case "settle":
            await presenter.settle()
            return state()
        default:
            if request.hasPrefix("dest ") {
                services.nextDestination = String(request.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                return state()
            }
            if request.hasPrefix("pick ") {
                services.nextFolder = String(request.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                return state()
            }
            let event: Event
            do {
                event = try Event.parse(request, context: ParseContext(model: presenter.model))
            } catch {
                throw DriverError("\(error)")
            }
            do {
                try presenter.send(event)
            } catch {
                throw DriverError("\(error)")
            }
            // Fake services answer at once; waiting here keeps `trash` then `undo` honest.
            await presenter.settle()
            return state()
        }
    }
}

/// Attached: events go over a persistent TCP connection to the app's debug bridge.
@MainActor
final class RemoteDriver: AppDriver {
    let name: String
    private let socket: LineSocket

    init(address: String) throws {
        let parts = address.split(separator: ":")
        let host = parts.first.map(String.init) ?? "127.0.0.1"
        let port = parts.count > 1 ? UInt16(parts[1]) ?? BridgeResponse.defaultPort : BridgeResponse.defaultPort
        socket = try LineSocket(host: host, port: port)
        name = "remote app at \(host):\(port)"
    }

    func state() throws -> Snapshot { try request("state").snapshot }

    func send(_ line: String) async throws -> Snapshot {
        let response = try request(line)
        guard response.ok else { throw DriverError(response.error ?? "unknown error") }
        return response.snapshot
    }

    private func request(_ line: String) throws -> BridgeResponse {
        let reply = try socket.request(line)
        do { return try BridgeResponse.decode(reply) } catch { throw DriverError("bad response: \(reply)") }
    }
}

/// Minimal blocking line-oriented TCP client.
final class LineSocket {
    private let fd: Int32
    private var buffer: [UInt8] = []

    init(host: String, port: UInt16) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let list = result else {
            throw DriverError("cannot resolve \(host)")
        }
        defer { freeaddrinfo(list) }
        var descriptor: Int32 = -1
        var cursor: UnsafeMutablePointer<addrinfo>? = list
        while let info = cursor {
            descriptor = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if descriptor >= 0 {
                if connect(descriptor, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 { break }
                close(descriptor)
                descriptor = -1
            }
            cursor = info.pointee.ai_next
        }
        guard descriptor >= 0 else {
            throw DriverError("cannot connect to \(host):\(port). Is Downtray running as a debug build?")
        }
        fd = descriptor
    }

    deinit { close(fd) }

    func request(_ line: String) throws -> String {
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            guard written > 0 else { throw DriverError("write failed") }
            offset += written
        }
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { throw DriverError("connection closed") }
            buffer.append(contentsOf: chunk[..<count])
        }
    }
}

func render(_ snapshot: Snapshot, _ output: Output) -> String {
    switch output {
    case .pretty: return snapshot.json(pretty: true)
    case .compact: return snapshot.json(pretty: false)
    case .summary: return snapshot.summary
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1e3 + Double(duration.components.attoseconds) / 1e15
}

let options = Options(Array(CommandLine.arguments.dropFirst()))
let command = options.positional.first ?? "help"

let driver: AppDriver
do {
    driver = try options.remote.map { try RemoteDriver(address: $0) } ?? LocalDriver()
} catch {
    fail("\(error)")
}

do {
    switch command {
    case "state":
        print(render(try driver.state(), options.output))

    case "send":
        let lines = options.positional.dropFirst()
        guard !lines.isEmpty else { fail("send needs at least one event, e.g. send \"arrive a.pdf\" hotkey") }
        var last: Snapshot?
        for line in lines {
            do {
                last = try await driver.send(line)
                if options.trace { print("> \(line)"); print(render(last!, options.output)) }
            } catch {
                fail("\(line): \(error)")
            }
        }
        if !options.trace, let last { print(render(last, options.output)) }

    case "repl":
        // Persistent session: each line is an event, each response is the state after applying it.
        // Errors go to stderr and the unchanged state is printed so the caller always gets a snapshot.
        let output: Output = options.output == .pretty ? .compact : options.output
        print(render(try driver.state(), output))
        fflush(stdout)
        while let line = readLine() {
            do {
                print(render(try await driver.send(line), output))
            } catch {
                FileHandle.standardError.write(Data("error: \(error)\n".utf8))
                print(render(try driver.state(), output))
            }
            fflush(stdout)
        }

    case "bench":
        // The success loop from the spec, repeated: a file lands, hotkey, it is at the top,
        // act on it. Here: arrive n files, then for each one focus it, open it, trash it, undo.
        let count = options.positional.dropFirst().first.flatMap(Int.init) ?? 20
        _ = try await driver.send("reset")
        for index in 0..<count {
            _ = try await driver.send("arrive bench-\(index).pdf 12k example.com")
        }
        let opened = try await driver.send("hotkey")
        guard opened.panelOpen, opened.rows.count == min(count, 20) else { fail("panel did not open with the rows") }
        let clock = ContinuousClock()
        var perFile: [Double] = []
        let started = clock.now
        for row in opened.rows {
            let stepStart = clock.now
            let focused = try await driver.send("focus \(row.name)")
            guard focused.focused == row.id else { throw DriverError("\(row.name) not focused") }
            let openedRow = try await driver.send("open")
            guard openedRow.rows.first(where: { $0.id == row.id })?.unread == false else { throw DriverError("\(row.name) still unread") }
            let trashed = try await driver.send("trash")
            guard trashed.rows.contains(where: { $0.id == row.id }) == false else { throw DriverError("\(row.name) still listed") }
            let restored = try await driver.send("undo")
            guard restored.rows.contains(where: { $0.id == row.id }) else { throw DriverError("\(row.name) not restored") }
            perFile.append(milliseconds(stepStart.duration(to: clock.now)))
        }
        let total = started.duration(to: clock.now)
        let mean = perFile.reduce(0, +) / Double(max(perFile.count, 1))
        print(String(format: "%@: focus/open/trash/undo on %d files in %.3f ms (mean %.3f ms per file)",
                     driver.name, perFile.count, milliseconds(total), mean))

    case "events":
        for (command, description) in Event.grammar {
            print(command.padding(toLength: 34, withPad: " ", startingAt: 0), description)
        }
        print("")
        print("session:                           state | reset | settle | dest <path> | pick <path>")

    default:
        print("""
        inbox-cli: drive Downtray without a UI, or attached to the running app.

          state                        print the current state
          send <event> [<event> ...]   apply events in order and print the final state
          repl                         read one event per line from stdin, print state after each
          bench [n]                    arrive n files, act on each, print timings
          events                       list the event grammar

        flags: --compact  --summary  --trace  --remote [host:port]
        """)
    }
} catch {
    fail("\(error)")
}
