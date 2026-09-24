import AppKit
import SwiftUI
import InboxCore

/// Standard Settings scene. Every control is a binding onto the model that sends an event.
struct SettingsView: View {
    @Environment(InboxPresenter.self) private var presenter

    private var model: InboxModel { presenter.model }

    var body: some View {
        Form {
            proSection

            Section {
                primaryFolderRow
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
                    if !model.isPro {
                        Text(String(localized: "settings.pro", defaultValue: "Pro")).foregroundStyle(.secondary)
                    }
                } label: {
                    Button(String(localized: "settings.addFolder", defaultValue: "Add Folder…", comment: "Opens the folder picker (Pro).")) { presenter.dispatch(.addFolder) }
                        .accessibilityIdentifier("addFolder")
                }
            } header: {
                Text(String(localized: "settings.folders", defaultValue: "Folders", comment: "Section title."))
            } footer: {
                Text(String(localized: "settings.folders.footer", defaultValue: "The inbox shows the \(model.effectiveListLimit) newest files from these folders.", comment: "Placeholder: 20 in the free tier, 200 with Pro."))
            }

            Section(String(localized: "settings.general", defaultValue: "General", comment: "Section title.")) {
                Toggle(String(localized: "settings.launchAtLogin", defaultValue: "Launch at login"), isOn: binding(\.launchAtLogin) { .setLaunchAtLogin($0) })
                LabeledContent(String(localized: "settings.hotkey", defaultValue: "Show inbox", comment: "Label of the keyboard shortcut recorder.")) {
                    HotkeyRecorder(hotkey: model.settings.hotkey) { presenter.dispatch(.setHotkey($0)) }
                }
                Toggle(String(localized: "settings.notifications", defaultValue: "Notify on new file", comment: "Toggle for system notifications."), isOn: binding(\.notificationsEnabled) { .setNotifications($0) })
                Toggle(isOn: binding(\.showBadge) { .setShowBadge($0) }) {
                    Text(String(localized: "settings.showBadge", defaultValue: "Show badge on the menu bar icon", comment: "Toggle in Settings › General."))
                    Text(String(localized: "settings.showBadge.body", defaultValue: "The badge counts unread files.")).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("showBadge")
                languageRow
            }

            rulesSection
            typesSection
            quitSection
        }
        .formStyle(.grouped)
        // A grouped form scrolls on its own. The window used to grow with its content, which
        // put the last sections below the bottom of the screen with no way to reach them.
        .frame(width: 440, height: 640)
        .navigationTitle(String(localized: "settings.title", defaultValue: "Downtray Settings", comment: "Window title. Keep the brand name."))
    }

    // MARK: Folders

    /// The folder the inbox lists: Downloads by default, any folder the user picks with Change….
    /// The same button re-opens the picker when macOS denied access.
    @ViewBuilder
    private var primaryFolderRow: some View {
        let folder = model.downloads
        let denied = folder?.access == .denied
        LabeledContent {
            Button(String(localized: "settings.primary.change", defaultValue: "Change…", comment: "Opens the folder picker to move the inbox to another folder.")) { presenter.dispatch(.grantAccess(.downloads)) }
                .accessibilityIdentifier("changeFolder")
        } label: {
            Text(folder?.localizedTitle ?? FolderKind.downloads.localizedTitle)
            Text(denied
                 ? String(localized: "settings.downloads.denied", defaultValue: "macOS has not allowed Downtray to read this folder.", comment: "Keep the brand name.")
                 : Self.displayPath(folder?.path))
                .foregroundStyle(denied ? Color.orange : Color.secondary)
        }
    }

    // MARK: Types

    @State private var addingType = false

    /// Which group the Type menu files an extension under, when the built-in table is wrong
    /// for this user (a `.key` that is a license, not a Keynote deck). Laid out like Rules:
    /// one row per override, then a row whose Add Type… button opens a small sheet.
    @ViewBuilder
    private var typesSection: some View {
        Section {
            let overrides = model.settings.typeOverrides.sorted { $0.key < $1.key }
            ForEach(overrides, id: \.key) { ext, group in
                LabeledContent {
                    HStack(spacing: 8) {
                        Picker("", selection: Binding(get: { presenter.model.settings.typeOverrides[ext] ?? group }, set: { presenter.dispatch(.setTypeOverride(ext, $0)) })) {
                            ForEach(TypeGroup.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button { presenter.dispatch(.setTypeOverride(ext, nil)) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help(String(localized: "settings.types.remove", defaultValue: "Remove this override", comment: "Tooltip on the minus button next to a type override."))
                    }
                } label: {
                    Text(verbatim: ".\(ext)")
                    Text(String(localized: "settings.types.builtIn", defaultValue: "Built in: \(TypeGroup.forExtension(ext).localizedTitle)", comment: "Under a type override: the group the extension would have without it. Placeholder: group name.")).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("typeOverride-\(ext)")
            }
            LabeledContent {
                Button(String(localized: "settings.types.addType", defaultValue: "Add Type…", comment: "Opens the sheet for a new type override.")) { addingType = true }
                    .accessibilityIdentifier("addType")
            } label: {
                Text(model.settings.typeOverrides.isEmpty
                     ? String(localized: "settings.types.none", defaultValue: "No overrides yet", comment: "Row title while the built-in table is untouched.")
                     : String(localized: "settings.types.new", defaultValue: "New override", comment: "Row title once at least one override exists."))
                Text(String(localized: "settings.types.body", defaultValue: "Decide which group the Type menu files an extension under.")).foregroundStyle(.secondary)
            }
        } header: {
            Text(String(localized: "settings.types", defaultValue: "Types", comment: "Section title: the extension-to-group table behind the Type menu."))
        }
        .sheet(isPresented: $addingType) {
            TypeOverrideEditor { ext, group in
                if let ext { presenter.dispatch(.setTypeOverride(ext, group)) }
                addingType = false
            }
        }
    }

    // MARK: Quit

    /// The last thing in the window: one red, full-width Quit button. Also ⌘Q while the inbox
    /// is open, and the status item's right-click menu.
    private var quitSection: some View {
        Section {
            Button(role: .destructive) { NSApp.terminate(nil) } label: {
                Text(String(localized: "app.quit", defaultValue: "Quit Downtray", comment: "Menu item, ⌘Q and the red button at the end of Settings. Keep the brand name as is."))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .accessibilityIdentifier("quit")
        }
    }

    // MARK: Language

    /// A pick that needs a relaunch, waiting for the alert's answer. `.some(nil)` is "System".
    /// Relaunch Now saves it and restarts; Later drops it, so the picker stays where it was.
    @State private var relaunchPrompt: AppLanguage?? = nil

    @ViewBuilder
    private var languageRow: some View {
        Picker(
            String(localized: "settings.language", defaultValue: "Language", comment: "Picker label in General."),
            selection: Binding(get: { presenter.model.settings.language }, set: { choice in
                if Self.languageAtNextLaunch(for: choice) == Self.runningLanguage {
                    presenter.dispatch(.setLanguage(choice))
                } else {
                    relaunchPrompt = .some(choice)
                }
            })
        ) {
            Text(String(localized: "settings.language.system", defaultValue: "System", comment: "Picker option: follow the macOS language.")).tag(AppLanguage?.none)
            Divider()
            ForEach(AppLanguage.allCases, id: \.self) { Text(verbatim: $0.endonym).tag(AppLanguage?.some($0)) }
        }
        .accessibilityIdentifier("language")
        .alert(
            String(localized: "settings.language.alert.title", defaultValue: "Relaunch Downtray to switch to \(Self.name(of: relaunchPrompt ?? nil))?", comment: "Alert after the language picker changed. Placeholder: the chosen language's own name (日本語) or 'System'. Keep the brand name."),
            isPresented: Binding(get: { relaunchPrompt != nil }, set: { if !$0 { relaunchPrompt = nil } })
        ) {
            Button(String(localized: "settings.language.relaunchNow", defaultValue: "Relaunch Now", comment: "Alert button: save the language and restart the app.")) {
                if let choice = relaunchPrompt {
                    presenter.dispatch(.setLanguage(choice))
                    // After the alert has closed: a quit requested while a sheet is closing stalls.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { AppDelegate.relaunch() }
                }
            }
            Button(String(localized: "settings.language.later", defaultValue: "Later", comment: "Alert button: keep the current language; the pick is discarded."), role: .cancel) {}
        } message: {
            Text(String(localized: "settings.language.alert.message", defaultValue: "The language changes when Downtray restarts. Later keeps the current language.", comment: "Alert body under the relaunch question. Keep the brand name."))
        }
    }

    /// What the alert calls the choice: the endonym, or the "System" option's label.
    private static func name(of choice: AppLanguage?) -> String {
        choice?.endonym ?? String(localized: "settings.language.system", defaultValue: "System")
    }

    /// The localization this process shows ("ja"). Foundation picks it once, at launch.
    private static let runningLanguage = Bundle.main.preferredLocalizations.first ?? "en"

    /// The localization the next launch will show: the choice, or for "System" the first of the
    /// user's macOS languages that the app ships. The system list is read from the global domain,
    /// since inside the app `Locale.preferredLanguages` already reflects the app's own override.
    private static func languageAtNextLaunch(for choice: AppLanguage?) -> String {
        if let choice { return choice.rawValue }
        let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] ?? []
        return Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: system).first ?? "en"
    }

    // MARK: Pro

    @State private var editingRule: Rule?
    @State private var proPrice: String?

    /// The first thing in the window for free users: the purchase button, Restore Purchases
    /// and the store's last word. Once Pro is unlocked the section is gone; the title bar
    /// carries a small badge instead (`ProBadge`).
    @ViewBuilder
    private var proSection: some View {
        if !model.isPro {
            Section {
                LabeledContent {
                    Button(proPrice.map { String(localized: "pro.unlock.buttonWithPrice", defaultValue: "Unlock Pro — \($0)", comment: "Purchase button. Placeholder: localized price, e.g. $7.99.") }
                           ?? String(localized: "pro.unlock.button", defaultValue: "Unlock Pro…", comment: "Purchase button while the price is unknown.")) {
                        presenter.dispatch(.unlockPro)
                    }
                    .accessibilityIdentifier("unlockPro")
                } label: {
                    Text(String(localized: "settings.pro", defaultValue: "Pro", comment: "Row label for the paid tier, the tag next to Add Folder… in the free tier, and the title bar badge once unlocked. Usually left as 'Pro'."))
                    Text(String(localized: "pro.unlock.body", defaultValue: "Extra folders, 200-file list with search, full history, and rules. One-time purchase.", comment: "What Pro adds."))
                        .foregroundStyle(.secondary)
                }
                Button(String(localized: "pro.restore", defaultValue: "Restore Purchases", comment: "Standard App Store wording.")) { presenter.dispatch(.restorePurchases) }
                if let toast = model.toast {
                    Text(toast.text.localized)
                        .font(.caption)
                        .foregroundStyle(toast.isError ? Color.orange : Color.secondary)
                }
            }
            .task { proPrice = await (presenter.services as? MacServices)?.proPrice() }
        }
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

/// A small green "Pro" capsule for the trailing end of the Settings title bar. Renders nothing
/// in the free tier, so it can stay installed and follow the purchase.
struct ProBadge: View {
    @Environment(InboxPresenter.self) private var presenter

    var body: some View {
        if presenter.model.isPro {
            Label(String(localized: "settings.pro", defaultValue: "Pro"), systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.green.opacity(0.15)))
                .padding(.trailing, 10)
                .help(String(localized: "settings.pro.badge.help", defaultValue: "Downtray Pro is unlocked.", comment: "Tooltip on the Pro badge in the Settings title bar. Keep the brand name."))
                .accessibilityIdentifier("proBadge")
        }
    }
}

/// The sheet behind Add Type…: an extension and the group it belongs to.
struct TypeOverrideEditor: View {
    @State private var extensionText = ""
    @State private var group: TypeGroup = .docs
    let finish: (String?, TypeGroup) -> Void

    private var cleaned: String {
        extensionText.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(String(localized: "settings.types.extension", defaultValue: "Extension", comment: "Type override sheet: the file extension field."), text: $extensionText, prompt: Text(verbatim: "pdf"))
                        .accessibilityIdentifier("newExtension")
                        .onSubmit { if !cleaned.isEmpty { finish(cleaned, group) } }
                    Picker(String(localized: "settings.types.group", defaultValue: "Group", comment: "Type override sheet: the Type menu group to file the extension under."), selection: $group) {
                        ForEach(TypeGroup.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
                    }
                } header: {
                    Text(String(localized: "settings.types.sheetTitle", defaultValue: "New Type", comment: "Title of the sheet that adds a type override."))
                } footer: {
                    if !cleaned.isEmpty {
                        Text(String(localized: "settings.types.builtIn", defaultValue: "Built in: \(TypeGroup.forExtension(cleaned).localizedTitle)"))
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) { finish(nil, group) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(String(localized: "common.add", defaultValue: "Add")) { finish(cleaned, group) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleaned.isEmpty)
                    .accessibilityIdentifier("addOverride")
            }
            .padding()
        }
        .frame(width: 440, height: 200)
    }
}
