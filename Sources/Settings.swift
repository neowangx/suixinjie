import AppKit
import Carbon.HIToolbox
import ServiceManagement

@MainActor
private final class ShortcutButton: NSButton {
    var recording = false
    var onEvent: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if recording { onEvent?(event) } else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        onEvent?(event)
        return true
    }
}

@MainActor
final class Settings: NSObject, NSWindowDelegate {
    private let hotKeys: HotKeys
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 224),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let login = NSButton(checkboxWithTitle: "登录时启动随心截", target: nil, action: nil)
    private let loginNote = NSTextField(wrappingLabelWithString: "")
    private let shortcutNote = NSTextField(wrappingLabelWithString: "")
    private var buttons: [CaptureMode: ShortcutButton] = [:]
    private var recordingMode: CaptureMode?
    var onChange: (() -> Void)?

    init(hotKeys: HotKeys) {
        self.hotKeys = hotKeys
        super.init()
        window.title = "随心截设置"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16)
        ])
        window.contentView = content

        for mode in CaptureMode.allCases {
            let label = NSTextField(labelWithString: mode.title)
            let button = ShortcutButton()
            button.bezelStyle = .rounded
            button.setAccessibilityLabel("\(mode.title)快捷键")
            button.target = self
            button.action = #selector(beginRecording(_:))
            button.onEvent = { [weak self] event in self?.record(event) }
            buttons[mode] = button
            label.widthAnchor.constraint(equalToConstant: 75).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 118).isActive = true
            stack.addArrangedSubview(NSStackView(views: [label, button]))
        }

        for note in [shortcutNote, loginNote] {
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = 392
        }
        stack.addArrangedSubview(shortcutNote)
        login.target = self
        login.action = #selector(toggleLogin)
        stack.addArrangedSubview(login)
        stack.addArrangedSubview(loginNote)
        updateShortcuts()
        refreshLogin()
        window.center()
    }

    func show() {
        refreshLogin()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { stopRecording() }
    func windowDidResignKey(_ notification: Notification) { stopRecording() }

    func handleRegisteredShortcut(_ mode: CaptureMode) -> Bool {
        guard window.isKeyWindow, let recordingMode else { return false }
        setShortcut(hotKeys.shortcut(for: mode), for: recordingMode)
        return true
    }

    func refreshLogin() {
        let status = SMAppService.mainApp.status
        login.state = status == .enabled || status == .requiresApproval ? .on : .off
        loginNote.stringValue = status == .requiresApproval
            ? "请在「系统设置 → 通用 → 登录项与扩展」中允许随心截启动。" : ""
    }

    @objc private func beginRecording(_ sender: ShortcutButton) {
        guard let mode = buttons.first(where: { $0.value === sender })?.key else { return }
        recordingMode = mode
        for (buttonMode, button) in buttons { button.recording = buttonMode == mode }
        window.makeFirstResponder(sender)
        updateShortcuts("同时按下修饰键和主键。按 Esc 退出录入。")
    }

    private func record(_ event: NSEvent) {
        guard let mode = recordingMode, !event.isARepeat else { return }
        if event.keyCode == kVK_Escape {
            stopRecording()
        } else if let shortcut = Shortcut(event: event) {
            setShortcut(shortcut, for: mode)
        } else {
            updateShortcuts("请使用 Control、Option 或 Command，再加一个主键。")
        }
    }

    private func setShortcut(_ shortcut: Shortcut, for mode: CaptureMode) {
        if let error = hotKeys.change(shortcut, for: mode) {
            updateShortcuts(error)
        } else {
            stopRecording("快捷键已更新。")
            onChange?()
        }
    }

    private func stopRecording(_ message: String? = nil) {
        recordingMode = nil
        for button in buttons.values { button.recording = false }
        updateShortcuts(message)
    }

    private func updateShortcuts(_ message: String? = nil) {
        for (mode, button) in buttons {
            button.title = recordingMode == mode ? "请按快捷键…" : hotKeys.shortcut(for: mode).description
        }
        let unavailable = CaptureMode.allCases.filter { !hotKeys.isRegistered($0) }.map(\.title)
        shortcutNote.stringValue = message ?? (unavailable.isEmpty ? "点击快捷键即可修改。"
            : "\(unavailable.joined(separator: "、"))的快捷键不可用。请点击修改。")
    }

    @objc private func toggleLogin() {
        stopRecording()
        do {
            if login.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLogin()
        } catch {
            refreshLogin()
            loginNote.stringValue = "无法更新登录项。\(error.localizedDescription)"
        }
    }
}
