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
let desktop = "/Users/sample/Desktop"
let today = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 23))!

func file(_ name: String, minutesAgo: Double = 0, size: Int64 = 1024, folder: String = downloads,
          source: FileSource = .unknown, unread: Bool = true) -> InboxFile {
    InboxFile(path: folder + "/" + name, size: size, addedAt: today.addingTimeInterval(3600 * 9 - minutesAgo * 60),
              source: source, unread: unread)
}

func model(_ files: [InboxFile] = [], open: Bool = false) -> InboxModel {
    var model = InboxModel(files: files, folders: WatchedFolder.sample(), today: today)
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

        let settings = Settings(watchDesktop: true, proUnlocked: false)
        spec.given(model()).when(.settingsLoaded(settings, folders: WatchedFolder.sample())).then { result in
            #expect(result.model.folder(.desktop)?.enabled == true)
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

    @Test func arrivalWhilePanelOpenIsUnreadButNotBadged() {
        spec.given(model(open: true)).when(.fileArrived(file("a.pdf"))).then { result in
            #expect(result.model.badgeCount == 0)
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

    @Test func openingThePanelClearsTheBadgeAndSelectsNothing() {
        let read = file("seen.pdf", unread: false)
        let unread = file("new.pdf", minutesAgo: 3)
        var m = model([read, unread])
        m.badgeIDs = [unread.id]
        spec.given(m).when(.panelOpened).then { result in
            #expect(result.model.panelOpen)
            #expect(result.model.badgeCount == 0)
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
        var m = model([file("a.pdf"), file("b.pdf", minutesAgo: 1)])
        m.badgeIDs = Set(m.files.keys)
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

    @Test func filtersMatchKindsAndToday() {
        let yesterday = InboxFile(path: downloads + "/old.pdf", addedAt: today.addingTimeInterval(-3600))
        let files = [file("a.pdf"), file("b.png", minutesAgo: 1), file("c.zip", minutesAgo: 2),
                     file("d.dmg", minutesAgo: 3), file("e.txt", minutesAgo: 4), yesterday]
        var m = model(files)
        func names(_ filter: FileFilter) -> [String] {
            m.filter = filter
            return m.visibleFiles.map(\.name)
        }
        #expect(names(.all).count == 6)
        #expect(names(.today) == ["a.pdf", "b.png", "c.zip", "d.dmg", "e.txt"])
        #expect(names(.pdf) == ["a.pdf", "old.pdf"])
        #expect(names(.images) == ["b.png"])
        #expect(names(.other) == ["c.zip", "d.dmg", "e.txt"], "archives, installers and plain files share the Other chip")
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
        spec.given(m).when(.setFilter(.pdf)).then { result in
            #expect(result.model.focused == nil && result.model.selection.isEmpty)
        }
        m.focused = downloads + "/a.pdf"
        m.selection = [m.focused!]
        spec.given(m).when(.setFilter(.pdf)).then { result in
            #expect(result.model.focused == downloads + "/a.pdf")
        }
    }

    @Test func desktopFilesOnlyShowWhenDesktopIsWatched() {
        let m = model([file("a.pdf"), file("note.txt", folder: desktop)])
        #expect(m.visibleFiles.map(\.name) == ["a.pdf"])
        spec.given(m).when(.setWatchDesktop(true)).then { result in
            #expect(result.model.visibleFiles.map(\.name) == ["a.pdf", "note.txt"])
            #expect(result.lastNext.effects == [.saveSettings(result.model.settings), .requestAccess(.desktop)])
        }
    }

    @Test func duplicateNamesAreFlagged() {
        let m = model([file("a.pdf"), file("a.pdf", folder: desktop)])
        var withDesktop = m
        withDesktop.folders[1].enabled = true
        #expect(m.duplicateNames.isEmpty)
        #expect(withDesktop.duplicateNames == ["a.pdf"])
        #expect(withDesktop.snapshot.rows.map(\.showFolder) == [true, true])
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
        var m = model([f])
        m.badgeIDs = [f.id]
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
        m.badgeIDs = [a.id]
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
            .when(.hotkeyPressed, .setFilter(.pdf), .moveFocus(.down), .open(.selection), .setFilter(.all),
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
