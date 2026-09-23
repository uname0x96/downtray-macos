import AppKit
import SwiftUI
import InboxCore

/// Standard Settings scene. Every control is a binding onto the model that sends an event.
struct SettingsView: View {
    @Environment(InboxPresenter.self) private var presenter

    private var model: InboxModel { presenter.model }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(String(localized: "settings.alwaysOn", defaultValue: "Always on", comment: "Value next to the Downloads folder: it cannot be turned off.")).foregroundStyle(.secondary)
                } label: {
                    Text(FolderKind.downloads.localizedTitle)
                    Text(Self.displayPath(model.downloads?.path)).foregroundStyle(.secondary)
                }
                if model.downloads?.access == .denied {
                    LabeledContent {
                        Button(String(localized: "settings.grantAccess", defaultValue: "Grant Access…", comment: "Opens the folder picker that grants access.")) { presenter.dispatch(.grantAccess(.downloads)) }
                    } label: {
                        Text(String(localized: "settings.accessNeeded", defaultValue: "Access needed", comment: "Row title when macOS denied a folder."))
                        Text(String(localized: "settings.downloads.denied", defaultValue: "macOS has not allowed Downtray to read this folder.", comment: "Keep the brand name.")).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: binding(\.watchDesktop) { .setWatchDesktop($0) }) {
                    Text(FolderKind.desktop.localizedTitle)
                    Text(String(localized: "settings.desktop.body", defaultValue: "Also list files that land on the Desktop.")).foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                if model.folder(.desktop)?.access == .denied {
                    LabeledContent {
                        Button(String(localized: "settings.grantAccess", defaultValue: "Grant Access…")) { presenter.dispatch(.grantAccess(.desktop)) }
                    } label: {
                        Text(String(localized: "settings.accessNeeded", defaultValue: "Access needed"))
                        Text(String(localized: "settings.desktop.denied", defaultValue: "Choose the Desktop folder to let Downtray watch it.", comment: "Keep the brand name.")).foregroundStyle(.secondary)
                    }
                }
                ForEach(model.customFolders, id: \.kind) { folder in
                    LabeledContent {
                        Button {
                            presenter.dispatch(.removeFolder(folder.kind))
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "settings.folder.remove", defaultValue: "Stop watching this folder", comment: "Tooltip on the minus button next to a custom folder."))
                        .accessibilityIdentifier("removeFolder")
                    } label: {
                        Text(folder.localizedTitle)
                        Text(folder.access == .denied
                             ? String(localized: "settings.folder.unreadable", defaultValue: "Can't read this folder any more.", comment: "Shown under a custom folder whose access was lost.")
                             : Self.displayPath(folder.path))
                            .foregroundStyle(folder.access == .denied ? Color.orange : Color.secondary)
                    }
                }
                LabeledContent {
                    Button(String(localized: "settings.addFolder", defaultValue: "Add Folder…", comment: "Opens the folder picker (Pro).")) { presenter.dispatch(.addFolder) }
                        .accessibilityIdentifier("addFolder")
                } label: {
                    Text(String(localized: "settings.moreFolders", defaultValue: "More folders"))
                    Text(model.isPro
                         ? String(localized: "settings.moreFolders.pro", defaultValue: "Watch any other folder, such as a scanner or AirDrop target.")
                         : String(localized: "settings.moreFolders.free", defaultValue: "Pro: watch any other folder.", comment: "Shown in the free tier; 'Pro:' marks a paid feature."))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "settings.folders", defaultValue: "Folders", comment: "Section title."))
            } footer: {
                Text(String(localized: "settings.folders.footer", defaultValue: "The inbox shows the \(model.effectiveListLimit) newest files from the folders it watches.", comment: "Placeholder: 20 in the free tier, 200 with Pro."))
            }

            Section(String(localized: "settings.general", defaultValue: "General", comment: "Section title.")) {
                Toggle(String(localized: "settings.launchAtLogin", defaultValue: "Launch at login"), isOn: binding(\.launchAtLogin) { .setLaunchAtLogin($0) })
                LabeledContent(String(localized: "settings.hotkey", defaultValue: "Show inbox", comment: "Label of the keyboard shortcut recorder.")) {
                    HotkeyRecorder(hotkey: model.settings.hotkey) { presenter.dispatch(.setHotkey($0)) }
                }
                Toggle(String(localized: "settings.notifications", defaultValue: "Notify on new file", comment: "Toggle for system notifications."), isOn: binding(\.notificationsEnabled) { .setNotifications($0) })
                LabeledContent {
                    Button(String(localized: "app.quit", defaultValue: "Quit Downtray")) { NSApp.terminate(nil) }
                } label: {
                    Text(String(localized: "settings.quit", defaultValue: "Quit"))
                    Text(String(localized: "settings.quit.body", defaultValue: "Also in the menu bar icon's right-click menu, or ⌘Q while the inbox is open.", comment: "Keep the ⌘Q glyph."))
                        .foregroundStyle(.secondary)
                }
            }

            proSection
            rulesSection
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle(String(localized: "settings.title", defaultValue: "Downtray Settings", comment: "Window title. Keep the brand name."))
    }

    // MARK: Pro

    @State private var editingRule: Rule?
    @State private var proPrice: String?

    @ViewBuilder
    private var proSection: some View {
        Section {
            if model.isPro {
                LabeledContent(String(localized: "settings.pro", defaultValue: "Pro", comment: "Section title and row label for the paid tier. Usually left as 'Pro'.")) {
                    Label(String(localized: "settings.pro.unlocked", defaultValue: "Unlocked", comment: "Status next to Pro after purchase."), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
                LabeledContent {
                    Button(String(localized: "settings.history.clear", defaultValue: "Clear History")) { presenter.dispatch(.clearHistory) }
                        .disabled(model.history.isEmpty)
                } label: {
                    Text(String(localized: "settings.history", defaultValue: "History", comment: "Row label."))
                    Text(historySummary).foregroundStyle(.secondary)
                }
            } else {
                LabeledContent {
                    Button(proPrice.map { String(localized: "pro.unlock.buttonWithPrice", defaultValue: "Unlock Pro — \($0)", comment: "Purchase button. Placeholder: localized price, e.g. $7.99.") }
                           ?? String(localized: "pro.unlock.button", defaultValue: "Unlock Pro…", comment: "Purchase button while the price is unknown.")) {
                        presenter.dispatch(.unlockPro)
                    }
                    .accessibilityIdentifier("unlockPro")
                } label: {
                    Text(String(localized: "settings.pro", defaultValue: "Pro"))
                    Text(String(localized: "pro.unlock.body", defaultValue: "Extra folders, 200-file list with search, full history, and rules. One-time purchase.", comment: "What Pro adds."))
                        .foregroundStyle(.secondary)
                }
                Button(String(localized: "pro.restore", defaultValue: "Restore Purchases", comment: "Standard App Store wording.")) { presenter.dispatch(.restorePurchases) }
            }
            if let toast = model.toast {
                Text(toast.text.localized)
                    .font(.caption)
                    .foregroundStyle(toast.isError ? Color.orange : Color.secondary)
            }
        } header: {
            Text(String(localized: "settings.pro", defaultValue: "Pro"))
        }
        .task {
            if !model.isPro { proPrice = await (presenter.services as? MacServices)?.proPrice() }
        }
    }

    private var historySummary: String {
        let count = model.history.count
        return count == 0
            ? String(localized: "settings.history.empty", defaultValue: "No files remembered yet.")
            : String(localized: "settings.history.count", defaultValue: "\(count) files remembered. The History button in the inbox lists them.", comment: "Placeholder: number of remembered files.")
    }

    @ViewBuilder
    private var rulesSection: some View {
        Section {
            ForEach(model.settings.rules) { rule in
                LabeledContent {
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { rule.enabled },
                            set: { on in
                                var updated = rule
                                updated.enabled = on
                                presenter.dispatch(.updateRule(updated))
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        Button { editingRule = rule } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                            .help(String(localized: "rule.edit", defaultValue: "Edit rule", comment: "Tooltip on the pencil button."))
                        Button { presenter.dispatch(.removeRule(rule.id)) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help(String(localized: "rule.delete", defaultValue: "Delete rule", comment: "Tooltip on the minus button."))
                    }
                } label: {
                    Text(rule.name)
                    Text(rule.localizedSummary).foregroundStyle(.secondary)
                }
                .disabled(!model.isPro)
            }
            LabeledContent {
                Button(String(localized: "rule.add", defaultValue: "Add Rule…", comment: "Opens the rule editor (Pro).")) { editingRule = Rule(name: "", action: .markSeen) }
                    .disabled(!model.isPro)
                    .accessibilityIdentifier("addRule")
            } label: {
                Text(model.settings.rules.isEmpty ? String(localized: "rule.none", defaultValue: "No rules yet") : String(localized: "rule.new", defaultValue: "New rule"))
                Text(model.isPro
                     ? String(localized: "rule.body.pro", defaultValue: "Sort arrivals automatically: move, trash, mark seen, or ask.")
                     : String(localized: "rule.body.free", defaultValue: "Pro: sort arrivals automatically.", comment: "Shown in the free tier; 'Pro:' marks a paid feature."))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(String(localized: "settings.rules", defaultValue: "Rules", comment: "Section title."))
        }
        .sheet(item: $editingRule) { rule in
            RuleEditor(rule: rule, isNew: !model.settings.rules.contains { $0.id == rule.id }) { saved in
                if let saved {
                    presenter.dispatch(model.settings.rules.contains { $0.id == saved.id } ? .updateRule(saved) : .addRule(saved))
                }
                editingRule = nil
            }
        }
    }

    /// "~/Downloads" instead of the full path.
    private static func displayPath(_ path: String?) -> String {
        guard let path else { return "" }
        let home = WatchedFolder.realHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func binding(_ keyPath: KeyPath<InboxCore.Settings, Bool>, event: @escaping (Bool) -> Event) -> Binding<Bool> {
        Binding(
            get: { presenter.model.settings[keyPath: keyPath] },
            set: { presenter.dispatch(event($0)) }
        )
    }
}

/// One rule: what to match and what to do. Saves through `addRule`/`updateRule`; nothing is
/// written until Save.
struct RuleEditor: View {
    @State private var rule: Rule
    let isNew: Bool
    let finish: (Rule?) -> Void

    private enum ActionChoice: String, CaseIterable, Identifiable {
        case moveTo, trash, markSeen, suggestTrash
        var id: String { rawValue }
        var title: String {
            switch self {
            case .moveTo: return String(localized: "rule.action.moveTo", defaultValue: "Move to a folder", comment: "Rule editor, 'Then' picker option.")
            case .trash: return String(localized: "rule.action.trash", defaultValue: "Move to Trash", comment: "Rule editor, 'Then' picker option.")
            case .markSeen: return String(localized: "rule.action.markSeen", defaultValue: "Mark as seen", comment: "Rule editor, 'Then' picker option.")
            case .suggestTrash: return String(localized: "rule.action.suggestTrash", defaultValue: "Ask whether to trash it", comment: "Rule editor, 'Then' picker option: show a notice instead of acting.")
            }
        }
    }

    @State private var actionChoice: ActionChoice
    @State private var destination: String

    init(rule: Rule, isNew: Bool, finish: @escaping (Rule?) -> Void) {
        _rule = State(initialValue: rule)
        self.isNew = isNew
        self.finish = finish
        switch rule.action {
        case .moveTo(let path):
            _actionChoice = State(initialValue: .moveTo)
            _destination = State(initialValue: path)
        case .trash:
            _actionChoice = State(initialValue: .trash)
            _destination = State(initialValue: "")
        case .markSeen:
            _actionChoice = State(initialValue: .markSeen)
            _destination = State(initialValue: "")
        case .suggestTrash:
            _actionChoice = State(initialValue: .suggestTrash)
            _destination = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(String(localized: "rule.editor.section", defaultValue: "Rule", comment: "Rule editor section title.")) {
                    TextField(String(localized: "rule.name", defaultValue: "Name"), text: $rule.name, prompt: Text(String(localized: "rule.name.prompt", defaultValue: "Invoices to Documents", comment: "Example rule name shown as a placeholder.")))
                    Picker(String(localized: "rule.when", defaultValue: "When", comment: "Rule editor: which event triggers the rule."), selection: $rule.trigger) {
                        ForEach(RuleTrigger.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
                    }
                }
                Section {
                    Picker(String(localized: "rule.kind", defaultValue: "Kind", comment: "Rule editor: file kind to match."), selection: $rule.match.kind) {
                        Text(String(localized: "rule.kind.any", defaultValue: "Any", comment: "Rule editor: match every file kind.")).tag(FileKind?.none)
                        ForEach(FileKind.allCases, id: \.self) { Text($0.localizedLabel).tag(FileKind?.some($0)) }
                    }
                    TextField(String(localized: "rule.extension", defaultValue: "Extension", comment: "Rule editor: file extension to match."), text: optional($rule.match.fileExtension), prompt: Text(verbatim: "pdf"))
                    TextField(String(localized: "rule.nameContains", defaultValue: "Name contains"), text: optional($rule.match.nameContains), prompt: Text(String(localized: "rule.nameContains.prompt", defaultValue: "invoice", comment: "Example text shown as a placeholder.")))
                    TextField(String(localized: "rule.host", defaultValue: "Downloaded from", comment: "Rule editor: web host the file came from."), text: optional($rule.match.host), prompt: Text(verbatim: "example.com"))
                } header: {
                    Text(String(localized: "rule.match", defaultValue: "Match", comment: "Rule editor section title: the conditions."))
                } footer: {
                    Text(String(localized: "rule.match.footer", defaultValue: "Leave a field empty to match any file. All filled fields must match."))
                }
                Section(String(localized: "rule.then", defaultValue: "Then", comment: "Rule editor section title: the action.")) {
                    Picker(String(localized: "rule.action", defaultValue: "Action"), selection: $actionChoice) {
                        ForEach(ActionChoice.allCases) { Text($0.title).tag($0) }
                    }
                    if actionChoice == .moveTo {
                        LabeledContent(String(localized: "rule.folder", defaultValue: "Folder", comment: "Rule editor: destination folder.")) {
                            HStack {
                                Text(destination.isEmpty ? String(localized: "rule.folder.none", defaultValue: "None chosen", comment: "Rule editor: no destination picked yet.") : (destination as NSString).lastPathComponent)
                                    .foregroundStyle(destination.isEmpty ? .secondary : .primary)
                                Button(String(localized: "rule.folder.choose", defaultValue: "Choose…"), action: chooseDestination)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? String(localized: "common.add", defaultValue: "Add", comment: "Rule editor: saves a new rule.") : String(localized: "common.save", defaultValue: "Save")) { finish(built) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 440, height: 480)
    }

    private var canSave: Bool {
        !rule.name.trimmingCharacters(in: .whitespaces).isEmpty && (actionChoice != .moveTo || !destination.isEmpty)
    }

    private var built: Rule {
        var result = rule
        result.name = rule.name.trimmingCharacters(in: .whitespaces)
        switch actionChoice {
        case .moveTo: result.action = .moveTo(destination)
        case .trash: result.action = .trash
        case .markSeen: result.action = .markSeen
        case .suggestTrash: result.action = .suggestTrash
        }
        return result
    }

    /// The chosen folder is remembered as a security-scoped bookmark so the rule can move files
    /// there in later launches.
    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "rule.destination.prompt", defaultValue: "Choose", comment: "Folder picker button. Keep short.")
        panel.message = String(localized: "rule.destination.message", defaultValue: "Files matching this rule will be moved here.", comment: "Folder picker heading.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        MacServices.rememberDestination(url)
        destination = url.path
    }

    private func optional(_ source: Binding<String?>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue ?? "" },
            set: { source.wrappedValue = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        )
    }
}

/// Click, then press the new combination. Escape cancels. Needs at least one modifier.
struct HotkeyRecorder: View {
    let hotkey: Hotkey
    let onChange: (Hotkey) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : startRecording()
        } label: {
            Text(recording ? String(localized: "hotkey.recording", defaultValue: "Press keys…", comment: "Shortcut recorder while it waits for a key combination.") : hotkey.display)
                .frame(minWidth: 90)
        }
        .keyboardShortcut(recording ? nil : KeyboardShortcut(.escape, modifiers: []))
        .accessibilityIdentifier("hotkeyRecorder")
        .onDisappear { stop() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                stop()
                return nil
            }
            if let hotkey = Hotkey(event: event) {
                onChange(hotkey)
                stop()
                return nil
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
