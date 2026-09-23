import Foundation
import MobiusCore
import Observation

/// Holds the current model and applies events. Observable so SwiftUI can render it directly,
/// but it has no dependency on any UI framework.
///
/// Internally this is a Mobius loop (`InboxUpdate` + `EffectRouter`). The loop runs on the
/// caller's thread, so `send` returns the new model synchronously and a rejected event is
/// reported as a typed error before `send` returns. Asynchronous effects (trash, move, unzip,
/// access prompts) run in tasks that feed their outcome back as events; `settle()` waits for them.
@MainActor
@Observable
public final class InboxPresenter {
    public private(set) var model: InboxModel
    /// Last error produced by `send`, cleared on the next successful event.
    public private(set) var lastError: EventError?
    public let services: any InboxServices

    @ObservationIgnored private var loop: MobiusLoop<InboxModel, Event, InboxEffect>?
    @ObservationIgnored private var pending: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var timers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let clock: any Clock<Duration>

    public init(
        model: InboxModel = InboxModel(),
        services: any InboxServices,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.model = model
        self.services = services
        self.clock = clock
    }

    /// Starts the loop and sends `.launched`, which asks the services for persisted settings;
    /// those in turn start the folder watchers.
    public func start() {
        guard loop == nil else { return }
        loop = makeLoop(from: model)
        dispatch(.launched)
    }

    /// Applies an event and returns the resulting model in the same call.
    @discardableResult
    public func send(_ event: Event) throws(EventError) -> InboxModel {
        if loop == nil { loop = makeLoop(from: model) }
        lastError = nil
        loop?.dispatchEvent(event)
        if let error = lastError { throw error }
        return model
    }

    /// Convenience for UI callbacks that do not care about the error.
    public func dispatch(_ event: Event) {
        _ = try? send(event)
    }

    /// Waits for every in-flight effect task (not the undo/toast timers) to deliver its outcome.
    /// With a timeout, gives up after that long (a modal panel may be waiting for a human).
    public func settle(timeout: Duration? = nil) async {
        guard let timeout else {
            while let task = pending.values.first {
                await task.value
            }
            return
        }
        let deadline = ContinuousClock.now + timeout
        while !pending.isEmpty && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// True while an effect is still waiting for its outcome.
    public var isBusy: Bool { !pending.isEmpty }

    /// Replaces the whole model. Used by tests and the debug bridge to start from a known state.
    public func reset(to model: InboxModel) {
        for task in pending.values { task.cancel() }
        for task in timers.values { task.cancel() }
        pending = [:]
        timers = [:]
        loop?.dispose()
        self.model = model
        lastError = nil
        loop = makeLoop(from: model)
    }

    /// A fresh model that keeps settings and folders, so a test can restart a scenario.
    public func resetKeepingEnvironment() {
        var fresh = InboxModel(folders: model.folders, settings: model.settings, today: model.today)
        fresh.loaded = true
        fresh.history = model.history
        reset(to: fresh)
    }

    // MARK: Mobius wiring

    private func makeLoop(from model: InboxModel) -> MobiusLoop<InboxModel, Event, InboxEffect> {
        // Handlers run synchronously on the dispatching thread (the main actor), which is what
        // lets `send` observe a rejection before it returns.
        let effects = EffectRouter<InboxEffect, Event>()
            .routeCase(InboxEffect.reject).to { [weak self] (error: EventError) in
                MainActor.assumeIsolated { self?.lastError = error }
            }
            .routeCase(InboxEffect.loadSettings).to { [weak self] (_: Void) in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let (settings, folders) = self.services.loadSettings()
                    self.dispatch(.settingsLoaded(settings, folders: folders))
                }
            }
            .routeCase(InboxEffect.saveSettings).to { [weak self] (settings: Settings) in
                MainActor.assumeIsolated { self?.services.saveSettings(settings) }
            }
            .routeCase(InboxEffect.startWatching).to { [weak self] (folders: [WatchedFolder]) in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.services.startWatching(folders) { [weak self] event in self?.dispatch(event) }
                }
            }
            .routeCase(InboxEffect.stopWatching).to { [weak self] (kind: FolderKind) in
                MainActor.assumeIsolated { self?.services.stopWatching(kind) }
            }
            .routeCase(InboxEffect.requestAccess).to { [weak self] (kind: FolderKind) in
                MainActor.assumeIsolated {
                    self?.run { services in
                        let (access, path) = await services.requestAccess(kind)
                        return .folderAccessChanged(kind, access, path: path)
                    }
                }
            }
            .routeCase(InboxEffect.openFiles).to { [weak self] (files: [InboxFile]) in
                MainActor.assumeIsolated { self?.services.open(files) }
            }
            .routeCase(InboxEffect.quickLook).to { [weak self] (files: [InboxFile]) in
                MainActor.assumeIsolated { self?.services.quickLook(files) }
            }
            .routeCase(InboxEffect.reveal).to { [weak self] (files: [InboxFile]) in
                MainActor.assumeIsolated { self?.services.reveal(files) }
            }
            .routeCase(InboxEffect.copyToPasteboard).to { [weak self] (text: String) in
                MainActor.assumeIsolated { self?.services.copyToPasteboard(text) }
            }
            .routeCase(InboxEffect.chooseDestination).to { [weak self] (_: Void) in
                MainActor.assumeIsolated {
                    self?.run { services in
                        if let destination = await services.chooseDestination() {
                            return .destinationChosen(destination)
                        }
                        return .moveCancelled
                    }
                }
            }
            .routeCase(InboxEffect.move).to { [weak self] (files: [InboxFile], destination: String) in
                MainActor.assumeIsolated {
                    self?.run { services in
                        let result = await services.move(files, to: destination)
                        return .moved(succeeded: result.succeeded, failed: result.failed, destination: destination)
                    }
                }
            }
            .routeCase(InboxEffect.unzip).to { [weak self] (file: InboxFile) in
                MainActor.assumeIsolated {
                    self?.run { services in
                        switch await services.unzip(file) {
                        case .success(let output): return .unzipped(file.id, outputPath: output)
                        case .failure(let error): return .actionFailed(file.id, message: error.description)
                        }
                    }
                }
            }
            .routeCase(InboxEffect.trash).to { [weak self] (token: Int, files: [InboxFile]) in
                MainActor.assumeIsolated {
                    self?.run { services in
                        switch await services.trash(files) {
                        case .success(let items): return .trashed(token: token, items: items)
                        case .failure(let error): return .trashFailed(token: token, message: error.description)
                        }
                    }
                }
            }
            .routeCase(InboxEffect.restore).to { [weak self] (token: Int, items: [TrashedItem]) in
                MainActor.assumeIsolated {
                    self?.run { services in
                        .restored(token: token, files: await services.restore(items))
                    }
                }
            }
            .routeCase(InboxEffect.openFolder).to { [weak self] (path: String) in
                MainActor.assumeIsolated { self?.services.openFolder(path) }
            }
            .routeCase(InboxEffect.scheduleUndoExpiry).to { [weak self] (token: Int) in
                MainActor.assumeIsolated {
                    self?.schedule("undo", seconds: InboxReducer.undoSeconds, then: .undoExpired(token: token))
                }
            }
            .routeCase(InboxEffect.scheduleToastDismiss).to { [weak self] (token: Int) in
                MainActor.assumeIsolated {
                    self?.schedule("toast", seconds: InboxReducer.toastSeconds, then: .toastExpired(token: token))
                }
            }
            .routeCase(InboxEffect.setLaunchAtLogin).to { [weak self] (enabled: Bool) in
                MainActor.assumeIsolated {
                    self?.run { services in
                        switch await services.setLaunchAtLogin(enabled) {
                        case .success(let actual): return .launchAtLoginChanged(actual)
                        case .failure(let error): return .actionFailed(nil, message: error.description)
                        }
                    }
                }
            }
            .routeCase(InboxEffect.registerHotkey).to { [weak self] (hotkey: Hotkey) in
                MainActor.assumeIsolated { self?.services.registerHotkey(hotkey) }
            }
            .routeCase(InboxEffect.showPanel).to { [weak self] (_: Void) in
                MainActor.assumeIsolated { self?.services.showPanel() }
            }
            .routeCase(InboxEffect.hidePanel).to { [weak self] (_: Void) in
                MainActor.assumeIsolated { self?.services.hidePanel() }
            }
            .routeCase(InboxEffect.notify).to { [weak self] (file: InboxFile) in
                MainActor.assumeIsolated { self?.services.notify(file) }
            }
            .routeCase(InboxEffect.requestNotificationPermission).to { [weak self] (_: Void) in
                MainActor.assumeIsolated { self?.services.requestNotificationPermission() }
            }
            .routeCase(InboxEffect.chooseFolder).to { [weak self] (_: Void) in
                MainActor.assumeIsolated {
                    self?.run { services in
                        if let path = await services.chooseFolder() { return .folderChosen(path) }
                        return .folderChooserCancelled
                    }
                }
            }
            .routeCase(InboxEffect.loadHistory).to { [weak self] (_: Void) in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let history = self.services.loadHistory()
                    if !history.isEmpty { self.dispatch(.historyLoaded(history)) }
                }
            }
            .routeCase(InboxEffect.saveHistory).to { [weak self] (history: [HistoryEntry]) in
                MainActor.assumeIsolated { self?.services.saveHistory(history) }
            }
            .routeCase(InboxEffect.checkProStatus).to { [weak self] (_: Void) in
                MainActor.assumeIsolated {
                    self?.run { services in .proStatusChanged(await services.proStatus()) }
                }
            }
            .routeCase(InboxEffect.purchasePro).to { [weak self] (_: Void) in
                MainActor.assumeIsolated {
                    self?.run { services in
                        switch await services.purchasePro() {
                        case .success(let owned): return .proStatusChanged(owned)
                        case .failure(let error): return .purchaseFailed(error.description)
                        }
                    }
                }
            }
            .routeCase(InboxEffect.restorePurchases).to { [weak self] (_: Void) in
                MainActor.assumeIsolated {
                    self?.run { services in
                        switch await services.restorePurchases() {
                        case .success(let owned): return .proStatusChanged(owned)
                        case .failure(let error): return .purchaseFailed(error.description)
                        }
                    }
                }
            }
            .asConnectable

        let loop = Mobius.loop(update: InboxUpdate.update, effectHandler: effects).start(from: model)
        loop.addObserver { [weak self] model in
            MainActor.assumeIsolated { self?.model = model }
        }
        return loop
    }

    /// Runs an asynchronous service call and feeds its outcome back into the loop. Tracked so
    /// `settle()` can wait for it.
    private func run(_ body: @escaping @MainActor (any InboxServices) async -> Event) {
        let id = UUID()
        let services = self.services
        pending[id] = Task { @MainActor [weak self] in
            let outcome = await body(services)
            guard let self, !Task.isCancelled else { return }
            pending[id] = nil
            dispatch(outcome)
        }
    }

    private func schedule(_ name: String, seconds: Int, then event: Event) {
        timers[name]?.cancel()
        let clock = self.clock
        timers[name] = Task { @MainActor [weak self] in
            try? await clock.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dispatch(event)
        }
    }
}
