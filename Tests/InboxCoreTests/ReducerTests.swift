import Foundation
import Testing
import MobiusCore
import MobiusTest
@testable import InboxCore

/// Routes MobiusTest assertion failures into Swift Testing.
private func recordFailure(_ message: String, _ file: StaticString, _ line: UInt) {
    Issue.record(Comment(rawValue: message),
                 sourceLocation: SourceLocation(fileID: "\(file)", filePath: "\(file)", line: Int(line), column: 1))
}

let downloads = "/Users/sample/Downloads"
let scans = "/Users/sample/Scans"
let today = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 23))!

func file(_ name: String, minutesAgo: Double = 0, size: Int64 = 1024, folder: String = downloads,
          source: FileSource = .unknown, unread: Bool = true) -> InboxFile {
    InboxFile(path: folder + "/" + name, size: size, addedAt: today.addingTimeInterval(3600 * 9 - minutesAgo * 60),
              source: source, unread: unread)
}

/// The clock the tests run on: 09:00 on `today`; `file(minutesAgo:)` counts back from it.
let now = today.addingTimeInterval(3600 * 9)

func model(_ files: [InboxFile] = [], open: Bool = false) -> InboxModel {
    var model = InboxModel(files: files, folders: WatchedFolder.sample(), today: today, now: now)
    model.loaded = true
    model.panelOpen = open
    return model
}

@Suite struct ReducerTests {
    private let spec = UpdateSpec(InboxUpdate.update)

    // MARK: Arrivals, badge, unread

    @Test func launchAsksForSettingsOnceAndSettingsStartWatching() {
        var fresh = InboxModel(folders: WatchedFolder.sample(), today: today)
        spec.given(fresh).when(.launched).then(assertThatNext(hasExactlyEffects([.loadSettings]), failFunction: recordFailure))
        fresh.loaded = true
        spec.given(fresh).when(.launched).then(assertThatNext(hasNoEffects(), failFunction: recordFailure))

        let settings = Settings(proUnlocked: false)
        spec.given(model()).when(.settingsLoaded(settings, folders: WatchedFolder.sample())).then { result in
            #expect(result.model.folders.map(\.kind) == [.downloads])
            #expect(result.lastNext.effects == [
                .startWatching(result.model.folders),
                .registerHotkey(.default),
                .loadHistory,
                .checkProStatus,
            ])
        }
    }

    @Test func arrivalWhilePanelClosedIsUnreadAndBadged() {
        spec.given(model()).when(.fileArrived(file("a.pdf"))).then { result in
            #expect(result.model.badgeCount == 1)
            #expect(result.model.visibleFiles.map(\.name) == ["a.pdf"])
            #expect(result.model.visibleFiles[0].unread)
            // Every arrival is recorded for History.
            #expect(result.lastNext.effects == [.saveHistory(result.model.history)])
            #expect(result.model.history.map(\.name) == ["a.pdf"])
        }
    }

    @Test func arrivalWhilePanelOpenIsUnreadAndBadgedToo() {
        // The badge is the unread count, whatever the panel is doing.
        spec.given(model(open: true)).when(.fileArrived(file("a.pdf"))).then { result in
            #expect(result.model.badgeCount == 1)
            #expect(result.model.unreadCount == 1)
        }
    }

    @Test func arrivalNotifiesOnlyWhenEnabled() {
        var m = model()
        m.settings.notificationsEnabled = true
        let f = file("a.pdf")
        spec.given(m).when(.fileArrived(f)).then { result in
            #expect(result.lastNext.effects == [.notify(f), .saveHistory(result.model.history)])
        }
        spec.given(model()).when(.fileArrived(f)).then { result in
            #expect(result.lastNext.effects == [.saveHistory(result.model.history)])
        }
    }

    @Test func initialScanIsNotNew() {
        spec.given(model()).when(.scanCompleted(.downloads, [file("old.pdf"), file("older.zip", minutesAgo: 5)])).then { result in
            #expect(result.model.badgeCount == 0)
            #expect(result.model.unreadCount == 0)
            #expect(result.model.visibleFiles.map(\.name) == ["old.pdf", "older.zip"])
        }
    }

    @Test func rescanKeepsUnreadStateAndDropsGoneFiles() {
        let a = file("a.pdf")
        let b = file("b.pdf", minutesAgo: 1)
        spec.given(model([a, b])).when(.scanCompleted(.downloads, [a])).then { result in
            #expect(result.model.visibleFiles.map(\.name) == ["a.pdf"])
            #expect(result.model.visibleFiles[0].unread)
        }
    }

    @Test func openingThePanelMarksNothingReadAndSelectsNothing() {
        let read = file("seen.pdf", unread: false)
        let unread = file("new.pdf", minutesAgo: 3)
        let m = model([read, unread])
        spec.given(m).when(.panelOpened).then { result in
            #expect(result.model.panelOpen)
            #expect(result.model.badgeCount == 1, "opening the panel alone does not mark read")
            #expect(result.model.unreadCount == 1)
            #expect(result.model.focused == nil && result.model.selection.isEmpty)
        }
    }

    @Test func hotkeyOpensWithNothingSelectedAndTogglesClosed() {
        let m = model([file("a.pdf")])
        spec.given(m).when(.hotkeyPressed).then { result in
            #expect(result.model.panelOpen)
            #expect(result.model.focused == nil && result.model.selection.isEmpty)
            #expect(result.lastNext.effects == [.showPanel])
        }
        // The first arrow key starts from the top.
        spec.given(model([file("a.pdf")], open: true)).when(.moveFocus(.down)).then { result in
            #expect(result.model.focused == m.visibleFiles[0].id)
            #expect(result.model.selection == [m.visibleFiles[0].id])
        }
        spec.given(model(open: true)).when(.hotkeyPressed).then { result in
            #expect(!result.model.panelOpen)
            #expect(result.model.selection.isEmpty && result.model.focused == nil)
            #expect(result.lastNext.effects == [.hidePanel])
        }
    }

    @Test func closingThePanelClearsSelectionFocusAndToast() {
        var m = model([file("a.pdf")], open: true)
        m.focused = m.visibleFiles[0].id
        m.selection = [m.focused!]
        m.toast = Toast(token: 9, message: "x")
        spec.given(m).when(.panelClosed).then { result in
            #expect(!result.model.panelOpen)
            #expect(result.model.selection.isEmpty)
            #expect(result.model.focused == nil)
            #expect(result.model.toast == nil)
        }
    }

    @Test func markAllSeenClearsDotsAndBadge() {
        let m = model([file("a.pdf"), file("b.pdf", minutesAgo: 1)])
        spec.given(m).when(.markAllSeen).then { result in
            #expect(result.model.unreadCount == 0)
            #expect(result.model.badgeCount == 0)
        }
    }

    // MARK: List, filters, order, limit

    @Test func listIsNewestFirstAndCappedAtTwenty() {
        let files = (0..<25).map { file("f\($0).pdf", minutesAgo: Double($0)) }
        let m = model(files)
        #expect(m.visibleFiles.count == 20)
        #expect(m.visibleFiles.first?.name == "f0.pdf")
        #expect(m.visibleFiles.last?.name == "f19.pdf")
    }

    // MARK: Chips, Type menu, search (the filter spec's matrix)

    @Test func typeGroupsComeFromTheExtensionTable() {
        #expect(file("Invoice.PDF").typeGroup() == .docs)
        #expect(file("shot.PNG").typeGroup() == .images)
        #expect(file("app.dmg").typeGroup() == .apps)
        #expect(file("clip.mov").typeGroup() == .media)
        #expect(file("src.tar.gz").typeGroup() == .archives)
        #expect(file("notes").typeGroup() == .other)
        #expect(file("data.bin").typeGroup() == .other)
        let folder = InboxFile(path: downloads + "/shots.app", addedAt: now, kind: .folder)
        #expect(folder.typeGroup() == .other, "a directory is never an app")
        #expect(file("notes.md").typeGroup(overrides: ["md": .media]) == .media, "overrides win")
    }

    @Test func chipsTypeMenuAndSearchAreAndCombined() {
        let invoice = file("Invoice.PDF", source: .web(host: "stripe.com"))
        let shot = file("shot.png", minutesAgo: 61)
        let early = InboxFile(path: downloads + "/early.png", addedAt: today.addingTimeInterval(60))
        let late = InboxFile(path: downloads + "/late.dmg", addedAt: today.addingTimeInterval(-60))
        let clip = file("clip.mp4", minutesAgo: 2, unread: false)
        var m = model([invoice, shot, early, late, clip])
        func names(_ chip: FileFilter, type: TypeGroup? = nil, search: String = "") -> [String] {
            m.filter = chip
            m.typeFilter = type
            m.query = search
            return m.visibleFiles.map(\.name)
        }
        #expect(names(.all) == ["Invoice.PDF", "clip.mp4", "shot.png", "early.png", "late.dmg"], "newest first")
        #expect(names(.lastHour) == ["Invoice.PDF", "clip.mp4"], "61 minutes is outside the hour")
        #expect(names(.today) == ["Invoice.PDF", "clip.mp4", "shot.png", "early.png"], "00:01 is today, yesterday 23:59 is not")
        #expect(names(.unread) == ["Invoice.PDF", "shot.png", "early.png", "late.dmg"])
        #expect(names(.all, type: .images) == ["shot.png", "early.png"])
        #expect(names(.today, type: .images) == ["shot.png", "early.png"], "Type AND chip")
        #expect(names(.lastHour, type: .images) == [])
        #expect(names(.all, search: "pdf") == ["Invoice.PDF"], "the extension matches without the dot")
        #expect(names(.all, search: ".PDF") == ["Invoice.PDF"], "and with it")
        #expect(names(.all, search: "images") == ["shot.png", "early.png"], "the type group's name matches")
        #expect(names(.all, search: "stripe") == ["Invoice.PDF"], "the source host matches")
        #expect(names(.all, search: "  late ") == ["late.dmg"], "trimmed, case-insensitive name match")
        #expect(names(.today, type: .docs, search: "inv") == ["Invoice.PDF"], "all three combine")
        m.typeLabels = [.images: "Bilder"]
        #expect(names(.all, search: "bild") == ["shot.png", "early.png"], "the localized group name matches too")
        #expect(m.count(for: .unread) == 4 && m.count(for: .lastHour) == 2, "chip counts ignore Type and search")
    }

    @Test func emptyStatesFollowTheChipTheTypeMenuAndTheSearch() throws {
        var m = model([file("a.pdf", minutesAgo: 90, unread: false)], open: true)
        #expect(m.emptyState == nil)
        m.filter = .lastHour
        #expect(m.emptyState == .nothingLastHour)
        m.filter = .unread
        #expect(m.emptyState == .caughtUp)
        m.filter = .all
        m.typeFilter = .images
        #expect(m.emptyState == .noMatches, "the Type menu narrowed a non-empty list")
        m.typeFilter = nil
        m.query = "zzz"
        #expect(m.emptyState == .noMatches)
        m.query = ""
        m = try InboxReducer.reduce(m, .setToday(today.addingTimeInterval(2 * 24 * 3600))).model
        m.filter = .today
        #expect(m.emptyState == .nothingToday)
        #expect(model(open: true).emptyState == .nothingNew, "nothing at all")
        var denied = model()
        denied.folders[0].access = .denied
        #expect(denied.emptyState == .needsAccess)
    }

    @Test func launchChipIsTodayUnlessTodayIsEmpty() throws {
        let settings = Settings(selectedChip: .today, selectedType: .docs)
        var m = try InboxReducer.reduce(model(), .settingsLoaded(settings, folders: WatchedFolder.sample())).model
        #expect(m.filter == .today && m.typeFilter == .docs, "the chip and the Type menu are restored")
        let old = InboxFile(path: downloads + "/old.pdf", addedAt: today.addingTimeInterval(-3600))
        m = try InboxReducer.reduce(m, .scanCompleted(.downloads, [old])).model
        #expect(m.filter == .all, "nothing today at launch: fall back to All")

        var fresh = try InboxReducer.reduce(model(), .settingsLoaded(settings, folders: WatchedFolder.sample())).model
        fresh = try InboxReducer.reduce(fresh, .scanCompleted(.downloads, [file("new.pdf")])).model
        #expect(fresh.filter == .today, "something today: Today stays")
        fresh = try InboxReducer.reduce(fresh, .scanCompleted(.downloads, [old])).model
        #expect(fresh.filter == .today, "decided once; later scans do not flip it")

        let step = try InboxReducer.reduce(fresh, .setFilter(.unread))
        #expect(step.model.settings.selectedChip == .unread && step.effects == [.saveSettings(step.model.settings)], "the chip is remembered")
        let typed = try InboxReducer.reduce(step.model, .setTypeFilter(nil))
        #expect(typed.model.settings.selectedType == nil && typed.effects == [.saveSettings(typed.model.settings)])
        #expect(try InboxReducer.reduce(typed.model, .setTypeFilter(nil)).effects.isEmpty, "no save when nothing changed")
    }

    @Test func inboxSectionsGroupByRecencyOnlyForAllAndToday() {
        let justNow = file("a.pdf", minutesAgo: 5)
        let earlierToday = file("b.pdf", minutesAgo: 20)
        let yesterday = InboxFile(path: downloads + "/c.pdf", addedAt: today.addingTimeInterval(-3600))
        let thisWeek = InboxFile(path: downloads + "/d.pdf", addedAt: today.addingTimeInterval(-4 * 24 * 3600))
        let earlier = InboxFile(path: downloads + "/e.pdf", addedAt: today.addingTimeInterval(-6 * 24 * 3600 - 1), unread: false)
        var m = model([justNow, earlierToday, yesterday, thisWeek, earlier])
        func sections() -> [(String, [String])] { m.inboxSections.map { ($0.section.rawValue, $0.files.map(\.name)) } }
        #expect(sections().map(\.0) == ["justNow", "earlierToday", "yesterday", "thisWeek", "earlier"])
        #expect(sections().map(\.1) == [["a.pdf"], ["b.pdf"], ["c.pdf"], ["d.pdf"], ["e.pdf"]])
        #expect(m.snapshot.sections == ["justNow", "earlierToday", "yesterday", "thisWeek", "earlier"])
        m.filter = .today
        #expect(sections().map(\.0) == ["justNow", "earlierToday"], "Today only has the two sections")
        m.filter = .lastHour
        #expect(m.inboxSections.isEmpty && m.snapshot.sections == nil, "1h is a flat list")
        m.filter = .unread
        #expect(m.inboxSections.isEmpty, "Unread is a flat list")
        m.filter = .all
        m.query = "pdf"
        #expect(m.inboxSections.isEmpty, "a search is a flat list")
    }

    @Test func nothingAgesOutOfTheInbox() {
        let fresh = file("fresh.pdf")
        let stale = InboxFile(path: downloads + "/stale.pdf", addedAt: now.addingTimeInterval(-400 * 24 * 3600))
        let m = model([fresh, stale])
        #expect(m.visibleFiles.map(\.name) == ["fresh.pdf", "stale.pdf"] && !m.hasOlderFiles, "the inbox is the whole folder")
    }

    @Test func foldersAreRowsLikeFiles() {
        let folder = InboxFile(path: downloads + "/shots", addedAt: now, kind: .folder)
        let m = model([folder, file("a.pdf", minutesAgo: 1)])
        #expect(m.visibleFiles.map(\.name) == ["shots", "a.pdf"])
    }

    @Test func aRedownloadOfTheSamePathIsANewArrival() throws {
        let first = file("report.pdf", minutesAgo: 30)
        var m = model([first])
        m = try InboxReducer.reduce(m, .open(.files([first.id]))).model
        #expect(m.files[first.id]?.unread == false)
        var again = first
        again.addedAt = now
        again.size = 999
        let step = try InboxReducer.reduce(m, .fileArrived(again))
        #expect(step.model.files[first.id]?.unread == true, "unread again")
        #expect(step.model.files[first.id]?.size == 999)
        #expect(step.model.history.map(\.name) == ["report.pdf"], "recorded once, at the top")
        #expect(step.effects == [.saveHistory(step.model.history)])
        // A rescan that reports the same "date added" is a change, not an arrival.
        var touched = again
        touched.size = 1000
        let same = try InboxReducer.reduce(step.model, .fileArrived(touched))
        #expect(same.model.files[first.id]?.size == 1000 && same.effects.isEmpty)
    }

    @Test func closingThePanelKeepsUnreadAndTheBadgeSetting() throws {
        let a = file("a.pdf")
        let b = file("b.pdf", minutesAgo: 1)
        var m = model([a, b], open: true)
        m = try InboxReducer.reduce(m, .panelClosed).model
        #expect(m.files[a.id]?.unread == true && m.files[b.id]?.unread == true, "closing marks nothing read")
        #expect(m.badgeCount == 2)
        m = try InboxReducer.reduce(m, .setShowBadge(false)).model
        #expect(m.badgeCount == 0 && m.unreadCount == 2, "the badge is off, the dots stay")
        #expect(m.snapshot.badge == 0 && m.snapshot.settings.showBadge == false)
    }

    @Test func markReadUnreadAndCopyName() throws {
        let a = file("a.pdf")
        var m = model([a], open: true)
        m = try InboxReducer.reduce(m, .markRead(.files([a.id]))).model
        #expect(m.files[a.id]?.unread == false)
        m = try InboxReducer.reduce(m, .markUnread(.files([a.id]))).model
        #expect(m.files[a.id]?.unread == true)
        let step = try InboxReducer.reduce(m, .copyName(.files([a.id])))
        #expect(step.effects.first == .copyToPasteboard("a.pdf"))
        #expect(step.model.toast?.message == "Name copied" && step.model.files[a.id]?.unread == false)
    }

    @Test func typeOverridesAreSavedAndReset() throws {
        var m = model([file("notes.md")])
        let step = try InboxReducer.reduce(m, .setTypeOverride(".MD ", .media))
        #expect(step.model.settings.typeOverrides == ["md": .media])
        #expect(step.model.visibleFiles[0].typeGroup(overrides: step.model.settings.typeOverrides) == .media)
        #expect(step.model.snapshot.rows[0].type == "media")
        #expect(step.effects == [.saveSettings(step.model.settings)])
        #expect(throws: EventError.invalidExtension(".")) { try InboxReducer.reduce(m, .setTypeOverride(".", .docs)) }
        m = try InboxReducer.reduce(step.model, .setTypeOverride("md", nil)).model
        #expect(m.settings.typeOverrides.isEmpty)
        m = try InboxReducer.reduce(m, .setTypeOverride("md", .apps)).model
        m = try InboxReducer.reduce(m, .resetTypeOverrides).model
        #expect(m.settings.typeOverrides.isEmpty)
    }

    @Test func showOlderFilesOpensHistoryWithProAndTheProSheetWithout() throws {
        let files = (0..<25).map { file("f\($0).pdf", minutesAgo: Double($0)) }
        var free = model(files)
        #expect(free.hasOlderFiles, "25 files in the folder, 20 on the list")
        #expect(free.snapshot.olderFiles)
        free = try InboxReducer.reduce(free, .showOlderFiles).model
        #expect(free.paywallShown && !free.historyMode)
        #expect(free.snapshot.paywall)
        free = try InboxReducer.reduce(free, .dismissPaywall).model
        #expect(!free.paywallShown)
        free = try InboxReducer.reduce(free, .showOlderFiles).model
        free = try InboxReducer.reduce(free, .panelClosed).model
        #expect(!free.paywallShown, "closing the panel drops the sheet")

        var pro = model(files)
        pro.settings.proUnlocked = true
        #expect(!pro.hasOlderFiles, "Pro lists all 25")
        pro = try InboxReducer.reduce(pro, .showOlderFiles).model
        #expect(pro.historyMode && !pro.paywallShown)
        pro = try InboxReducer.reduce(pro, .setQuery("f1")).model
        pro = try InboxReducer.reduce(pro, .setHistoryMode(false)).model
        #expect(pro.query.isEmpty, "leaving History clears the search")

        var buying = model(files)
        buying = try InboxReducer.reduce(buying, .showOlderFiles).model
        buying = try InboxReducer.reduce(buying, .proStatusChanged(true)).model
        #expect(!buying.paywallShown, "a purchase closes the sheet")
    }

    @Test func settingAFilterDropsFocusFromAHiddenRow() {
        var m = model([file("a.pdf"), file("b.png", minutesAgo: 1)], open: true)
        m.focused = downloads + "/b.png"
        m.selection = [m.focused!]
        spec.given(m).when(.setTypeFilter(.docs)).then { result in
            #expect(result.model.focused == nil && result.model.selection.isEmpty)
        }
        m.focused = downloads + "/a.pdf"
        m.selection = [m.focused!]
        spec.given(m).when(.setTypeFilter(.docs)).then { result in
            #expect(result.model.focused == downloads + "/a.pdf")
        }
    }

    @Test func changingThePrimaryFolderSwapsItsRows() {
        var m = model([file("a.pdf"), file("b.zip")])
        m.panelOpen = true
        m.focused = m.files.keys.sorted().first
        let inbox = "/Users/sample/Inbox"
        spec.given(m).when(.folderAccessChanged(.downloads, .granted, path: inbox)).then { result in
            #expect(result.model.downloads?.path == inbox)
            #expect(result.model.downloads?.title == "Inbox")
            #expect(result.model.visibleFiles.isEmpty)
            #expect(result.model.focused == nil)
            #expect(result.lastNext.effects == [.startWatching([result.model.downloads!])])
        }
        // Cancelling the picker changes nothing.
        spec.given(m).when(.folderAccessChanged(.downloads, .denied, path: nil)).then { result in
            #expect(result.model.downloads?.path == downloads)
            #expect(result.model.visibleFiles.map(\.name) == ["a.pdf", "b.zip"])
            #expect(result.lastNext.effects.isEmpty)
        }
    }

    @Test func movingThePrimaryFolderOntoAnExtraFolderFoldsThemTogether() {
        var m = model([file("a.pdf"), file("scan.pdf", folder: scans)])
        m.settings.proUnlocked = true
        m.settings.extraFolders = [scans]
        m.folders.append(.custom(scans))
        spec.given(m).when(.folderAccessChanged(.downloads, .granted, path: scans)).then { result in
            #expect(result.model.folders.map(\.kind) == [.downloads])
            #expect(result.model.settings.extraFolders.isEmpty)
            #expect(result.model.visibleFiles.map(\.name) == ["scan.pdf"])
            #expect(result.lastNext.effects == [
                .stopWatching(.custom(scans)),
                .saveSettings(result.model.settings),
                .startWatching([result.model.downloads!]),
            ])
        }
    }

    @Test func duplicateNamesAreFlagged() {
        let m = model([file("a.pdf"), file("a.pdf", folder: scans)])
        var withScans = m
        withScans.folders.append(.custom(scans))
        #expect(m.duplicateNames.isEmpty)
        #expect(withScans.duplicateNames == ["a.pdf"])
        #expect(withScans.snapshot.rows.map(\.showFolder) == [true, true])
    }

    // MARK: Selection and focus

    @Test func selectionModesBehaveLikeFinder() {
        let files = (0..<5).map { file("f\($0).pdf", minutesAgo: Double($0)) }
        let ids = files.map(\.id)
        spec.given(model(files, open: true))
            .when(.select(ids[1], .replace), .select(ids[3], .toggle), .select(ids[0], .toggle))
            .then { result in
                #expect(result.model.selection == [ids[1], ids[3], ids[0]])
                #expect(result.model.focused == ids[0])
            }
        spec.given(model(files, open: true))
            .when(.select(ids[1], .replace), .select(ids[3], .range))
            .then { result in
                #expect(result.model.selection == [ids[1], ids[2], ids[3]])
            }
        spec.given(model(files, open: true))
            .when(.select(ids[1], .replace), .select(ids[3], .range), .clearSelection)
            .then { #expect($0.model.selection.isEmpty) }
    }

    @Test func arrowKeysMoveFocusAndSingleSelection() {
        let files = (0..<3).map { file("f\($0).pdf", minutesAgo: Double($0)) }
        let ids = files.map(\.id)
        spec.given(model(files, open: true)).when(.moveFocus(.down), .moveFocus(.down), .moveFocus(.down), .moveFocus(.up)).then { result in
            #expect(result.model.focused == ids[1])
            #expect(result.model.selection == [ids[1]])
        }
        spec.given(model(files, open: true)).when(.moveFocus(.up)).then { #expect($0.model.focused == ids[2]) }
        spec.given(model(open: true)).when(.moveFocus(.down)).then(assertThatNext(
            hasNoModel(), hasExactlyEffects([.reject(.nothingToFocus)]), failFunction: recordFailure))
    }

    @Test func unknownFilesAreRejectedWithTypedErrors() {
        spec.given(model()).when(.select("/nope", .replace)).then(assertThatNext(
            hasNoModel(), hasExactlyEffects([.reject(.unknownFile("/nope"))]), failFunction: recordFailure))
        spec.given(model()).when(.open(.selection)).then(assertThatNext(
            hasNoModel(), hasExactlyEffects([.reject(.nothingSelected)]), failFunction: recordFailure))
        spec.given(model()).when(.open(.files(["/nope"]))).then(assertThatNext(
            hasNoModel(), hasExactlyEffects([.reject(.unknownFile("/nope"))]), failFunction: recordFailure))
    }

    // MARK: Actions

    @Test func openMarksReadAndAsksTheSystemToOpen() {
        let f = file("a.pdf")
        let m = model([f])
        spec.given(m).when(.open(.files([f.id]))).then { result in
            #expect(result.model.files[f.id]?.unread == false)
            #expect(result.model.badgeCount == 0)
            #expect(result.lastNext.effects == [.openFiles([f])])
        }
    }

    @Test func actionsFallBackToSelectionThenFocus() {
        let a = file("a.pdf")
        let b = file("b.pdf", minutesAgo: 1)
        var m = model([a, b], open: true)
        m.focused = b.id
        spec.given(m).when(.reveal(.selection)).then { result in
            #expect(result.lastNext.effects == [.reveal([b])])
        }
        m.selection = [a.id, b.id]
        spec.given(m).when(.quickLook(.selection)).then { result in
            // On-screen order: newest first.
            #expect(result.lastNext.effects == [.quickLook([a, b])])
        }
    }

    @Test func copyPathCopiesPosixPathsAndToasts() {
        let f = file("a b.pdf")
        spec.given(model([f])).when(.copyPath(.files([f.id]))).then { result in
            #expect(result.lastNext.effects.first == .copyToPasteboard(downloads + "/a b.pdf"))
            #expect(result.model.toast?.message == "Path copied")
            #expect(result.lastNext.effects.last == .scheduleToastDismiss(token: result.model.toast!.token))
        }
    }

    @Test func moveToAsksForADestinationThenMoves() {
        let f = file("a.pdf")
        spec.given(model([f])).when(.moveTo(.files([f.id]))).then { result in
            #expect(result.model.pendingMove == [f.id])
            #expect(result.lastNext.effects == [.chooseDestination])
        }
        spec.given(model([f])).when(.moveTo(.files([f.id])), .destinationChosen("/Users/sample/Documents/Invoices")).then { result in
            #expect(result.model.pendingMove == nil)
            #expect(result.lastNext.effects == [.move([f], to: "/Users/sample/Documents/Invoices")])
        }
        spec.given(model([f])).when(.moveTo(.files([f.id])), .moveCancelled).then { result in
            #expect(result.model.pendingMove == nil)
            #expect(result.lastNext.effects.isEmpty)
        }
        spec.given(model([f])).when(.destinationChosen("/x")).then(assertThatNext(
            hasNoModel(), hasExactlyEffects([.reject(.noPendingMove)]), failFunction: recordFailure))
        spec.given(model([f])).when(.moved(succeeded: [f.id], failed: [], destination: "/Users/sample/Documents/Invoices")).then { result in
            #expect(result.model.files.isEmpty)
            #expect(result.model.toast?.message == "Moved a.pdf to Invoices")
        }
    }

    @Test func unzipOnlyAcceptsZipArchives() {
        let zip = file("a.zip")
        let tar = file("b.tar", minutesAgo: 1)
        spec.given(model([zip, tar])).when(.unzip(.files([zip.id]))).then { result in
            #expect(result.lastNext.effects == [.unzip(zip)])
            #expect(result.model.files[zip.id]?.unread == false)
        }
        spec.given(model([zip, tar])).when(.unzip(.files([zip.id, tar.id]))).then(assertThatNext(
            hasNoModel(), hasExactlyEffects([.reject(.notAZip(tar.id))]), failFunction: recordFailure))
        spec.given(model([zip])).when(.unzipped(zip.id, outputPath: downloads + "/a")).then {
            #expect($0.model.toast?.message == "Extracted a.zip to a")
        }
    }

    @Test func trashRemovesRowsAndOffersUndoUntilItExpires() {
        let a = file("a.pdf")
        let b = file("b.pdf", minutesAgo: 1)
        let items = [TrashedItem(file: a, trashedPath: "/T/a.pdf")]
        spec.given(model([a, b], open: true)).when(.trash(.files([a.id]))).then { result in
            #expect(result.model.visibleFiles.map(\.name) == ["b.pdf"])
            #expect(result.model.undo?.ready == false)
            #expect(result.lastNext.effects == [.trash(token: 1, [a])])
        }
        // Undo is not ready until the file system reports where the files went.
        spec.given(model([a, b], open: true)).when(.trash(.files([a.id])), .undoTrash).then(assertThatNext(
            hasNoModel(), hasExactlyEffects([.reject(.nothingToUndo)]), failFunction: recordFailure))
        spec.given(model([a, b], open: true)).when(.trash(.files([a.id])), .trashed(token: 1, items: items)).then { result in
            #expect(result.model.undo?.ready == true)
            #expect(result.lastNext.effects == [.scheduleUndoExpiry(token: 1)])
        }
        spec.given(model([a, b], open: true))
            .when(.trash(.files([a.id])), .trashed(token: 1, items: items), .undoTrash)
            .then { result in
                #expect(result.model.undo == nil)
                #expect(result.lastNext.effects == [.restore(token: 1, items)])
            }
        spec.given(model([a, b], open: true))
            .when(.trash(.files([a.id])), .trashed(token: 1, items: items), .undoTrash, .restored(token: 1, files: [a]))
            .then { result in
                #expect(result.model.visibleFiles.map(\.name) == ["a.pdf", "b.pdf"])
                #expect(result.model.files[a.id]?.unread == false)
            }
        spec.given(model([a, b], open: true))
            .when(.trash(.files([a.id])), .trashed(token: 1, items: items), .undoExpired(token: 1), .undoTrash)
            .then(assertThatNext(hasNoModel(), hasExactlyEffects([.reject(.nothingToUndo)]), failFunction: recordFailure))
        // A stale expiry (from an earlier trash) must not cancel a newer undo.
        spec.given(model([a, b], open: true))
            .when(.trash(.files([a.id])), .trash(.files([b.id])), .trashed(token: 2, items: items), .undoExpired(token: 1))
            .then { #expect($0.model.undo?.token == 2) }
    }

    @Test func failedTrashPutsTheRowsBack() {
        let a = file("a.pdf")
        spec.given(model([a], open: true)).when(.trash(.files([a.id])), .trashFailed(token: 1, message: "Nope")).then { result in
            #expect(result.model.visibleFiles.map(\.name) == ["a.pdf"])
            #expect(result.model.undo == nil)
            #expect(result.model.toast == Toast(token: 2, message: "Nope", isError: true))
        }
    }

    // MARK: Vanished files

    @Test func vanishedFilesLeaveTheListAndClearFocus() {
        let a = file("a.pdf")
        var m = model([a], open: true)
        m.focused = a.id
        m.selection = [a.id]
        spec.given(m).when(.fileRemoved(a.id)).then { result in
            #expect(result.model.files.isEmpty)
            #expect(result.model.focused == nil && result.model.selection.isEmpty && result.model.badgeCount == 0)
        }
        spec.given(model([a], open: true)).when(.fileRemoved(a.id), .open(.files([a.id]))).then(assertThatNext(
            hasNoModel(), hasExactlyEffects([.reject(.unknownFile(a.id))]), failFunction: recordFailure))
        spec.given(model([a], open: true)).when(.fileRemoved(a.id), .fileArrived(a)).then {
            #expect($0.model.files[a.id]?.unread == true, "a file that comes back is new again")
        }
        spec.given(model()).when(.fileRemoved("/nope")).then(assertThatNext(hasNoEffects(), failFunction: recordFailure))
    }

    // MARK: Empty states

    @Test func emptyStatesFollowAccessAndRows() {
        var m = model()
        #expect(m.emptyState == .nothingNew)
        m.folders[0].access = .denied
        #expect(m.emptyState == .needsAccess)
        spec.given(m).when(.grantAccess(.downloads)).then(assertThatNext(
            hasExactlyEffects([.requestAccess(.downloads)]), failFunction: recordFailure))
        spec.given(m).when(.folderAccessChanged(.downloads, .granted, path: nil)).then { result in
            #expect(result.model.emptyState == .nothingNew)
            #expect(result.lastNext.effects == [.startWatching([result.model.folders[0]])])
        }
    }

    // MARK: Settings

    @Test func settingsEventsPersistAndReachTheSystem() {
        let hotkey = Hotkey.parse("cmd+shift+space")!
        spec.given(model()).when(.setHotkey(hotkey)).then { result in
            #expect(result.model.settings.hotkey == hotkey)
            #expect(result.lastNext.effects == [.registerHotkey(hotkey), .saveSettings(result.model.settings)])
        }
        spec.given(model()).when(.setLaunchAtLogin(true)).then(assertThatNext(
            hasNoModel(), hasExactlyEffects([.setLaunchAtLogin(true)]), failFunction: recordFailure))
        spec.given(model()).when(.launchAtLoginChanged(true)).then {
            #expect($0.model.settings.launchAtLogin)
        }
        spec.given(model()).when(.setNotifications(true)).then { result in
            #expect(result.model.settings.notificationsEnabled)
            #expect(result.lastNext.effects == [.saveSettings(result.model.settings), .requestNotificationPermission])
        }
        spec.given(model()).when(.setLanguage(.ja)).then { result in
            #expect(result.model.settings.language == .ja)
            #expect(result.lastNext.effects == [.saveSettings(result.model.settings)])
            #expect(result.model.snapshot.settings.language == "ja")
        }
        var german = model()
        german.settings.language = .de
        spec.given(german).when(.setLanguage(nil)).then { result in
            #expect(result.model.settings.language == nil)
            #expect(result.model.snapshot.settings.language == nil)
        }
        spec.given(model()).when(.unlockPro).then(assertThatNext(
            hasNoModel(), hasExactlyEffects([.purchasePro]), failFunction: recordFailure))
        spec.given(model()).when(.proStatusChanged(true)).then { result in
            #expect(result.model.settings.proUnlocked)
            #expect(result.lastNext.effects.first == .saveSettings(result.model.settings))
            #expect(result.model.toast?.message == "Pro unlocked. Thank you!")
        }
    }

    @Test func aWholeTriageSession() {
        let invoice = file("invoice.pdf", source: .web(host: "stripe.com"))
        let photo = file("photo.heic", minutesAgo: 1, source: .airDrop)
        let archive = file("build.zip", minutesAgo: 2)
        spec.given(model([invoice, photo, archive]))
            .when(.hotkeyPressed, .setTypeFilter(.docs), .moveFocus(.down), .open(.selection), .setTypeFilter(nil),
                  .select(photo.id, .replace), .trash(.selection), .trashed(token: 1, items: [TrashedItem(file: photo, trashedPath: "/T/p")]),
                  .select(archive.id, .replace), .unzip(.selection), .panelClosed)
            .then { result in
                #expect(result.model.visibleFiles.map(\.name) == ["invoice.pdf", "build.zip"])
                #expect(result.model.unreadCount == 0)
                #expect(result.model.badgeCount == 0)
                #expect(result.model.undo?.ready == true)
                #expect(!result.model.panelOpen)
                #expect(result.model.snapshot.rows.map(\.source) == ["stripe.com", nil])
            }
    }
}
