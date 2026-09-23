import Foundation
import Testing
@testable import InboxCore

/// The presenter wires the reducer to services through Mobius. These tests check the wiring:
/// effects reach the fake services, their outcomes come back as events, and `send` reports
/// rejections synchronously.
@MainActor
@Suite struct PresenterTests {
    private func makePresenter(files: [InboxFile] = []) -> (InboxPresenter, FakeServices) {
        let services = FakeServices()
        for file in files { services.world[file.id] = file }
        let presenter = InboxPresenter(model: InboxModel(folders: services.folders, today: today), services: services)
        presenter.start()
        return (presenter, services)
    }

    @Test func startLoadsSettingsAndScansWatchedFolders() {
        let (presenter, services) = makePresenter(files: [file("old.pdf")])
        #expect(presenter.model.loaded)
        #expect(presenter.model.visibleFiles.map(\.name) == ["old.pdf"])
        #expect(presenter.model.unreadCount == 0)
        // Mobius does not order sibling effects; `proStatus` is asynchronous and lands later.
        #expect(Set(services.log.prefix(4)) == ["loadSettings", "watch downloads", "hotkey ctrl+alt+d", "loadHistory"], "\(services.log)")
        #expect(services.registeredHotkey == .default)
    }

    @Test func sendReturnsTheNewModelAndThrowsTypedErrors() throws {
        let (presenter, _) = makePresenter()
        let model = try presenter.send(.fileArrived(file("a.pdf")))
        #expect(model.badgeCount == 1)
        #expect(throws: EventError.nothingSelected) { try presenter.send(.open(.selection)) }
        #expect(presenter.lastError == .nothingSelected)
        _ = try presenter.send(.panelOpened)
        #expect(presenter.lastError == nil)
    }

    @Test func watcherEventsFlowIntoTheLoop() {
        let (presenter, services) = makePresenter()
        services.arrive(file("a.pdf"))
        #expect(presenter.model.visibleFiles.map(\.name) == ["a.pdf"])
        #expect(presenter.model.badgeCount == 1)
        services.vanish(downloads + "/a.pdf")
        #expect(presenter.model.files[downloads + "/a.pdf"] == nil)
    }

    @Test func trashUndoRoundTripsThroughTheFakeFileSystem() async throws {
        let a = file("a.pdf")
        let (presenter, services) = makePresenter(files: [a])
        try presenter.send(.hotkeyPressed)
        try presenter.send(.trash(.files([a.id])))
        #expect(presenter.model.undo?.ready == false)
        await presenter.settle()
        #expect(presenter.model.undo?.ready == true)
        #expect(services.world[a.id] == nil)
        try presenter.send(.undoTrash)
        await presenter.settle()
        #expect(presenter.model.visibleFiles.map(\.name) == ["a.pdf"])
        #expect(services.world[a.id] != nil)
        #expect(services.log.suffix(2) == ["trash a.pdf", "restore a.pdf"])
    }

    @Test func undoExpiresOnTheClock() async throws {
        let a = file("a.pdf")
        let services = FakeServices()
        services.world[a.id] = a
        let clock = TestClock()
        let presenter = InboxPresenter(model: InboxModel(folders: services.folders, today: today), services: services, clock: clock)
        presenter.start()
        try presenter.send(.trash(.files([a.id])))
        await presenter.settle()
        #expect(presenter.model.undo?.ready == true)
        await clock.advance(by: .seconds(InboxReducer.undoSeconds))
        // Timers are not tracked by `settle`; the woken task dispatches on its next turn.
        #expect(await eventually { presenter.model.undo == nil })
    }

    @Test func moveUsesTheChosenDestination() async throws {
        let a = file("a.pdf")
        let (presenter, services) = makePresenter(files: [a])
        services.nextDestination = "/Users/sample/Documents/Invoices"
        try presenter.send(.moveTo(.files([a.id])))
        await presenter.settle()
        #expect(presenter.model.files.isEmpty)
        #expect(presenter.model.toast?.message == "Moved a.pdf to Invoices")
        #expect(services.world.keys.contains("/Users/sample/Documents/Invoices/a.pdf"))

        services.nextDestination = nil
        services.arrive(file("b.pdf"))
        try presenter.send(.moveTo(.files([downloads + "/b.pdf"])))
        await presenter.settle()
        #expect(presenter.model.pendingMove == nil)
        #expect(presenter.model.files.count == 1)
    }

    @Test func failedUnzipBecomesAnErrorToast() async throws {
        let z = file("a.zip")
        let (presenter, services) = makePresenter(files: [z])
        services.unzipShouldFail = true
        try presenter.send(.unzip(.files([z.id])))
        await presenter.settle()
        #expect(presenter.model.toast?.isError == true)
    }

    @Test func launchAtLoginReflectsWhatTheSystemDid() async throws {
        let (presenter, services) = makePresenter()
        try presenter.send(.setLaunchAtLogin(true))
        await presenter.settle()
        #expect(presenter.model.settings.launchAtLogin)
        #expect(services.settings.launchAtLogin)
        services.launchAtLoginSupported = false
        try presenter.send(.setLaunchAtLogin(false))
        await presenter.settle()
        #expect(presenter.model.settings.launchAtLogin)
        #expect(presenter.model.toast?.isError == true)
    }

    @Test func resetKeepsEnvironmentAndDropsFiles() throws {
        let (presenter, _) = makePresenter(files: [file("a.pdf")])
        try presenter.send(.setHotkey(Hotkey.parse("cmd+d")!))
        presenter.resetKeepingEnvironment()
        #expect(presenter.model.files.isEmpty)
        #expect(presenter.model.settings.hotkey == Hotkey.parse("cmd+d"))
        #expect(presenter.model.loaded)
    }
}

/// A manual clock so timer effects can be tested without waiting.
/// Polls a main-actor condition for up to a second. For state that arrives from a task the
/// presenter does not track (timers), where a fixed number of yields is not a guarantee.
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

final class TestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let lock = NSLock()
    private var _now = Instant(offset: .zero)
    private var sleepers: [(deadline: Instant, continuation: CheckedContinuation<Void, any Error>)] = []

    var now: Instant { lock.withLock { _now } }
    var minimumResolution: Duration { .milliseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if deadline <= _now {
                    continuation.resume()
                } else {
                    sleepers.append((deadline, continuation))
                }
            }
        }
    }

    /// Moves time forward and lets any woken tasks run. Waits (up to a second) for at least one
    /// sleeper first: a timer task scheduled just before may not have called `sleep` yet, and
    /// advancing before it does would give it a deadline that never comes.
    func advance(by duration: Duration) async {
        for _ in 0..<200 where lock.withLock({ sleepers.isEmpty }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let due: [CheckedContinuation<Void, any Error>] = lock.withLock {
            _now = _now.advanced(by: duration)
            let (ready, waiting) = sleepers.reduce(into: ([CheckedContinuation<Void, any Error>](), [(Instant, CheckedContinuation<Void, any Error>)]())) { acc, sleeper in
                if sleeper.deadline <= _now { acc.0.append(sleeper.continuation) } else { acc.1.append(sleeper) }
            }
            sleepers = waiting
            return ready
        }
        for continuation in due { continuation.resume() }
        // Let the resumed tasks dispatch their events (other pending tasks may take turns too).
        for _ in 0..<20 { await Task.yield() }
    }
}
