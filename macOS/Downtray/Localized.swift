import Foundation
import InboxCore
import UniformTypeIdentifiers

// Localized wording for the values `InboxCore` describes in English. The core's text is the
// snapshot contract that scripts and tests read; these extensions are what the UI shows.
// Every key lives in `Localizable.xcstrings`; the `defaultValue` is the English source.

extension FileFilter {
    var localizedTitle: String {
        switch self {
        case .all: String(localized: "filter.all", defaultValue: "All", comment: "Filter chip: every file.")
        case .lastHour: String(localized: "filter.lastHour", defaultValue: "1h", comment: "Filter chip: files that arrived in the last hour. Keep very short; four chips and the Type menu share one row.")
        case .today: String(localized: "filter.today", defaultValue: "Today", comment: "Filter chip: files that arrived today.")
        case .unread: String(localized: "filter.unread", defaultValue: "Unread", comment: "Filter chip: files the user has not opened yet. Keep short.")
        }
    }
}

extension TypeGroup {
    /// The Type menu's items, and the button label while a group is selected.
    var localizedTitle: String {
        switch self {
        case .docs: String(localized: "type.docs", defaultValue: "Docs", comment: "Type menu item: documents, spreadsheets, presentations, text. Keep short.")
        case .images: String(localized: "type.images", defaultValue: "Images", comment: "Type menu item: pictures.")
        case .media: String(localized: "type.media", defaultValue: "Media", comment: "Type menu item: video and audio.")
        case .archives: String(localized: "type.archives", defaultValue: "Archives", comment: "Type menu item: zip, tar and similar.")
        case .apps: String(localized: "type.apps", defaultValue: "Apps", comment: "Type menu item: dmg, pkg, app and other installers.")
        case .other: String(localized: "type.other", defaultValue: "Other", comment: "Type group for anything not in the table; only shown in Settings.")
        }
    }
}

extension Retention {
    /// Settings › List › Keep items.
    var localizedTitle: String {
        switch self {
        case .day: String(localized: "retention.day", defaultValue: "24 hours", comment: "Keep items picker option.")
        case .week: String(localized: "retention.week", defaultValue: "7 days", comment: "Keep items picker option.")
        case .month: String(localized: "retention.month", defaultValue: "30 days", comment: "Keep items picker option.")
        }
    }
}

extension InboxSection {
    /// Section header in the inbox list (All and Today chips only).
    var localizedTitle: String {
        switch self {
        case .justNow: String(localized: "section.justNow", defaultValue: "Just now", comment: "Inbox section header: files that arrived in the last 15 minutes.")
        case .earlierToday: String(localized: "section.earlierToday", defaultValue: "Earlier today", comment: "Inbox section header.")
        case .yesterday: String(localized: "section.yesterday", defaultValue: "Yesterday", comment: "Inbox section header.")
        case .thisWeek: String(localized: "section.thisWeek", defaultValue: "This week", comment: "Inbox section header: the last six days before yesterday.")
        case .earlier: String(localized: "section.earlier", defaultValue: "Earlier", comment: "Inbox section header: older than a week.")
        }
    }
}

extension FileKind {
    /// Short label for the row's meta line and the rule editor ("PDF", "Image", ...).
    var localizedLabel: String {
        switch self {
        case .pdf: String(localized: "kind.pdf", defaultValue: "PDF", comment: "File kind in a row's meta line.")
        case .image: String(localized: "kind.image", defaultValue: "Image", comment: "File kind in a row's meta line.")
        case .archive: String(localized: "kind.archive", defaultValue: "Archive", comment: "File kind in a row's meta line: zip, tar and similar.")
        case .installer: String(localized: "kind.installer", defaultValue: "Installer", comment: "File kind in a row's meta line: dmg, pkg, app.")
        case .folder: String(localized: "kind.folder", defaultValue: "Folder", comment: "File kind in a row's meta line.")
        case .other: String(localized: "kind.file", defaultValue: "File", comment: "File kind in a row's meta line, for anything not recognized.")
        }
    }
}

extension FolderKind {
    /// The two built-in folders get the name Finder shows for them; a custom folder keeps its own.
    var localizedTitle: String {
        switch self {
        case .downloads: String(localized: "folder.downloads", defaultValue: "Downloads", comment: "The user's Downloads folder, as Finder names it.")
        case .desktop: String(localized: "folder.desktop", defaultValue: "Desktop", comment: "The user's Desktop folder, as Finder names it.")
        default: title
        }
    }
}

extension HistoryFilter {
    var localizedTitle: String {
        switch self {
        case .all: String(localized: "history.filter.all", defaultValue: "All", comment: "History segment: every recorded file.")
        case .available: String(localized: "history.filter.available", defaultValue: "Available", comment: "History segment: files still where they were. Keep short; three segments share one row.")
        case .gone: String(localized: "history.filter.gone", defaultValue: "Gone", comment: "History segment: files moved or deleted since. Keep short.")
        }
    }
}

extension WatchedFolder {
    var localizedTitle: String { kind.isCustom ? title : kind.localizedTitle }
}

extension InboxFile {
    /// The kind on a row's meta line: the system's name for the type where that name says
    /// something ("Disk Image", "ZIP archive", "PNG image"), otherwise the uppercase extension
    /// ("MD", "CSV", "DOCX"). Never "File" or "Document". Nil for an extensionless file.
    var rowKind: String? {
        switch kind {
        case .pdf: return FileKind.pdf.localizedLabel
        case .folder: return FileKind.folder.localizedLabel
        default: break
        }
        if let type = UTType(filenameExtension: fileExtension), !type.isDynamic,
           Self.describedFamilies.contains(where: { type.conforms(to: $0) }),
           let description = type.localizedDescription {
            return description
        }
        return shortKind
    }

    /// The row's fallback when the system name does not fit line 2: the uppercase extension.
    var shortKind: String? {
        switch kind {
        case .pdf: return FileKind.pdf.localizedLabel
        case .folder: return FileKind.folder.localizedLabel
        default: return fileExtension.isEmpty ? nil : fileExtension.uppercased()
        }
    }

    /// Families whose system description is a kind a user recognizes. Text, data and source
    /// code are left out: their descriptions are "Document", "Data" or a long phrase, and the
    /// extension says more.
    private static let describedFamilies: [UTType] = [.image, .archive, .diskImage, .package, .application, .movie, .audio, .font]
}

extension FileSource {
    /// Where the file came from, for the row's tooltip and menu caption; nil when unknown.
    var localizedDescription: String? {
        switch self {
        case .web(let host): String(localized: "row.source.web", defaultValue: "From \(host)", comment: "Row tooltip and menu caption. Placeholder: web host such as dropbox.com.")
        case .airDrop: String(localized: "row.source.airDrop", defaultValue: "Received via AirDrop", comment: "Row tooltip and menu caption. Keep 'AirDrop' as Apple spells it.")
        case .unknown: nil
        }
    }
}

extension RuleTrigger {
    /// Picker label in the rule editor.
    var localizedTitle: String {
        switch self {
        case .arrival: String(localized: "rule.trigger.arrival", defaultValue: "When a file arrives", comment: "Rule editor, 'When' picker option.")
        case .opened: String(localized: "rule.trigger.opened", defaultValue: "After a file is opened", comment: "Rule editor, 'When' picker option.")
        }
    }

    /// Start of the one-line rule summary in Settings ("when a file arrives: PDF → move to Receipts").
    var localizedSummary: String {
        switch self {
        case .arrival: String(localized: "rule.summary.trigger.arrival", defaultValue: "when a file arrives", comment: "Start of a rule summary line; followed by a colon.")
        case .opened: String(localized: "rule.summary.trigger.opened", defaultValue: "after a file is opened", comment: "Start of a rule summary line; followed by a colon.")
        }
    }
}

extension RuleMatch {
    var localizedSummary: String {
        var parts: [String] = []
        if let kind { parts.append(kind.localizedLabel) }
        if let fileExtension, !fileExtension.isEmpty { parts.append(".\(fileExtension)") }
        if let host { parts.append(String(localized: "rule.summary.from", defaultValue: "from \(host)", comment: "Rule summary fragment; the placeholder is a web host such as stripe.com.")) }
        if let nameContains, !nameContains.isEmpty {
            parts.append(String(localized: "rule.summary.named", defaultValue: "named “\(nameContains)”", comment: "Rule summary fragment; the placeholder is text the file name must contain."))
        }
        return parts.isEmpty
            ? String(localized: "rule.summary.any", defaultValue: "any file", comment: "Rule summary when the rule has no conditions.")
            : parts.joined(separator: " ")
    }
}

extension RuleAction {
    /// End of the rule summary line, lowercase.
    var localizedSummary: String {
        switch self {
        case .moveTo(let path):
            String(localized: "rule.summary.moveTo", defaultValue: "move to \((path as NSString).lastPathComponent)", comment: "Rule summary fragment; the placeholder is a folder name.")
        case .trash: String(localized: "rule.summary.trash", defaultValue: "move to Trash", comment: "Rule summary fragment.")
        case .markSeen: String(localized: "rule.summary.markSeen", defaultValue: "mark as seen", comment: "Rule summary fragment.")
        case .suggestTrash: String(localized: "rule.summary.suggestTrash", defaultValue: "offer to Trash it", comment: "Rule summary fragment: the rule asks before trashing.")
        }
    }
}

extension Rule {
    var localizedSummary: String { "\(trigger.localizedSummary): \(match.localizedSummary) → \(action.localizedSummary)" }
}

extension ToastText {
    var localized: String {
        switch self {
        case .pathCopied(let count):
            String(localized: "toast.pathCopied", defaultValue: "\(count) paths copied", comment: "Toast after Copy Path. Plural: 1 → 'Path copied'.")
        case .nameCopied(let count):
            String(localized: "toast.nameCopied", defaultValue: "\(count) names copied", comment: "Toast after Copy Name. Plural: 1 → 'Name copied'.")
        case .moved(let names, let folder):
            names.count == 1
                ? String(localized: "toast.movedOne", defaultValue: "Moved \(names[0]) to \(folder)", comment: "Toast after a move. First placeholder: file name, second: destination folder name.")
                : String(localized: "toast.movedMany", defaultValue: "Moved \(names.count) files to \(folder)", comment: "Toast after moving several files. Placeholders: count, destination folder name.")
        case .moveFailed(let failed, let total):
            String(localized: "toast.moveFailed", defaultValue: "Could not move \(failed) of \(total) files", comment: "Error toast. Placeholders: number that failed, total number.")
        case .extracted(let name, let folder):
            String(localized: "toast.extracted", defaultValue: "Extracted \(name) to \(folder)", comment: "Toast after Unzip Here. Placeholders: archive name, new folder name.")
        case .proUnlocked:
            String(localized: "toast.proUnlocked", defaultValue: "Pro unlocked. Thank you!", comment: "Toast after a successful purchase or restore.")
        case .folderAlreadyWatched(let name):
            String(localized: "toast.folderAlreadyWatched", defaultValue: "\(name) is already watched", comment: "Error toast when adding a folder that is already in the list. Placeholder: folder name.")
        case .text(let text):
            text
        }
    }
}

extension Suggestion {
    var localizedMessage: String {
        switch action {
        case .trash, .suggestTrash:
            String(localized: "suggestion.trash", defaultValue: "\(ruleName): move \(fileName) to the Trash?", comment: "Notice with a Yes button. Placeholders: rule name, file name.")
        case .moveTo(let path):
            String(localized: "suggestion.move", defaultValue: "\(ruleName): move \(fileName) to \((path as NSString).lastPathComponent)?", comment: "Notice with a Yes button. Placeholders: rule name, file name, folder name.")
        case .markSeen:
            String(localized: "suggestion.markSeen", defaultValue: "\(ruleName): mark \(fileName) as seen?", comment: "Notice with a Yes button. Placeholders: rule name, file name.")
        }
    }
}

/// The product name. Never translated; one key so every screen spells it the same way.
var appName: String {
    String(localized: "app.name", defaultValue: "Downtray", comment: "Brand name. Do not translate or transliterate.")
}
