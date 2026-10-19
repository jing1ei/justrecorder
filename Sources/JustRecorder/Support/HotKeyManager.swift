import AppKit
import Carbon.HIToolbox

/// Virtual key code helpers (used for the hotkey picker and its label).
enum KeyCodes {

    static let r: UInt16 = 15

    /// Display labels for virtual key codes.
    static func name(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 36: return "↩"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 48: return "⇥"
        case 49: return "Space"
        case 50: return "`"
        case 51: return "⌫"
        case 53: return "⎋"
        case 65: return "Keypad ."
        case 67: return "Keypad *"
        case 69: return "Keypad +"
        case 71: return "Clear"
        case 75: return "Keypad /"
        case 76: return "Keypad ↩"
        case 78: return "Keypad -"
        case 81: return "Keypad ="
        case 82: return "Keypad 0"
        case 83: return "Keypad 1"
        case 84: return "Keypad 2"
        case 85: return "Keypad 3"
        case 86: return "Keypad 4"
        case 87: return "Keypad 5"
        case 88: return "Keypad 6"
        case 89: return "Keypad 7"
        case 91: return "Keypad 8"
        case 92: return "Keypad 9"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 114: return "Help"
        case 115: return "Home"
        case 116: return "Page Up"
        case 117: return "⌦"
        case 118: return "F4"
        case 119: return "End"
        case 120: return "F2"
        case 121: return "Page Down"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "Key \(keyCode)"
        }
    }

    static func modifierString(_ modifiers: NSEvent.ModifierFlags) -> String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        return out
    }

    static func displayString(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String {
        modifierString(modifiers) + name(for: keyCode)
    }
}

/// Registers one system-wide hotkey through Carbon's `RegisterEventHotKey`.
///
/// Deliberately *not* using a `CGEventTap`: Carbon hotkeys work without the
/// Accessibility permission, so the app only ever asks for screen/audio recording.
final class HotKeyManager {

    static let shared = HotKeyManager()

    /// Posted (main queue) after every `register` attempt, successful or not, so Settings
    /// can show whether the shortcut it displays is actually live.
    static let registrationDidChange = Notification.Name("com.jing1ei.JustRecorder.hotKeyRegistrationDidChange")

    /// Called on the main queue whenever the hotkey is pressed.
    var onTrigger: (() -> Void)?
    var isCapturingShortcut = false

    /// The combination Carbon actually accepted, or `nil` when the last attempt was
    /// refused — usually because another app already owns the shortcut. Main thread only:
    /// `register` and `unregister` are called from `AppDelegate` (on launch, on a debounced
    /// settings change, and while quitting) and read from the settings window.
    private(set) var activeHotKey: (keyCode: UInt16, modifiers: NSEvent.ModifierFlags)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x4A52_4543 // 'JREC'

    private init() {}

    // MARK: - Public API

    /// (Re)binds the hotkey. Returns `false` when the combination could not be claimed.
    @discardableResult
    func register(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let carbonModifiers = HotKeyManager.carbonModifiers(from: modifiers)
        // Checked before unregistering, so a bad request cannot drop a working hotkey.
        guard carbonModifiers != 0 else {
            Log.warn("Refusing to register a hotkey without modifiers.")
            return false
        }

        unregister()
        guard installHandler() else { return publish(nil) }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            Log.error("RegisterEventHotKey failed with status \(status).")
            return publish(nil)
        }

        hotKeyRef = ref
        Log.info("Hotkey registered: \(KeyCodes.displayString(keyCode: keyCode, modifiers: modifiers))")
        return publish((keyCode: keyCode, modifiers: modifiers))
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        // No notification here: `register` calls this mid-flight and publishes its own
        // outcome, and the only other caller is termination, where nothing is left to tell.
        activeHotKey = nil
    }

    // MARK: - Internals

    /// Records the outcome and tells the UI about it.
    @discardableResult
    private func publish(_ combination: (keyCode: UInt16, modifiers: NSEvent.ModifierFlags)?) -> Bool {
        activeHotKey = combination
        NotificationCenter.default.post(name: HotKeyManager.registrationDidChange, object: nil)
        return combination != nil
    }

    /// Installs the Carbon handler if it is not installed yet. Returns `false` when
    /// Carbon refused, in which case the hotkey would never be delivered.
    private func installHandler() -> Bool {
        guard eventHandler == nil else { return true }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // JustRecorder only ever owns a single hotkey, so any delivered
        // kEventHotKeyPressed belongs to it — no need to inspect the event.
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ -> OSStatus in
                guard !HotKeyManager.shared.isCapturingShortcut else { return noErr }
                DispatchQueue.main.async {
                    guard !HotKeyManager.shared.isCapturingShortcut else { return }
                    HotKeyManager.shared.onTrigger?()
                }
                return noErr
            },
            1,
            &spec,
            nil,
            &eventHandler
        )

        if status != noErr {
            Log.error("InstallEventHandler failed with status \(status).")
            eventHandler = nil
            return false
        }
        return true
    }

    private static func carbonModifiers(from modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        return result
    }
}
