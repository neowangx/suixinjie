import AppKit
import Carbon.HIToolbox

enum CaptureMode: String, CaseIterable {
    case region, fullScreen

    var title: String { self == .region ? "区域截图" : "全屏截图" }
    var defaultShortcut: Shortcut {
        Shortcut(keyCode: UInt32(self == .region ? kVK_ANSI_4 : kVK_ANSI_3),
                 modifiers: UInt32(controlKey | shiftKey), label: self == .region ? "4" : "3")
    }
}

struct Shortcut: Codable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String

    var description: String {
        let symbols: [(Int, String)] = [(controlKey, "⌃"), (optionKey, "⌥"),
                                        (shiftKey, "⇧"), (cmdKey, "⌘")]
        return symbols.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + label
    }

    func matches(_ other: Shortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        let mappings: [(NSEvent.ModifierFlags, Int)] = [(.shift, shiftKey), (.option, optionKey),
                                                       (.control, controlKey), (.command, cmdKey)]
        let modifiers = mappings.reduce(UInt32(0)) { result, mapping in
            flags.contains(mapping.0) ? result | UInt32(mapping.1) : result
        }
        let specialKeys = [kVK_Space: "空格", kVK_Tab: "⇥", kVK_Return: "↩", kVK_Delete: "⌫",
                           kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→",
                           kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
                           kVK_PageUp: "⇞", kVK_PageDown: "⇟"]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                            kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                            kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        let code = Int(event.keyCode)
        let label: String
        if let special = specialKeys[code] {
            label = special
        } else if let index = functionKeys.firstIndex(of: code) {
            label = "F\(index + 1)"
        } else if let character = event.characters(byApplyingModifiers: []), character.count == 1,
                  character.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  character.unicodeScalars.allSatisfy({ !(0xF700...0xF8FF).contains($0.value) }) {
            label = character.uppercased()
        } else {
            return nil
        }
        self.init(keyCode: UInt32(code), modifiers: modifiers, label: label)
    }
}

@MainActor
final class HotKeys {
    private struct Registration {
        let id: UInt32
        let ref: EventHotKeyRef
    }

    private static let signature: OSType = 0x536E6170
    private let defaults: UserDefaults
    private var handler: EventHandlerRef?
    private var registrations: [CaptureMode: Registration] = [:]
    private var shortcuts: [CaptureMode: Shortcut] = [:]
    private var nextID: UInt32 = 0
    var onPress: ((CaptureMode) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == HotKeys.signature else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            let registrationID = id.id
            DispatchQueue.main.async { manager.handle(registrationID) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)

        if status != noErr { handler = nil }
        for mode in CaptureMode.allCases {
            let stored = defaults.data(forKey: preferenceKey(mode))
            let shortcut = stored.flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
            shortcuts[mode] = shortcut ?? mode.defaultShortcut
        }
        for mode in CaptureMode.allCases {
            _ = install(shortcut(for: mode), for: mode)
        }
    }

    func shortcut(for mode: CaptureMode) -> Shortcut { shortcuts[mode] ?? mode.defaultShortcut }

    func isRegistered(_ mode: CaptureMode) -> Bool { registrations[mode] != nil }

    func stop() {
        for registration in registrations.values { UnregisterEventHotKey(registration.ref) }
        registrations.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    func change(_ shortcut: Shortcut, for mode: CaptureMode) -> String? {
        if CaptureMode.allCases.contains(where: { $0 != mode && self.shortcut(for: $0).matches(shortcut) }) {
            return "这个组合已分配给另一种截图方式。请换一个组合。"
        }
        guard install(shortcut, for: mode) else {
            return "无法注册这个组合，可能已被 macOS 或其他 App 占用。请换一个组合。"
        }
        shortcuts[mode] = shortcut
        if let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: preferenceKey(mode))
        }
        return nil
    }

    private func install(_ shortcut: Shortcut, for mode: CaptureMode) -> Bool {
        guard handler != nil else { return false }
        let previous = registrations[mode]
        if previous != nil, self.shortcut(for: mode).matches(shortcut) { return true }

        nextID += 1
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: nextID)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier,
                                         GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else { return false }
        if let previous { UnregisterEventHotKey(previous.ref) }
        registrations[mode] = Registration(id: nextID, ref: reference)
        return true
    }

    private func handle(_ id: UInt32) {
        if let mode = registrations.first(where: { $0.value.id == id })?.key { onPress?(mode) }
    }

    private func preferenceKey(_ mode: CaptureMode) -> String { "shortcut.\(mode.rawValue)" }
}
