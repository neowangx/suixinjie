import AppKit
import OSLog
import ScreenCaptureKit

@main
@MainActor
enum SuixinjieMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let captureLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.suixinjie.macos",
                                    category: "ScreenCapture")
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let hotKeys = HotKeys()
    private var settings: Settings?
    private var editor: EditorWindow?
    private var capturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "随心截")
            button.toolTip = "随心截"
        }
        updateMenu()
        hotKeys.onPress = { [weak self] mode in
            guard let self, self.settings?.handleRegisteredShortcut(mode) != true else { return }
            self.startCapture(mode)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { settings?.refreshLogin() }
    func applicationWillTerminate(_ notification: Notification) { hotKeys.stop() }

    private func updateMenu() {
        let menu = NSMenu()
        for (mode, action) in [(CaptureMode.region, #selector(captureRegion)),
                               (CaptureMode.fullScreen, #selector(captureFullScreen))] {
            let shortcut = hotKeys.shortcut(for: mode).description
            let title = hotKeys.isRegistered(mode) ? "\(mode.title)    \(shortcut)" : mode.title
            addItem(title, action: action, to: menu)
        }
        menu.addItem(.separator())
        addItem("设置…", action: #selector(showSettings), to: menu)
        addItem("退出随心截", action: #selector(quit), to: menu)
        statusItem.menu = menu
    }

    private func addItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func captureRegion() { startCapture(.region, fromMenu: true) }
    @objc private func captureFullScreen() { startCapture(.fullScreen, fromMenu: true) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showSettings() {
        if settings == nil {
            let controller = Settings(hotKeys: hotKeys)
            controller.onChange = { [weak self] in self?.updateMenu() }
            settings = controller
        }
        settings?.show()
    }

    private func startCapture(_ mode: CaptureMode, fromMenu: Bool = false) {
        guard !capturing, editor == nil else { return }
        capturing = true
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        Task { [self] in
            defer { capturing = false }
            // A tracked status menu lingers briefly while AppKit dismisses it.
            if fromMenu { try? await Task.sleep(for: .milliseconds(150)) }
            guard let screen, let id = ScreenSnapshot.displayID(for: screen) else {
                showError(CaptureFailure.displayUnavailable)
                return
            }

            do {
                let snapshot = try await ScreenSnapshot.capture(displayID: id)
                captureLog.debug("ScreenCaptureKit captured \(snapshot.width) × \(snapshot.height) pixels.")
                guard let target = NSScreen.screens.first(where: { ScreenSnapshot.displayID(for: $0) == id }),
                      target.frame.size == screen.frame.size else {
                    throw CaptureFailure.displayUnavailable
                }
                let window = EditorWindow(screen: target, snapshot: snapshot, mode: mode)
                window.onFinish = { [weak self] in self?.editor = nil }
                editor = window
                window.present()
            } catch {
                let failure = error as NSError
                captureLog.error("Capture failed in \(failure.domain, privacy: .public), code \(failure.code).")
                if failure.domain == SCStreamError.errorDomain,
                   failure.code == SCStreamError.Code.userDeclined.rawValue {
                    showPermissionInstructions()
                } else {
                    showError(error)
                }
            }
        }
    }

    private func showPermissionInstructions() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "随心截需要屏幕录制权限"
        alert.informativeText = """
        macOS 拒绝了此副本的屏幕录制。

        \(Bundle.main.bundlePath)

        请在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」中启用此副本。若同名开关已经打开，可用「−」移除旧条目，再用「+」添加上面路径中的应用。完成后退出并重新打开随心截。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        NSAlert(error: error).runModal()
    }
}
