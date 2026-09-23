import Foundation

/// What the parser needs from its caller: where the watched folders are (to build paths for
/// `arrive`), how to turn a file name into an id, and the clock for arrival times.
public struct ParseContext: Sendable {
    public var downloadsPath: String
    public var desktopPath: String
    public var now: Date
    /// Resolves a bare name (or a path) to a known file id. Returns nil when unknown.
    public var resolveFile: @Sendable (String) -> FileID?
    /// Resolves a rule name or id to the rule's id.
    public var resolveRule: @Sendable (String) -> String? = { _ in nil }
    /// The rule with this id, for edits.
    public var rule: @Sendable (String) -> Rule? = { _ in nil }
    /// Resolves an extra folder's name to its path.
    public var resolveFolder: @Sendable (String) -> String? = { _ in nil }

    public init(
        downloadsPath: String,
        desktopPath: String,
        now: Date = Date(),
        resolveFile: @escaping @Sendable (String) -> FileID?
    ) {
        self.downloadsPath = downloadsPath
        self.desktopPath = desktopPath
        self.now = now
        self.resolveFile = resolveFile
    }

    /// A context bound to a model: names resolve against the files the model knows.
    public init(model: InboxModel, now: Date = Date()) {
        let files = model.files
        let downloads = model.folder(.downloads)?.path ?? "/Downloads"
        let desktop = model.folder(.desktop)?.path ?? "/Desktop"
        let history = model.history
        self.init(downloadsPath: downloads, desktopPath: desktop, now: now) { name in
            if files[name] != nil { return name }
            let matches = files.values.filter { $0.name == name }
            if matches.count == 1 { return matches[0].id }
            // History rows can be addressed too, so `reveal`/`open` on them give the typed error.
            let past = history.filter { $0.name == name }
            return past.count == 1 ? past[0].id : nil
        }
        let rules = model.settings.rules
        resolveRule = { name in
            if let byID = rules.first(where: { $0.id == name }) { return byID.id }
            let matches = rules.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            return matches.count == 1 ? matches[0].id : nil
        }
        rule = { id in rules.first { $0.id == id } }
        let custom = model.customFolders
        resolveFolder = { name in
            let matches = custom.filter { $0.title.caseInsensitiveCompare(name) == .orderedSame }
            return matches.count == 1 ? matches[0].path : nil
        }
    }
}

/// Text grammar for events, shared by the CLI and the debug bridge so agents use one vocabulary.
extension Event {
    public static let grammar: [(command: String, description: String)] = [
        ("panel open|close", "open or close the popover (what the status item click does)"),
        ("hotkey", "press the global hotkey: opens the panel focused on the first unread row, or closes it"),
        ("filter <name>", "all, today, pdf, images, archives, installers"),
        ("select <file> [toggle|range]", "click, ⌘-click or ⇧-click a row"),
        ("focus <file>", "move keyboard focus to a row"),
        ("up | down", "move focus (and single selection) with the arrow keys"),
        ("deselect", "clear the selection"),
        ("open [file ...]", "open with the default app (Return); no argument acts on the selection"),
        ("ql [file ...]", "Quick Look (Space)"),
        ("reveal [file ...]", "reveal in Finder (⌘R)"),
        ("copy [file ...]", "copy POSIX path (⌘C)"),
        ("move [file ...]", "Move to… (⌘M); the destination comes from the folder panel or `dest`"),
        ("unzip [file ...]", "extract a .zip beside the archive (⌘U)"),
        ("trash [file ...]", "move to Trash with a 5 s undo (⌫)"),
        ("undo", "put the last trashed files back"),
        ("dismiss <file>", "remove a greyed-out row whose file vanished"),
        ("seen", "mark all rows seen and clear the badge"),
        ("finder [downloads|desktop]", "open the watched folder in Finder"),
        ("desktop on|off", "watch the Desktop folder too"),
        ("login on|off", "launch at login"),
        ("notify on|off", "notification on new file"),
        ("language en|ja|de|fr|system", "UI language (system: follow macOS); applies at the next launch"),
        ("hotkey-set <combo>", "e.g. ctrl+alt+d, cmd+shift+space"),
        ("grant downloads|desktop", "ask for folder access"),
        ("unlock", "buy Pro through the store"),
        ("restore", "restore a Pro purchase"),
        ("pro on|off", "what the store reported (headless: sets Pro directly)"),
        ("folder add [path]", "Pro: watch another folder (no path: ask with the folder panel)"),
        ("folder remove <name|path>", "Pro: stop watching an extra folder"),
        ("history on|off", "Pro: list every arrival instead of the current folder contents"),
        ("history clear", "Pro: forget the recorded arrivals"),
        ("search [text]", "filter rows by name; no text clears the search"),
        ("rule add <name> [kind=pdf] [host=stripe.com] [name=invoice] [ext=dmg] [on=arrival|opened] then move <path>|trash|seen|suggest-trash", "Pro: add a rule"),
        ("rule remove|enable|disable <name>", "Pro: manage a rule"),
        ("accept", "do what the current suggestion offers"),
        ("dismiss-suggestion", "drop the current suggestion"),
        ("today <yyyy-mm-dd>", "set the day used by the Today filter"),
        ("arrive <file> [size] [host|airdrop]", "a file lands in Downloads (prefix desktop/ for the Desktop); size like 120k, 2m"),
        ("vanish <file>", "a listed file disappears from its folder"),
    ]

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case unknownCommand(String)
        case missingArgument(String)
        case invalidArgument(String)
        case unknownFile(String)
        case unknownRule(String)

        public var description: String {
            switch self {
            case .empty: return "empty command"
            case .unknownCommand(let c): return "unknown command '\(c)'"
            case .missingArgument(let c): return "'\(c)' needs an argument"
            case .invalidArgument(let v): return "invalid argument '\(v)'"
            case .unknownFile(let n): return "no file named '\(n)'"
            case .unknownRule(let n): return "no rule named '\(n)'"
            }
        }
    }

    public static func parse(_ line: String, context: ParseContext) throws(ParseError) -> Event {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts[0].lowercased()
        let argument = parts.count > 1 ? parts[1] : nil
        let words = argument.map { $0.split(separator: " ").map(String.init) } ?? []

        func required() throws(ParseError) -> String {
            guard let argument else { throw .missingArgument(command) }
            return argument
        }
        func onOff() throws(ParseError) -> Bool {
            switch try required().lowercased() {
            case "on", "true", "yes": return true
            case "off", "false", "no": return false
            case let other: throw .invalidArgument(other)
            }
        }
        func file(_ name: String) throws(ParseError) -> FileID {
            guard let id = context.resolveFile(name) else { throw .unknownFile(name) }
            return id
        }
        func target(_ names: [String]) throws(ParseError) -> Target {
            if names.isEmpty { return .selection }
            var ids: [FileID] = []
            for name in names { ids.append(try file(name)) }
            return .files(ids)
        }
        func folder(_ name: String?) throws(ParseError) -> FolderKind {
            guard let name else { return .downloads }
            if name.hasPrefix("/") { return .custom(name) }
            let kind = FolderKind(name.lowercased())
            guard FolderKind.standardKinds.contains(kind) else { throw .invalidArgument(name) }
            return kind
        }
        func rule(_ name: String) throws(ParseError) -> String {
            guard let id = context.resolveRule(name) else { throw .unknownRule(name) }
            return id
        }

        switch command {
        case "panel":
            switch try required().lowercased() {
            case "open": return .panelOpened
            case "close": return .panelClosed
            case let other: throw .invalidArgument(other)
            }
        case "hotkey": return .hotkeyPressed
        case "filter":
            let value = try required().lowercased()
            guard let filter = FileFilter(rawValue: value) else { throw .invalidArgument(value) }
            return .setFilter(filter)
        case "select":
            guard let name = words.first else { throw .missingArgument(command) }
            var mode = SelectionMode.replace
            if words.count > 1 {
                guard let parsed = SelectionMode(rawValue: words[1].lowercased()) else { throw .invalidArgument(words[1]) }
                mode = parsed
            }
            return .select(try file(name), mode)
        case "focus": return .focus(try file(try required()))
        case "up": return .moveFocus(.up)
        case "down": return .moveFocus(.down)
        case "deselect": return .clearSelection
        case "open": return .open(try target(words))
        case "ql", "quicklook", "preview": return .quickLook(try target(words))
        case "reveal": return .reveal(try target(words))
        case "copy": return .copyPath(try target(words))
        case "move": return .moveTo(try target(words))
        case "unzip": return .unzip(try target(words))
        case "trash", "delete": return .trash(try target(words))
        case "undo": return .undoTrash
        case "dismiss": return .dismiss(try file(try required()))
        case "seen": return .markAllSeen
        case "finder": return .openWatchedFolder(try folder(argument))
        case "desktop": return .setWatchDesktop(try onOff())
        case "login": return .setLaunchAtLogin(try onOff())
        case "notify": return .setNotifications(try onOff())
        case "language":
            let code = try required().lowercased()
            if code == "system" { return .setLanguage(nil) }
            guard let language = AppLanguage(rawValue: code) else { throw .invalidArgument(code) }
            return .setLanguage(language)
        case "hotkey-set":
            let combo = try required()
            guard let hotkey = Hotkey.parse(combo) else { throw .invalidArgument(combo) }
            return .setHotkey(hotkey)
        case "grant": return .grantAccess(try folder(argument))
        case "unlock": return .unlockPro
        case "restore": return .restorePurchases
        case "pro": return .proStatusChanged(try onOff())
        case "folder":
            guard let verb = words.first?.lowercased() else { throw .missingArgument(command) }
            let rest = words.dropFirst().joined(separator: " ")
            switch verb {
            case "add":
                return rest.isEmpty ? .addFolder : .folderChosen(rest)
            case "remove":
                guard !rest.isEmpty else { throw .missingArgument("folder remove") }
                if rest.hasPrefix("/") { return .removeFolder(.custom(rest)) }
                guard let path = context.resolveFolder(rest) else { throw .invalidArgument(rest) }
                return .removeFolder(.custom(path))
            case let other: throw .invalidArgument(other)
            }
        case "history":
            switch try required().lowercased() {
            case "on": return .setHistoryMode(true)
            case "off": return .setHistoryMode(false)
            case "clear": return .clearHistory
            case let other: throw .invalidArgument(other)
            }
        case "search": return .setQuery(argument ?? "")
        case "rule":
            guard let verb = words.first?.lowercased() else { throw .missingArgument(command) }
            let rest = Array(words.dropFirst())
            switch verb {
            case "add": return .addRule(try Self.parseRule(rest))
            case "remove":
                return .removeRule(try rule(rest.joined(separator: " ")))
            case "enable", "disable":
                let id = try rule(rest.joined(separator: " "))
                guard var existing = context.rule(id) else { throw .unknownRule(id) }
                existing.enabled = verb == "enable"
                return .updateRule(existing)
            case let other: throw .invalidArgument(other)
            }
        case "accept": return .acceptSuggestion
        case "dismiss-suggestion": return .dismissSuggestion
        case "today":
            let text = try required()
            guard let date = Self.parseDay(text) else { throw .invalidArgument(text) }
            return .setToday(date)
        case "arrive":
            guard let name = words.first else { throw .missingArgument(command) }
            var path: String
            if name.lowercased().hasPrefix("desktop/") {
                path = context.desktopPath + "/" + String(name.dropFirst("desktop/".count))
            } else if name.hasPrefix("/") {
                path = name
            } else {
                path = context.downloadsPath + "/" + name
            }
            var size: Int64 = 0
            var source = FileSource.unknown
            for extra in words.dropFirst() {
                if let bytes = Self.parseSize(extra) {
                    size = bytes
                } else if extra.lowercased() == "airdrop" {
                    source = .airDrop
                } else if extra.contains(".") {
                    source = .web(host: extra.lowercased())
                } else {
                    throw .invalidArgument(extra)
                }
            }
            return .fileArrived(InboxFile(path: path, size: size, addedAt: context.now, source: source))
        case "vanish": return .fileRemoved(try file(try required()))
        default: throw .unknownCommand(command)
        }
    }

    /// Text form that round-trips through `parse` (using file names for ids).
    public var commandLine: String {
        func names(_ target: Target) -> String {
            switch target {
            case .selection: return ""
            case .files(let ids): return " " + ids.map { ($0 as NSString).lastPathComponent }.joined(separator: " ")
            }
        }
        func name(_ id: FileID) -> String { (id as NSString).lastPathComponent }
        switch self {
        case .panelOpened: return "panel open"
        case .panelClosed: return "panel close"
        case .hotkeyPressed: return "hotkey"
        case .setFilter(let filter): return "filter \(filter.rawValue)"
        case .select(let id, let mode): return "select \(name(id))" + (mode == .replace ? "" : " \(mode.rawValue)")
        case .focus(let id): return "focus \(name(id))"
        case .moveFocus(let direction): return direction.rawValue
        case .clearSelection: return "deselect"
        case .open(let target): return "open" + names(target)
        case .quickLook(let target): return "ql" + names(target)
        case .reveal(let target): return "reveal" + names(target)
        case .copyPath(let target): return "copy" + names(target)
        case .moveTo(let target): return "move" + names(target)
        case .unzip(let target): return "unzip" + names(target)
        case .trash(let target): return "trash" + names(target)
        case .undoTrash: return "undo"
        case .dismiss(let id): return "dismiss \(name(id))"
        case .markAllSeen: return "seen"
        case .openWatchedFolder(let kind): return "finder \(kind.rawValue)"
        case .dismissToast: return "dismiss-toast"
        case .setWatchDesktop(let on): return "desktop \(on ? "on" : "off")"
        case .setLaunchAtLogin(let on): return "login \(on ? "on" : "off")"
        case .setNotifications(let on): return "notify \(on ? "on" : "off")"
        case .setLanguage(let language): return "language \(language?.rawValue ?? "system")"
        case .setHotkey(let hotkey): return "hotkey-set \(hotkey.commandLine)"
        case .grantAccess(let kind): return "grant \(kind.rawValue)"
        case .unlockPro: return "unlock"
        case .restorePurchases: return "restore"
        case .proStatusChanged(let on): return "pro \(on ? "on" : "off")"
        case .addFolder: return "folder add"
        case .folderChosen(let path): return "folder add \(path)"
        case .removeFolder(let kind): return "folder remove \(kind.rawValue)"
        case .setHistoryMode(let on): return "history \(on ? "on" : "off")"
        case .clearHistory: return "history clear"
        case .setQuery(let text): return text.isEmpty ? "search" : "search \(text)"
        case .addRule(let rule): return "rule add \(Self.ruleText(rule))"
        case .updateRule(let rule): return "rule \(rule.enabled ? "enable" : "disable") \(rule.name)"
        case .removeRule(let id): return "rule remove \(id)"
        case .acceptSuggestion: return "accept"
        case .dismissSuggestion: return "dismiss-suggestion"
        case .folderChooserCancelled: return "folder-cancelled"
        case .historyLoaded(let entries): return "history-loaded \(entries.count)"
        case .purchaseFailed(let message): return "purchase-failed \(message)"
        case .setToday(let date): return "today \(Self.formatDay(date))"
        case .fileArrived(let file):
            var line = "arrive \(file.name) \(file.size)"
            if let label = file.source.label { line += " \(label)" }
            return line
        case .fileRemoved(let id): return "vanish \(name(id))"
        // Outcomes are produced by services, never typed by a user or agent.
        case .launched: return "launched"
        case .settingsLoaded: return "settings-loaded"
        case .folderAccessChanged(let kind, let access, _): return "access \(kind.rawValue) \(access.rawValue)"
        case .scanCompleted(let kind, let files): return "scanned \(kind.rawValue) \(files.count)"
        case .fileChanged(let file): return "changed \(file.name)"
        case .destinationChosen(let path): return "destination \(path)"
        case .moveCancelled: return "move-cancelled"
        case .moved(let ok, let failed, _): return "moved \(ok.count) failed \(failed.count)"
        case .unzipped(let id, _): return "unzipped \(name(id))"
        case .trashed(let token, let items): return "trashed #\(token) \(items.count)"
        case .trashFailed(let token, _): return "trash-failed #\(token)"
        case .restored(let token, let files): return "restored #\(token) \(files.count)"
        case .undoExpired(let token): return "undo-expired #\(token)"
        case .toastExpired(let token): return "toast-expired #\(token)"
        case .actionFailed(_, let message): return "failed \(message)"
        case .launchAtLoginChanged(let on): return "login-changed \(on)"
        }
    }

    /// `<name> [kind=..] [host=..] [name=..] [ext=..] [on=arrival|opened] then <action>`.
    /// The rule name is every word before the first `key=value` or `then`.
    static func parseRule(_ words: [String]) throws(ParseError) -> Rule {
        guard let thenIndex = words.firstIndex(where: { $0.lowercased() == "then" }) else {
            throw .missingArgument("rule add … then")
        }
        let head = Array(words[..<thenIndex])
        let tail = Array(words[(thenIndex + 1)...])
        var nameWords: [String] = []
        var match = RuleMatch()
        var trigger = RuleTrigger.arrival
        for word in head {
            guard let equals = word.firstIndex(of: "=") else {
                guard match == RuleMatch(), trigger == .arrival else { throw .invalidArgument(word) }
                nameWords.append(word)
                continue
            }
            let key = word[..<equals].lowercased()
            let value = String(word[word.index(after: equals)...])
            switch key {
            case "kind":
                guard let kind = FileKind(rawValue: value.lowercased()) else { throw .invalidArgument(word) }
                match.kind = kind
            case "host": match.host = value.lowercased()
            case "name": match.nameContains = value
            case "ext": match.fileExtension = value.lowercased()
            case "on":
                guard let parsed = RuleTrigger(rawValue: value.lowercased()) else { throw .invalidArgument(word) }
                trigger = parsed
            default: throw .invalidArgument(word)
            }
        }
        guard !nameWords.isEmpty else { throw .missingArgument("rule add <name>") }
        let action: RuleAction
        switch tail.first?.lowercased() {
        case "move":
            let path = tail.dropFirst().joined(separator: " ")
            guard path.hasPrefix("/") else { throw .invalidArgument("move needs an absolute path") }
            action = .moveTo(path)
        case "trash": action = .trash
        case "seen": action = .markSeen
        case "suggest-trash": action = .suggestTrash
        default: throw .invalidArgument(tail.joined(separator: " "))
        }
        return Rule(name: nameWords.joined(separator: " "), trigger: trigger, match: match, action: action)
    }

    static func ruleText(_ rule: Rule) -> String {
        var parts = [rule.name]
        if let kind = rule.match.kind { parts.append("kind=\(kind.rawValue)") }
        if let host = rule.match.host { parts.append("host=\(host)") }
        if let name = rule.match.nameContains { parts.append("name=\(name)") }
        if let ext = rule.match.fileExtension { parts.append("ext=\(ext)") }
        if rule.trigger != .arrival { parts.append("on=\(rule.trigger.rawValue)") }
        parts.append("then")
        switch rule.action {
        case .moveTo(let path): parts.append("move \(path)")
        case .trash: parts.append("trash")
        case .markSeen: parts.append("seen")
        case .suggestTrash: parts.append("suggest-trash")
        }
        return parts.joined(separator: " ")
    }

    /// "2026-09-23" -> start of that day in the current calendar.
    static func parseDay(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func formatDay(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// "120k" -> 122880, "2m" -> 2 MiB, "512" -> 512 bytes.
    static func parseSize(_ text: String) -> Int64? {
        var digits = text.lowercased()
        var multiplier: Int64 = 1
        if let last = digits.last, "kmg".contains(last) {
            multiplier = last == "k" ? 1024 : last == "m" ? 1024 * 1024 : 1024 * 1024 * 1024
            digits.removeLast()
        }
        guard let value = Int64(digits) else { return nil }
        return value * multiplier
    }
}
