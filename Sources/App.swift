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
    private var checkingUpdates = false
    private var promptingUpdate = false
    private var installingUpdate = false
    private var pendingUpdate: UpdateOffer?
    private let updateCheckKey = "updates.lastSuccessfulCheck"

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
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            while let self {
                let last = UserDefaults.standard.object(forKey: self.updateCheckKey) as? Date ?? .distantPast
                if Date().timeIntervalSince(last) >= 24 * 60 * 60 {
                    self.checkForUpdates(manually: false)
                }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
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
        addItem("检查更新…", action: #selector(checkForUpdatesFromMenu), to: menu)
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
        guard !installingUpdate, !promptingUpdate else { return }
        if settings == nil {
            let controller = Settings(hotKeys: hotKeys)
            controller.onChange = { [weak self] in self?.updateMenu() }
            controller.onClose = { [weak self] in
                Task { @MainActor in self?.presentPendingUpdate() }
            }
            settings = controller
        }
        settings?.show()
    }

    private func startCapture(_ mode: CaptureMode, fromMenu: Bool = false) {
        guard !capturing, editor == nil, !installingUpdate, !promptingUpdate else { return }
        capturing = true
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        Task { [self] in
            defer { capturing = false; presentPendingUpdate() }
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
                window.onFinish = { [weak self] in
                    self?.editor = nil
                    self?.presentPendingUpdate()
                }
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

    @objc private func checkForUpdatesFromMenu() { checkForUpdates(manually: true) }

    private func checkForUpdates(manually: Bool) {
        guard !checkingUpdates, !promptingUpdate, !installingUpdate,
              let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let installed = UpdateVersion(value) else { return }
        checkingUpdates = true
        Task {
            defer { checkingUpdates = false; presentPendingUpdate() }
            do {
                pendingUpdate = try await GitHubUpdater.latest(installed: installed)
                UserDefaults.standard.set(Date(), forKey: updateCheckKey)
                if manually && pendingUpdate == nil && canPromptForUpdate {
                    showUpdateMessage("没有可用更新", "GitHub 上暂时没有适用于这台 Mac 的更新包。")
                }
            } catch {
                if manually && canPromptForUpdate { showUpdateFailure(error) }
            }
        }
    }

    private var canPromptForUpdate: Bool {
        !capturing && editor == nil && settings?.isVisible != true && !promptingUpdate && !installingUpdate
    }

    private func presentPendingUpdate() {
        guard canPromptForUpdate, let update = pendingUpdate else { return }
        pendingUpdate = nil
        promptingUpdate = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "随心截 \(update.version) 可用"
        alert.informativeText = "更新将从 GitHub 下载并校验。安装后随心截会重新启动。"
        alert.addButton(withTitle: "更新并重启").keyEquivalent = ""
        alert.addButton(withTitle: "稍后").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "查看发行说明")
        let choice = alert.runModal()
        promptingUpdate = false
        if choice == .alertThirdButtonReturn {
            NSWorkspace.shared.open(update.page)
        } else if choice == .alertFirstButtonReturn {
            installingUpdate = true
            Task {
                do {
                    try await GitHubUpdater.prepareAndLaunch(update, replacing: Bundle.main.bundleURL)
                    NSApp.terminate(nil)
                } catch {
                    installingUpdate = false
                    showUpdateFailure(error)
                }
            }
        }
    }

    private func showUpdateMessage(_ title: String, _ detail: String, showReleases: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        if showReleases { alert.addButton(withTitle: "打开 GitHub Releases") }
        if alert.runModal() == .alertSecondButtonReturn && showReleases {
            NSWorkspace.shared.open(GitHubUpdater.releasePage)
        }
    }

    private func showUpdateFailure(_ error: Error) {
        showUpdateMessage("无法更新随心截", error.localizedDescription, showReleases: true)
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
