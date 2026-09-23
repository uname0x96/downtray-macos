import Foundation
import Testing
import MobiusTest
@testable import InboxCore

/// Pro features: extra folders, history, rules and the purchase flow. All headless.
@Suite struct ProTests {
    private var spec: UpdateSpec<InboxModel, Event, InboxEffect> { UpdateSpec(InboxUpdate.update) }
    private let docs = "/Users/sample/Documents"

    private func pro(_ files: [InboxFile] = [], rules: [Rule] = []) -> InboxModel {
        var m = model(files)
        m.settings.proUnlocked = true
        m.settings.rules = rules
        return m
    }

    // MARK: Gating

    @Test func proFeaturesAreRejectedInTheFreeTier() {
        let free = model()
        #expect(throws: EventError.proRequired(.extraFolders)) { try InboxReducer.reduce(free, .addFolder) }
        #expect(throws: EventError.proRequired(.extraFolders)) { try InboxReducer.reduce(free, .folderChosen(docs)) }
        #expect(throws: EventError.proRequired(.history)) { try InboxReducer.reduce(free, .setHistoryMode(true)) }
        #expect(throws: EventError.proRequired(.rules)) {
            try InboxReducer.reduce(free, .addRule(Rule(name: "x", action: .trash)))
        }
        // Rules already stored (from a lapsed Pro) do not run without Pro.
        var lapsed = model()
        lapsed.settings.rules = [Rule(name: "trash all", action: .trash)]
        let step = try? InboxReducer.reduce(lapsed, .fileArrived(file("a.pdf")))
        #expect(step?.model.visibleFiles.count == 1)
        #expect(step?.model.undo == nil)
    }

    @Test func freeTierListsTwentyAndProListsMore() {
        let many = (0..<30).map { file("f\($0).pdf", minutesAgo: Double($0)) }
        #expect(model(many).visibleFiles.count == 20)
        #expect(pro(many).visibleFiles.count == 30)
    }

    // MARK: Extra folders

    @Test func extraFoldersAreAddedWatchedAndRemoved() throws {
        var step = try InboxReducer.reduce(pro(), .addFolder)
        #expect(step.effects == [.chooseFolder])

        step = try InboxReducer.reduce(pro(), .folderChosen(docs))
        let folder = WatchedFolder.custom(docs)
        #expect(step.model.customFolders == [folder])
        #expect(step.model.settings.extraFolders == [docs])
        #expect(step.effects == [.saveSettings(step.model.settings), .startWatching([folder])])
        let again = try InboxReducer.reduce(step.model, .folderChosen(docs))
        #expect(again.model.settings.extraFolders == [docs])
        #expect(again.model.toast?.isError == true)

        let inDocs = InboxFile(path: docs + "/notes.pdf", addedAt: today)
        var withFile = try InboxReducer.reduce(step.model, .fileArrived(inDocs)).model
        #expect(withFile.visibleFiles.map(\.name) == ["notes.pdf"])
        withFile.panelOpen = true
        withFile.focused = inDocs.id
        let removed = try InboxReducer.reduce(withFile, .removeFolder(.custom(docs)))
        #expect(removed.model.customFolders.isEmpty)
        #expect(removed.model.settings.extraFolders.isEmpty)
        #expect(removed.model.visibleFiles.isEmpty)
        #expect(removed.model.focused == nil)
        #expect(removed.effects == [.stopWatching(.custom(docs)), .saveSettings(removed.model.settings)])
        #expect(throws: EventError.unknownFolder(.downloads)) { try InboxReducer.reduce(withFile, .removeFolder(.downloads)) }
    }

    @Test func extraFoldersFromSettingsAreWatchedAtLaunch() throws {
        let settings = Settings(proUnlocked: true, extraFolders: [docs])
        let step = try InboxReducer.reduce(model(), .settingsLoaded(settings, folders: WatchedFolder.sample()))
        #expect(step.model.customFolders.map(\.path) == [docs])
        #expect(step.effects.first == .startWatching(step.model.folders.filter(\.enabled)))
        #expect(step.model.folders.filter(\.enabled).map(\.kind) == [.downloads, .custom(docs)])
    }

    // MARK: History

    @Test func historyRecordsArrivalsAndOutlivesTheFiles() throws {
        let a = file("a.pdf")
        var m = try InboxReducer.reduce(pro(), .fileArrived(a)).model
        #expect(m.history.map(\.name) == ["a.pdf"])
        m = try InboxReducer.reduce(m, .dismiss(a.id)).model
        #expect(m.visibleFiles.isEmpty)
        m = try InboxReducer.reduce(m, .setHistoryMode(true)).model
        #expect(m.visibleFiles.map(\.name) == ["a.pdf"])
        #expect(m.visibleFiles[0].missing, "a history row for a gone file is greyed out")
        #expect(throws: EventError.fileMissing(a.id)) { try InboxReducer.reduce(m, .open(.files([a.id]))) }

        let cleared = try InboxReducer.reduce(m, .clearHistory)
        #expect(cleared.model.history.isEmpty && cleared.effects == [.saveHistory([])])
    }

    @Test func historyPanelHidesFoldersSegmentsRowsAndForgetsGoneOnes() throws {
        let folder = InboxFile(path: downloads + "/shots", addedAt: today.addingTimeInterval(3600), kind: .folder)
        let gone = file("gone.pdf", minutesAgo: 5)
        let here = file("here.pdf")
        var m = pro()
        for arrival in [folder, gone, here] { m = try InboxReducer.reduce(m, .fileArrived(arrival)).model }
        m = try InboxReducer.reduce(m, .fileRemoved(gone.id)).model
        m = try InboxReducer.reduce(m, .setFilter(.images)).model
        m = try InboxReducer.reduce(m, .setHistoryMode(true)).model
        #expect(m.visibleFiles.map(\.name) == ["here.pdf", "gone.pdf"], "folders are left out and the inbox type chip does not apply")
        #expect(m.visibleFiles.map(\.missing) == [false, true])

        m = try InboxReducer.reduce(m, .setHistoryFilter(.gone)).model
        #expect(m.visibleFiles.map(\.name) == ["gone.pdf"] && m.snapshot.historyFilter == "gone")
        m = try InboxReducer.reduce(m, .setHistoryFilter(.available)).model
        #expect(m.visibleFiles.map(\.name) == ["here.pdf"])
        m = try InboxReducer.reduce(m, .setQuery("zzz")).model
        #expect(m.emptyState == .noMatches)
        m = try InboxReducer.reduce(m, .setQuery("")).model
        m = try InboxReducer.reduce(m, .setHistoryFilter(.all)).model

        let step = try InboxReducer.reduce(m, .removeFromHistory(gone.id))
        #expect(step.model.visibleFiles.map(\.name) == ["here.pdf"])
        #expect(step.effects == [.saveHistory(step.model.history)])
        #expect(throws: EventError.unknownFile(gone.id)) { try InboxReducer.reduce(step.model, .removeFromHistory(gone.id)) }

        var empty = try InboxReducer.reduce(pro(), .setHistoryMode(true)).model
        #expect(empty.emptyState == .historyEmpty)
        empty = try InboxReducer.reduce(empty, .fileArrived(folder)).model
        #expect(empty.emptyState == .historyEmpty, "a folder alone is not history")
    }

    @Test func historyIsCappedAndDeduplicated() throws {
        var m = pro()
        for index in 0..<(InboxModel.historyLimit + 5) {
            m = try InboxReducer.reduce(m, .fileArrived(file("f\(index).pdf", minutesAgo: Double(index)))).model
        }
        #expect(m.history.count == InboxModel.historyLimit)
        #expect(m.history.first?.name == "f\(InboxModel.historyLimit + 4).pdf")
        m = try InboxReducer.reduce(m, .dismiss(m.history[0].id)).model
        m = try InboxReducer.reduce(m, .fileArrived(file("f\(InboxModel.historyLimit + 4).pdf"))).model
        #expect(m.history.filter { $0.name == "f\(InboxModel.historyLimit + 4).pdf" }.count == 1)
    }

    @Test func searchFiltersByNameInBothModes() throws {
        var m = pro([file("invoice.pdf"), file("photo.png", minutesAgo: 1)])
        m = try InboxReducer.reduce(m, .setQuery("inv")).model
        #expect(m.visibleFiles.map(\.name) == ["invoice.pdf"])
        m = try InboxReducer.reduce(m, .setQuery("")).model
        #expect(m.visibleFiles.count == 2)
        m.panelOpen = true
        m = try InboxReducer.reduce(m, .setQuery("zzz")).model
        #expect(m.emptyState == .noMatches, "the Pro inbox has a search field, so no hits is No matches")
        m = try InboxReducer.reduce(m, .setQuery("")).model
        #expect(m.emptyState == nil)
        m = try InboxReducer.reduce(m, .setQuery("inv")).model
        m = try InboxReducer.reduce(m, .setHistoryMode(true)).model
        #expect(m.query.isEmpty, "entering History starts with an empty search")
        m = try InboxReducer.reduce(m, .setQuery("zzz")).model
        m = try InboxReducer.reduce(m, .setHistoryMode(false)).model
        #expect(m.query.isEmpty, "leaving History clears its search")
        m = try InboxReducer.reduce(m, .setQuery("zzz")).model
        m = try InboxReducer.reduce(m, .hotkeyPressed).model
        #expect(m.query.isEmpty, "closing the panel clears the search")
    }

    // MARK: Rules

    @Test func arrivalRulesMoveTrashMarkSeenOrSuggest() throws {
        let move = Rule(name: "invoices", match: RuleMatch(kind: .pdf, host: "stripe.com"), action: .moveTo(docs))
        let trash = Rule(name: "no dmg", match: RuleMatch(fileExtension: "dmg"), action: .trash)
        let seen = Rule(name: "screenshots", match: RuleMatch(nameContains: "Screenshot"), action: .markSeen)
        let suggest = Rule(name: "big zips", match: RuleMatch(kind: .archive), action: .suggestTrash)
        let m = pro(rules: [move, trash, seen, suggest])

        let invoice = InboxFile(path: downloads + "/invoice.pdf", addedAt: today, source: .web(host: "pay.stripe.com"))
        var step = try InboxReducer.reduce(m, .fileArrived(invoice))
        #expect(step.effects.contains(.move([step.model.files[invoice.id]!], to: docs)))

        step = try InboxReducer.reduce(m, .fileArrived(file("Tool.dmg")))
        #expect(step.model.visibleFiles.isEmpty && step.model.undo?.files.map(\.name) == ["Tool.dmg"])
        #expect(step.effects.contains { if case .trash = $0 { return true } else { return false } })

        step = try InboxReducer.reduce(m, .fileArrived(file("Screenshot 1.png")))
        #expect(step.model.visibleFiles[0].unread == false && step.model.badgeCount == 0)

        step = try InboxReducer.reduce(m, .fileArrived(file("big.zip")))
        #expect(step.model.visibleFiles.count == 1)
        #expect(step.model.suggestion?.message == "big zips: move big.zip to the Trash?")
        let accepted = try InboxReducer.reduce(step.model, .acceptSuggestion)
        #expect(accepted.model.visibleFiles.isEmpty && accepted.model.suggestion == nil)
        #expect(accepted.model.undo?.files.map(\.name) == ["big.zip"])
        let dismissed = try InboxReducer.reduce(step.model, .dismissSuggestion)
        #expect(dismissed.model.suggestion == nil && dismissed.model.visibleFiles.count == 1)
        #expect(throws: EventError.noSuggestion) { try InboxReducer.reduce(dismissed.model, .acceptSuggestion) }

        // An unrelated file matches nothing.
        step = try InboxReducer.reduce(m, .fileArrived(file("notes.txt")))
        #expect(step.effects == [.saveHistory(step.model.history)])
    }

    @Test func openedRulesRunAfterOpening() throws {
        let rule = Rule(name: "installers", trigger: .opened, match: RuleMatch(kind: .installer), action: .suggestTrash)
        let dmg = file("Tool.dmg")
        let m = pro([dmg], rules: [rule])
        let step = try InboxReducer.reduce(m, .open(.files([dmg.id])))
        #expect(step.effects == [.openFiles([dmg])])
        #expect(step.model.suggestion?.fileID == dmg.id)
        // The suggestion goes away with the file.
        let gone = try InboxReducer.reduce(step.model, .fileRemoved(dmg.id))
        #expect(gone.model.suggestion == nil)
    }

    @Test func rulesAreManagedAndPersisted() throws {
        let rule = Rule(name: "r", action: .trash)
        var step = try InboxReducer.reduce(pro(), .addRule(rule))
        #expect(step.model.settings.rules == [rule] && step.effects == [.saveSettings(step.model.settings)])
        var edited = rule
        edited.enabled = false
        step = try InboxReducer.reduce(step.model, .updateRule(edited))
        #expect(step.model.settings.rules == [edited])
        #expect(step.model.rule(for: .arrival, matching: file("a.pdf")) == nil, "disabled rules do not match")
        step = try InboxReducer.reduce(step.model, .removeRule(rule.id))
        #expect(step.model.settings.rules.isEmpty)
        #expect(throws: EventError.unknownRule(rule.id)) { try InboxReducer.reduce(step.model, .removeRule(rule.id)) }
    }

    @Test func ruleMatchingIsSpecific() {
        let stripe = InboxFile(path: downloads + "/a.pdf", addedAt: today, source: .web(host: "pay.stripe.com"))
        #expect(RuleMatch(host: "stripe.com").matches(stripe))
        #expect(!RuleMatch(host: "stripe.com").matches(file("a.pdf")), "no source, no host match")
        #expect(!RuleMatch(host: "notstripe.com").matches(stripe))
        #expect(RuleMatch(fileExtension: ".DMG").matches(file("x.dmg")))
        #expect(RuleMatch(nameContains: "INVOICE").matches(file("my-invoice-3.pdf")))
        #expect(RuleMatch().matches(file("anything.bin")))
        #expect(RuleMatch(kind: .pdf, host: "stripe.com").summary == "PDF from stripe.com")
    }

    // MARK: Grammar

    @Test func proCommandsRoundTrip() throws {
        var m = pro([file("a.pdf")])
        let rule = Rule(name: "stripe invoices", match: RuleMatch(kind: .pdf, host: "stripe.com"), action: .moveTo(docs))
        m.settings.rules = [rule]
        m.folders.append(.custom(docs))
        let context = ParseContext(model: m, now: today)

        let parsed = try Event.parse("rule add stripe invoices kind=pdf host=stripe.com then move \(docs)", context: context)
        guard case .addRule(let added) = parsed else { Issue.record("not a rule"); return }
        #expect(added.name == rule.name && added.match == rule.match && added.action == rule.action)
        #expect(Event.addRule(rule).commandLine == "rule add stripe invoices kind=pdf host=stripe.com then move \(docs)")

        #expect(try Event.parse("rule disable stripe invoices", context: context) == .updateRule({ var r = rule; r.enabled = false; return r }()))
        #expect(try Event.parse("rule remove stripe invoices", context: context) == .removeRule(rule.id))
        #expect(try Event.parse("folder add", context: context) == .addFolder)
        #expect(try Event.parse("folder add \(docs)", context: context) == .folderChosen(docs))
        #expect(try Event.parse("folder remove Documents", context: context) == .removeFolder(.custom(docs)))
        #expect(try Event.parse("history on", context: context) == .setHistoryMode(true))
        #expect(try Event.parse("history gone", context: context) == .setHistoryFilter(.gone))
        #expect(try Event.parse("search inv oice", context: context) == .setQuery("inv oice"))
        #expect(try Event.parse("search", context: context) == .setQuery(""))
        #expect(try Event.parse("pro on", context: context) == .proStatusChanged(true))
        #expect(try Event.parse("accept", context: context) == .acceptSuggestion)
        #expect(throws: Event.ParseError.unknownRule("nope")) { try Event.parse("rule remove nope", context: context) }
        #expect(throws: Event.ParseError.missingArgument("rule add … then")) { try Event.parse("rule add x kind=pdf", context: context) }
    }

    // MARK: Presenter

    @MainActor @Test func purchaseFlowsThroughTheStore() async throws {
        let services = FakeServices()
        let presenter = InboxPresenter(model: InboxModel(folders: services.folders, today: today), services: services)
        presenter.start()
        await presenter.settle()
        #expect(!presenter.model.isPro)

        services.purchaseShouldFail = true
        try presenter.send(.unlockPro)
        await presenter.settle()
        #expect(!presenter.model.isPro && presenter.model.toast?.isError == true)

        services.purchaseShouldFail = false
        try presenter.send(.unlockPro)
        await presenter.settle()
        #expect(presenter.model.isPro && services.settings.proUnlocked)

        // Restart: the store's answer wins over the saved flag.
        services.proOwned = false
        let again = InboxPresenter(model: InboxModel(folders: services.folders, today: today), services: services)
        again.start()
        await again.settle()
        #expect(!again.model.isPro)
    }

    @MainActor @Test func extraFolderIsWatchedThroughTheServices() async throws {
        let services = FakeServices()
        services.proOwned = true
        services.nextFolder = docs
        let inDocs = InboxFile(path: docs + "/old.pdf", addedAt: today)
        services.world[inDocs.id] = inDocs
        let presenter = InboxPresenter(model: InboxModel(folders: services.folders, today: today), services: services)
        presenter.start()
        await presenter.settle()
        try presenter.send(.addFolder)
        await presenter.settle()
        #expect(presenter.model.customFolders.map(\.path) == [docs])
        #expect(presenter.model.visibleFiles.map(\.name) == ["old.pdf"])
        #expect(services.log.contains("watch \(docs)"))
    }
}
