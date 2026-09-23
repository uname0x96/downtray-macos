import Foundation

/// One transition: the model after the event and the effects it asks for.
public struct Step: Equatable, Sendable {
    public var model: InboxModel
    public var effects: [InboxEffect]

    public init(_ model: InboxModel, _ effects: [InboxEffect] = []) {
        self.model = model
        self.effects = effects
    }
}

/// Pure state transition. Everything the app does is expressed here, so a UI, a test or an agent
/// can drive the app by sending events and reading the returned model. Rejected commands throw a
/// typed `EventError`; environment events (files arriving, panels closing) never throw.
public enum InboxReducer {
    public static let undoSeconds = 5
    public static let toastSeconds = 4

    public static func reduce(_ model: InboxModel, _ event: Event) throws(EventError) -> Step {
        var next = model
        var effects: [InboxEffect] = []

        switch event {
        // MARK: Environment

        case .launched:
            if !next.loaded { effects.append(.loadSettings) }

        case .settingsLoaded(let settings, let folders):
            next.settings = settings
            next.folders = folders
            next.loaded = true
            if let index = next.folders.firstIndex(where: { $0.kind == .desktop }) {
                next.folders[index].enabled = settings.watchDesktop
            }
            // Extra folders live in settings; the services may already have resolved their access.
            for path in settings.extraFolders where next.folder(.custom(path)) == nil {
                next.folders.append(.custom(path, access: .granted))
            }
            effects.append(.startWatching(next.folders.filter(\.enabled)))
            effects.append(.registerHotkey(settings.hotkey))
            effects.append(.loadHistory)
            effects.append(.checkProStatus)

        case .folderAccessChanged(let kind, let access, let path):
            guard let index = next.folders.firstIndex(where: { $0.kind == kind }) else { break }
            next.folders[index].access = access
            if let path { next.folders[index].path = path }
            if access == .granted && next.folders[index].enabled {
                effects.append(.startWatching([next.folders[index]]))
            }
            // The Desktop is opt-in; a refused grant turns the option back off.
            if kind == .desktop && access == .denied && next.folders[index].enabled {
                next.folders[index].enabled = false
                next.settings.watchDesktop = false
                effects.append(.saveSettings(next.settings))
            }

        case .scanCompleted(let kind, let listing):
            guard let folder = next.folder(kind) else { break }
            // Files present before the app looked are not "new": no unread dot, no badge.
            for id in next.files.keys where next.files[id]?.folder == folder.path {
                if !listing.contains(where: { $0.id == id }) {
                    next.files[id] = nil
                    next.selection.remove(id)
                    next.badgeIDs.remove(id)
                }
            }
            for var file in listing {
                if let existing = next.files[file.id] {
                    file.unread = existing.unread
                    file.missing = false
                } else {
                    file.unread = false
                }
                next.files[file.id] = file
            }
            next.fixFocus()

        case .fileArrived(let file):
            if var existing = next.files[file.id] {
                existing.size = file.size
                existing.modifiedAt = file.modifiedAt
                existing.kind = file.kind
                existing.source = file.source
                existing.missing = false
                next.files[file.id] = existing
            } else {
                var new = file
                new.unread = true
                new.missing = false
                next.files[file.id] = new
                if !next.panelOpen { next.badgeIDs.insert(file.id) }
                let watched = next.enabledFolderPaths.contains(file.folder)
                if next.settings.notificationsEnabled && watched {
                    effects.append(.notify(new))
                }
                if watched {
                    next.history.removeAll { $0.id == new.id }
                    next.history.insert(HistoryEntry(new), at: 0)
                    if next.history.count > InboxModel.historyLimit {
                        next.history.removeLast(next.history.count - InboxModel.historyLimit)
                    }
                    effects.append(.saveHistory(next.history))
                    if let rule = next.rule(for: .arrival, matching: new) {
                        effects.append(contentsOf: next.apply(rule, to: new))
                    }
                }
            }
            next.fixFocus()

        case .fileChanged(let file):
            guard var existing = next.files[file.id] else { break }
            existing.size = file.size
            existing.modifiedAt = file.modifiedAt
            existing.kind = file.kind
            existing.source = file.source
            existing.missing = false
            next.files[file.id] = existing

        case .fileRemoved(let id):
            // A file that left its folder leaves the list too; only History (Pro) remembers it.
            // The user did that move or delete themselves, so there is nothing to tell them.
            guard next.files[id] != nil else { break }
            next.files[id] = nil
            next.selection.remove(id)
            next.badgeIDs.remove(id)
            if next.suggestion?.fileID == id { next.suggestion = nil }
            next.fixFocus()

        case .setToday(let date):
            next.today = date
            next.fixFocus()

        case .panelOpened:
            next.panelOpen = true
            next.badgeIDs = []

        case .panelClosed:
            next.panelOpen = false
            next.selection = []
            next.focused = nil
            next.toast = nil
            next.query = ""
            next.paywallShown = false

        // MARK: Panel

        case .hotkeyPressed:
            if next.panelOpen {
                // The model leads and the UI follows, in both directions: the panel is closed
                // here and `.hidePanel` asks the UI to catch up. The UI's own `.panelClosed`
                // report is then a no-op instead of a late rewrite.
                next.panelOpen = false
                next.selection = []
                next.focused = nil
                next.toast = nil
                next.query = ""
                next.paywallShown = false
                effects.append(.hidePanel)
            } else {
                // Nothing is focused or selected on open: the pointer shows where the user is,
                // and the first arrow key starts keyboard navigation from the top.
                next.panelOpen = true
                next.badgeIDs = []
                effects.append(.showPanel)
            }

        case .setFilter(let filter):
            next.filter = filter
            next.fixFocus()

        case .showOlderFiles:
            if next.isPro {
                next.historyMode = true
                next.selection = []
                next.focused = nil
            } else {
                next.paywallShown = true
            }

        case .dismissPaywall:
            next.paywallShown = false

        case .select(let id, let mode):
            guard next.files[id] != nil else { throw .unknownFile(id) }
            switch mode {
            case .replace:
                next.selection = [id]
            case .toggle:
                if next.selection.contains(id) { next.selection.remove(id) } else { next.selection.insert(id) }
            case .range:
                let order = next.visibleIDs
                let anchor = next.focused ?? id
                if let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
                    next.selection = Set(order[min(from, to)...max(from, to)])
                } else {
                    next.selection = [id]
                }
            }
            next.focused = id

        case .focus(let id):
            guard next.files[id] != nil else { throw .unknownFile(id) }
            next.focused = id

        case .moveFocus(let direction):
            let order = next.visibleIDs
            guard !order.isEmpty else { throw .nothingToFocus }
            let current = next.focused.flatMap { order.firstIndex(of: $0) }
            let index: Int
            switch (direction, current) {
            case (.down, nil): index = 0
            case (.up, nil): index = order.count - 1
            case (.down, let i?): index = min(i + 1, order.count - 1)
            case (.up, let i?): index = max(i - 1, 0)
            }
            next.focused = order[index]
            next.selection = [order[index]]

        case .clearSelection:
            next.selection = []

        case .markAllSeen:
            for id in next.files.keys { next.files[id]?.unread = false }
            next.badgeIDs = []

        case .openWatchedFolder(let kind):
            guard let folder = next.folder(kind) else { throw .unknownFolder(kind) }
            effects.append(.openFolder(folder.path))

        case .dismissToast:
            next.toast = nil

        // MARK: File actions

        case .open(let target):
            let files = try next.resolve(target)
            next.markRead(files)
            effects.append(.openFiles(files))
            for file in files {
                if let rule = next.rule(for: .opened, matching: file) {
                    effects.append(contentsOf: next.apply(rule, to: file))
                }
            }

        case .quickLook(let target):
            let files = try next.resolve(target)
            next.markRead(files)
            effects.append(.quickLook(files))

        case .reveal(let target):
            let files = try next.resolve(target)
            next.markRead(files)
            effects.append(.reveal(files))

        case .copyPath(let target):
            let files = try next.resolve(target)
            next.markRead(files)
            effects.append(.copyToPasteboard(files.map(\.path).joined(separator: "\n")))
            effects.append(next.showToast(.pathCopied(count: files.count)))

        case .moveTo(let target):
            let files = try next.resolve(target)
            next.pendingMove = files.map(\.id)
            effects.append(.chooseDestination)

        case .unzip(let target):
            let files = try next.resolve(target)
            if let notZip = files.first(where: { !$0.isZip }) { throw .notAZip(notZip.id) }
            next.markRead(files)
            effects.append(contentsOf: files.map { InboxEffect.unzip($0) })

        case .trash(let target):
            let files = try next.resolve(target)
            effects.append(next.trashFiles(files))

        case .undoTrash:
            guard let undo = next.undo, undo.ready else { throw .nothingToUndo }
            next.undo = nil
            effects.append(.restore(token: undo.token, undo.items))

        case .dismiss(let id):
            guard next.files[id] != nil else { throw .unknownFile(id) }
            next.files[id] = nil
            next.selection.remove(id)
            next.badgeIDs.remove(id)
            next.fixFocus()

        // MARK: Outcomes

        case .destinationChosen(let destination):
            guard let ids = next.pendingMove else { throw .noPendingMove }
            next.pendingMove = nil
            let files = ids.compactMap { next.files[$0] }
            guard !files.isEmpty else { break }
            effects.append(.move(files, to: destination))

        case .moveCancelled:
            next.pendingMove = nil

        case .moved(let succeeded, let failed, let destination):
            for id in succeeded {
                next.files[id] = nil
                next.selection.remove(id)
                next.badgeIDs.remove(id)
            }
            next.fixFocus()
            let folderName = (destination as NSString).lastPathComponent
            if failed.isEmpty {
                let names = succeeded.map { ($0 as NSString).lastPathComponent }
                effects.append(next.showToast(.moved(names: names, folder: folderName)))
            } else {
                effects.append(next.showToast(.moveFailed(failed: failed.count, total: succeeded.count + failed.count), isError: true))
            }

        case .unzipped(let id, let outputPath):
            let name = (id as NSString).lastPathComponent
            let output = (outputPath as NSString).lastPathComponent
            effects.append(next.showToast(.extracted(name: name, folder: output)))

        case .trashed(let token, let items):
            guard next.undo?.token == token else { break }
            next.undo?.items = items
            effects.append(.scheduleUndoExpiry(token: token))

        case .trashFailed(let token, let message):
            guard let undo = next.undo, undo.token == token else { break }
            for file in undo.files { next.files[file.id] = file }
            next.undo = nil
            next.fixFocus()
            effects.append(next.showToast(message, isError: true))

        case .restored(_, let files):
            for var file in files {
                file.unread = false
                file.missing = false
                next.files[file.id] = file
            }
            next.fixFocus()

        case .undoExpired(let token):
            if next.undo?.token == token { next.undo = nil }

        case .toastExpired(let token):
            if next.toast?.token == token { next.toast = nil }

        case .actionFailed(_, let message):
            effects.append(next.showToast(message, isError: true))

        case .launchAtLoginChanged(let enabled):
            next.settings.launchAtLogin = enabled
            effects.append(.saveSettings(next.settings))

        case .folderChosen(let path):
            guard next.isPro else { throw .proRequired(.extraFolders) }
            // An outcome of the folder panel: nobody is waiting for a thrown error, so tell the
            // user through the toast instead.
            if next.folders.contains(where: { $0.path == path }) {
                effects.append(next.showToast(.folderAlreadyWatched(name: (path as NSString).lastPathComponent), isError: true))
                break
            }
            let folder = WatchedFolder.custom(path)
            next.folders.append(folder)
            next.settings.extraFolders.append(path)
            effects.append(.saveSettings(next.settings))
            effects.append(.startWatching([folder]))

        case .folderChooserCancelled:
            break

        case .historyLoaded(let entries):
            next.history = Array(entries.prefix(InboxModel.historyLimit))
            next.fixFocus()

        case .proStatusChanged(let owned):
            let changed = next.settings.proUnlocked != owned
            next.settings.proUnlocked = owned
            if !owned && next.historyMode { next.historyMode = false }
            if owned { next.paywallShown = false }
            if changed {
                effects.append(.saveSettings(next.settings))
                if owned { effects.append(next.showToast(.proUnlocked)) }
            }
            next.fixFocus()

        case .purchaseFailed(let message):
            effects.append(next.showToast(message, isError: true))

        // MARK: Settings

        case .setWatchDesktop(let enabled):
            guard let index = next.folders.firstIndex(where: { $0.kind == .desktop }) else { throw .unknownFolder(.desktop) }
            next.settings.watchDesktop = enabled
            next.folders[index].enabled = enabled
            effects.append(.saveSettings(next.settings))
            if enabled {
                effects.append(next.folders[index].access == .granted
                    ? .startWatching([next.folders[index]])
                    : .requestAccess(.desktop))
            } else {
                effects.append(.stopWatching(.desktop))
                next.selection = next.selection.filter { next.files[$0]?.folder != next.folders[index].path }
                next.fixFocus()
            }

        case .setLaunchAtLogin(let enabled):
            effects.append(.setLaunchAtLogin(enabled))

        case .setHotkey(let hotkey):
            next.settings.hotkey = hotkey
            effects.append(.registerHotkey(hotkey))
            effects.append(.saveSettings(next.settings))

        case .setNotifications(let enabled):
            next.settings.notificationsEnabled = enabled
            effects.append(.saveSettings(next.settings))
            if enabled { effects.append(.requestNotificationPermission) }

        case .setLanguage(let language):
            next.settings.language = language
            effects.append(.saveSettings(next.settings))

        case .grantAccess(let kind):
            guard next.folder(kind) != nil else { throw .unknownFolder(kind) }
            effects.append(.requestAccess(kind))

        case .unlockPro:
            effects.append(.purchasePro)

        case .restorePurchases:
            effects.append(.restorePurchases)

        // MARK: Pro

        case .addFolder:
            guard next.isPro else { throw .proRequired(.extraFolders) }
            effects.append(.chooseFolder)

        case .removeFolder(let kind):
            guard kind.isCustom, let index = next.folders.firstIndex(where: { $0.kind == kind }) else {
                throw .unknownFolder(kind)
            }
            let path = next.folders[index].path
            next.folders.remove(at: index)
            next.settings.extraFolders.removeAll { $0 == path }
            for id in next.files.keys where next.files[id]?.folder == path {
                next.files[id] = nil
                next.selection.remove(id)
                next.badgeIDs.remove(id)
            }
            next.fixFocus()
            effects.append(.stopWatching(kind))
            effects.append(.saveSettings(next.settings))

        case .setHistoryMode(let on):
            if on && !next.isPro { throw .proRequired(.history) }
            next.historyMode = on
            next.selection = []
            next.focused = nil
            // Each panel has its own search: a query never carries over between them.
            next.query = ""

        case .setQuery(let text):
            next.query = text
            next.fixFocus()

        case .clearHistory:
            next.history = []
            next.fixFocus()
            effects.append(.saveHistory([]))

        case .setHistoryFilter(let filter):
            next.historyFilter = filter
            next.fixFocus()

        case .removeFromHistory(let id):
            guard next.history.contains(where: { $0.id == id }) else { throw .unknownFile(id) }
            next.history.removeAll { $0.id == id }
            next.selection.remove(id)
            next.fixFocus()
            effects.append(.saveHistory(next.history))

        case .addRule(let rule):
            guard next.isPro else { throw .proRequired(.rules) }
            if next.settings.rules.contains(where: { $0.id != rule.id && $0.name.caseInsensitiveCompare(rule.name) == .orderedSame }) {
                throw .duplicateRule(rule.name)
            }
            next.settings.rules.removeAll { $0.id == rule.id }
            next.settings.rules.append(rule)
            effects.append(.saveSettings(next.settings))

        case .updateRule(let rule):
            guard let index = next.settings.rules.firstIndex(where: { $0.id == rule.id }) else {
                throw .unknownRule(rule.name)
            }
            next.settings.rules[index] = rule
            effects.append(.saveSettings(next.settings))

        case .removeRule(let id):
            guard let index = next.settings.rules.firstIndex(where: { $0.id == id }) else { throw .unknownRule(id) }
            next.settings.rules.remove(at: index)
            effects.append(.saveSettings(next.settings))

        case .acceptSuggestion:
            guard let suggestion = next.suggestion else { throw .noSuggestion }
            next.suggestion = nil
            guard let file = next.files[suggestion.fileID], !file.missing else { break }
            effects.append(contentsOf: next.perform(suggestion.action, on: file))

        case .dismissSuggestion:
            next.suggestion = nil
        }

        return Step(next, effects)
    }
}

// MARK: - Helpers used only by the reducer

extension InboxModel {
    /// The files an action applies to, in on-screen order. Throws when a target names a file the
    /// model does not have, or one that vanished.
    fileprivate func resolve(_ target: Target) throws(EventError) -> [InboxFile] {
        let ids: [FileID]
        switch target {
        case .files(let explicit):
            ids = explicit
        case .selection:
            if !selection.isEmpty {
                let order = visibleIDs
                ids = order.filter { selection.contains($0) } + selection.filter { !order.contains($0) }.sorted()
            } else if let focused {
                ids = [focused]
            } else {
                throw .nothingSelected
            }
        }
        guard !ids.isEmpty else { throw .nothingSelected }
        var files: [InboxFile] = []
        for id in ids {
            guard let file = self.files[id] else {
                // A history row whose file is gone reads as "missing", not "unknown".
                if history.contains(where: { $0.id == id }) { throw .fileMissing(id) }
                throw .unknownFile(id)
            }
            if file.missing { throw .fileMissing(id) }
            files.append(file)
        }
        return files
    }

    fileprivate mutating func markRead(_ files: [InboxFile]) {
        for file in files {
            self.files[file.id]?.unread = false
            badgeIDs.remove(file.id)
        }
    }

    /// Removes the rows and asks the file system to trash them, with the 5 s undo window.
    fileprivate mutating func trashFiles(_ files: [InboxFile]) -> InboxEffect {
        let token = takeToken()
        for file in files {
            self.files[file.id] = nil
            selection.remove(file.id)
            badgeIDs.remove(file.id)
            if suggestion?.fileID == file.id { suggestion = nil }
        }
        undo = TrashUndo(token: token, files: files)
        toast = nil
        fixFocus()
        return .trash(token: token, files)
    }

    /// What a matching rule does to a file. Suggestions wait for the user; the rest act at once.
    fileprivate mutating func apply(_ rule: Rule, to file: InboxFile) -> [InboxEffect] {
        switch rule.action {
        case .suggestTrash:
            suggestion = Suggestion(fileID: file.id, ruleName: rule.name, action: .trash)
            return []
        default:
            return perform(rule.action, on: file)
        }
    }

    fileprivate mutating func perform(_ action: RuleAction, on file: InboxFile) -> [InboxEffect] {
        switch action {
        case .moveTo(let path):
            return [.move([file], to: path)]
        case .trash:
            return [trashFiles([file])]
        case .markSeen:
            markRead([file])
            return []
        case .suggestTrash:
            return [trashFiles([file])]
        }
    }

    fileprivate mutating func takeToken() -> Int {
        defer { nextToken += 1 }
        return nextToken
    }

    fileprivate mutating func showToast(_ message: String, isError: Bool = false) -> InboxEffect {
        showToast(.text(message), isError: isError)
    }

    fileprivate mutating func showToast(_ text: ToastText, isError: Bool = false) -> InboxEffect {
        let token = takeToken()
        toast = Toast(token: token, text: text, isError: isError)
        return .scheduleToastDismiss(token: token)
    }

    /// Keeps focus and selection on rows that are still on screen.
    fileprivate mutating func fixFocus() {
        let visible = Set(visibleIDs)
        selection = selection.filter { visible.contains($0) }
        if let focused, !visible.contains(focused) { self.focused = nil }
    }
}
