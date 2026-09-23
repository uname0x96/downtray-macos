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
                    Text("Always on").foregroundStyle(.secondary)
                } label: {
                    Text("Downloads")
                    Text(Self.displayPath(model.downloads?.path)).foregroundStyle(.secondary)
                }
                if model.downloads?.access == .denied {
                    LabeledContent {
                        Button("Grant Access…") { presenter.dispatch(.grantAccess(.downloads)) }
                    } label: {
                        Text("Access needed")
                        Text("macOS has not allowed Downtray to read this folder.").foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: binding(\.watchDesktop) { .setWatchDesktop($0) }) {
                    Text("Desktop")
                    Text("Also list files that land on the Desktop.").foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                if model.folder(.desktop)?.access == .denied {
                    LabeledContent {
                        Button("Grant Access…") { presenter.dispatch(.grantAccess(.desktop)) }
                    } label: {
                        Text("Access needed")
                        Text("Choose the Desktop folder to let Downtray watch it.").foregroundStyle(.secondary)
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
                        .help("Stop watching this folder")
                        .accessibilityIdentifier("removeFolder")
                    } label: {
                        Text(folder.title)
                        Text(folder.access == .denied
                             ? String(localized: "Can't read this folder any more.")
                             : Self.displayPath(folder.path))
                            .foregroundStyle(folder.access == .denied ? Color.orange : Color.secondary)
                    }
                }
                LabeledContent {
                    Button("Add Folder…") { presenter.dispatch(.addFolder) }
                        .accessibilityIdentifier("addFolder")
                } label: {
                    Text("More folders")
                    Text(model.isPro
                         ? String(localized: "Watch any other folder, such as a scanner or AirDrop target.")
                         : String(localized: "Pro: watch any other folder."))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Folders")
            } footer: {
                Text(model.isPro
                     ? String(localized: "The inbox shows the 200 newest files from the folders it watches.")
                     : String(localized: "The inbox shows the 20 newest files from the folders it watches."))
            }

            Section("General") {
                Toggle("Launch at login", isOn: binding(\.launchAtLogin) { .setLaunchAtLogin($0) })
                LabeledContent("Show inbox") {
                    HotkeyRecorder(hotkey: model.settings.hotkey) { presenter.dispatch(.setHotkey($0)) }
                }
                Toggle("Notify on new file", isOn: binding(\.notificationsEnabled) { .setNotifications($0) })
                LabeledContent {
                    Button("Quit Downtray") { NSApp.terminate(nil) }
                } label: {
                    Text("Quit")
                    Text("Also in the menu bar icon's right-click menu, or ⌘Q while the inbox is open.")
                        .foregroundStyle(.secondary)
                }
            }

            proSection
            rulesSection
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("Downtray Settings")
    }

    // MARK: Pro

    @State private var editingRule: Rule?
    @State private var proPrice: String?

    @ViewBuilder
    private var proSection: some View {
        Section {
            if model.isPro {
                LabeledContent("Pro") {
                    Label("Unlocked", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
                LabeledContent {
                    Button("Clear History") { presenter.dispatch(.clearHistory) }
                        .disabled(model.history.isEmpty)
                } label: {
                    Text("History")
                    Text(historySummary).foregroundStyle(.secondary)
                }
            } else {
                LabeledContent {
                    Button(proPrice.map { String(localized: "Unlock Pro — \($0)") } ?? String(localized: "Unlock Pro…")) {
                        presenter.dispatch(.unlockPro)
                    }
                    .accessibilityIdentifier("unlockPro")
                } label: {
                    Text("Pro")
                    Text("Extra folders, 200-file list with search, full history, and rules. One-time purchase.")
                        .foregroundStyle(.secondary)
                }
                Button("Restore Purchases") { presenter.dispatch(.restorePurchases) }
            }
            if let toast = model.toast {
                Text(toast.message)
                    .font(.caption)
                    .foregroundStyle(toast.isError ? Color.orange : Color.secondary)
            }
        } header: {
            Text("Pro")
        }
        .task {
            if !model.isPro { proPrice = await (presenter.services as? MacServices)?.proPrice() }
        }
    }

    private var historySummary: String {
        let count = model.history.count
        return count == 0
            ? String(localized: "No files remembered yet.")
            : String(localized: "\(count) files remembered. The History button in the inbox lists them.")
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
                            .help("Edit rule")
                        Button { presenter.dispatch(.removeRule(rule.id)) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Delete rule")
                    }
                } label: {
                    Text(rule.name)
                    Text(rule.summary).foregroundStyle(.secondary)
                }
                .disabled(!model.isPro)
            }
            LabeledContent {
                Button("Add Rule…") { editingRule = Rule(name: "", action: .markSeen) }
                    .disabled(!model.isPro)
                    .accessibilityIdentifier("addRule")
            } label: {
                Text(model.settings.rules.isEmpty ? String(localized: "No rules yet") : String(localized: "New rule"))
                Text(model.isPro
                     ? String(localized: "Sort arrivals automatically: move, trash, mark seen, or ask.")
                     : String(localized: "Pro: sort arrivals automatically."))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Rules")
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
            case .moveTo: return String(localized: "Move to a folder")
            case .trash: return String(localized: "Move to Trash")
            case .markSeen: return String(localized: "Mark as seen")
            case .suggestTrash: return String(localized: "Ask whether to trash it")
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
                Section("Rule") {
                    TextField("Name", text: $rule.name, prompt: Text("Invoices to Documents"))
                    Picker("When", selection: $rule.trigger) {
                        ForEach(RuleTrigger.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Section {
                    Picker("Kind", selection: $rule.match.kind) {
                        Text("Any").tag(FileKind?.none)
                        ForEach(FileKind.allCases, id: \.self) { Text($0.label).tag(FileKind?.some($0)) }
                    }
                    TextField("Extension", text: optional($rule.match.fileExtension), prompt: Text("pdf"))
                    TextField("Name contains", text: optional($rule.match.nameContains), prompt: Text("invoice"))
                    TextField("Downloaded from", text: optional($rule.match.host), prompt: Text("example.com"))
                } header: {
                    Text("Match")
                } footer: {
                    Text("Leave a field empty to match any file. All filled fields must match.")
                }
                Section("Then") {
                    Picker("Action", selection: $actionChoice) {
                        ForEach(ActionChoice.allCases) { Text($0.title).tag($0) }
                    }
                    if actionChoice == .moveTo {
                        LabeledContent("Folder") {
                            HStack {
                                Text(destination.isEmpty ? String(localized: "None chosen") : (destination as NSString).lastPathComponent)
                                    .foregroundStyle(destination.isEmpty ? .secondary : .primary)
                                Button("Choose…", action: chooseDestination)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel", role: .cancel) { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? "Add" : "Save") { finish(built) }
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
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Files matching this rule will be moved here.")
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
            Text(recording ? String(localized: "Press keys…") : hotkey.display)
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
