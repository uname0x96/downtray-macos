import AppKit
import Carbon.HIToolbox
import InboxCore

/// Global hotkey through Carbon's `RegisterEventHotKey`. Works inside the App Sandbox and needs
/// no Accessibility permission, unlike event taps.
@MainActor
final class HotkeyCenter {
    var onPress: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x44_49_4E_42 // "DINB"

    func register(_ hotkey: Hotkey) {
        unregister()
        installHandlerIfNeeded()
        var modifiers: UInt32 = 0
        if hotkey.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        if hotkey.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        if hotkey.modifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if hotkey.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr { hotKeyRef = ref } else { NSLog("[hotkey] register failed: \(status)") }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers application-target events on the main thread.
            MainActor.assumeIsolated { center.onPress?() }
            return noErr
        }, 1, &eventType, userData, &handlerRef)
    }
}

extension Hotkey {
    /// Builds a hotkey from an AppKit key event, e.g. inside the settings recorder.
    init?(event: NSEvent) {
        var modifiers: Modifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        guard !modifiers.isEmpty, Hotkey.keyName(for: UInt32(event.keyCode)) != nil else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }
}
