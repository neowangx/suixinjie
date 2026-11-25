import AppKit
import Carbon.HIToolbox

private struct CheckFailed: Error, CustomStringConvertible {
    let description: String
}

@main
@MainActor
enum Verify {
    private static let size = CGSize(width: 480, height: 300)

    static func main() async {
        _ = NSApplication.shared
        do {
            let snapshot = try fixture()
            try verifyEditor(snapshot)
            try verifyAnnotationTools(snapshot)
            try verifyToolbarAlignment(snapshot)
            try verifyCompactToolbar(snapshot)
            try verifyShortcuts()
            try verifyUpdater()
            try await verifyScreenCapture()
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func verifyUpdater() throws {
        let version = try unwrap(UpdateVersion("v0.2.0"), "update version")
        let installed = try unwrap(UpdateVersion("0.1.10"), "installed version")
        try require(installed < version && UpdateVersion("v0.2.0-rc.1") == nil, "stable version comparison")
        let hash = String(repeating: "a", count: 64)
        let asset = GitHubUpdater.assetName
        let url = "\(GitHubUpdater.releasePage.absoluteString)/download/v0.2.0/\(asset)"
        func payload(download: String = url, digest: String = "sha256:" + hash, pre: Bool = false) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "tag_name": "v0.2.0", "draft": false, "prerelease": pre, "assets": [
                    ["name": asset, "browser_download_url": download, "digest": digest, "size": 3, "state": "uploaded"]
                ]
            ])
        }
        let update = try GitHubUpdater.offer(from: payload(), installed: installed, assetName: asset)
        try require(update?.version == version && update?.sha256 == hash, "expected GitHub release asset")
        let same = try GitHubUpdater.offer(from: payload(), installed: version, assetName: asset)
        let prerelease = try GitHubUpdater.offer(from: payload(pre: true), installed: installed, assetName: asset)
        let wrongPlatform = try GitHubUpdater.offer(from: payload(), installed: installed, assetName: "Suixinjie-windows.zip")
        try require(same == nil && prerelease == nil && wrongPlatform == nil, "ignore installed, prerelease and other platform")
        do {
            _ = try GitHubUpdater.offer(from: payload(download: "https://example.com/archive.zip"), installed: installed, assetName: asset)
            throw CheckFailed(description: "accepted another update source")
        } catch UpdaterError.invalidPackage { }
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: archive) }
        try Data("abc".utf8).write(to: archive)
        try GitHubUpdater.verifyArchive(archive, size: 3, sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        do {
            try GitHubUpdater.verifyArchive(archive, size: 3, sha256: hash)
            throw CheckFailed(description: "accepted a mismatched update digest")
        } catch UpdaterError.invalidPackage { }
        print("PASS: update version, platform and origin checks, and SHA-256 validation")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckFailed(description: message) }
    }

    private static func fixture() throws -> CGImage {
        let space = try unwrap(CGColorSpace(name: CGColorSpace.sRGB), "color space")
        let context = try unwrap(CGContext(data: nil, width: 960, height: 600, bitsPerComponent: 8,
                                           bytesPerRow: 0, space: space,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "fixture context")
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 300, width: 960, height: 300))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 960, height: 300))
        context.setFillColor(gray: 0, alpha: 1)
        for x in stride(from: 640, to: 760, by: 8) {
            context.fill(CGRect(x: x, y: 380, width: 4, height: 60))
        }
        return try unwrap(context.makeImage(), "fixture image")
    }

    private static func verifyAnnotationTools(_ snapshot: CGImage) throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = EditorCanvas(snapshot: snapshot, size: size, mode: .fullScreen)
        window.contentView = canvas
        canvas.layoutSubtreeIfNeeded()
        var output: CGImage?
        canvas.onOutput = { image, _ in output = image }
        func bitmap() throws -> NSBitmapImageRep {
            try button("复制到剪贴板", in: canvas).performClick(nil)
            return NSBitmapImageRep(cgImage: try unwrap(output, "annotation tools output"))
        }
        func redComponent(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
            image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.redComponent ?? 0
        }
        let tools = ["矩形", "椭圆", "箭头", "画笔", "马赛克", "文字", "表情", "撤销", "重做", "保存到本地…", "取消", "复制到剪贴板"]
        for title in tools {
            let item = try button(title, in: canvas)
            try require(item.image != nil && canvas.bounds.contains(canvas.convert(item.bounds, from: item)),
                        "reachable icon for \(title)")
        }

        try button("箭头", in: canvas).performClick(nil)
        try drag(canvas, from: CGPoint(x: 42, y: 44), to: CGPoint(x: 120, y: 44))
        try button("画笔", in: canvas).performClick(nil)
        try button("蓝色", in: canvas).performClick(nil)
        try button("大", in: canvas).performClick(nil)
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 45, y: 94), in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 88, y: 72), in: canvas))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 125, y: 94), in: canvas))
        try button("表情", in: canvas).performClick(nil)
        try button("⭐", in: canvas).performClick(nil)
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 208, y: 88), in: canvas))

        try button("马赛克", in: canvas).performClick(nil)
        try button("中", in: canvas).performClick(nil)
        try drag(canvas, from: CGPoint(x: 324, y: 96), to: CGPoint(x: 374, y: 96))
        let marked = try bitmap()
        try require(isRed(marked, x: 150, y: 88) && isRed(marked, x: 215, y: 94), "arrow stroke and arrowhead")
        let ink = marked.colorAt(x: 176, y: 148)?.usingColorSpace(.sRGB)
        try require((ink?.blueComponent ?? 0) > 0.88 && (ink?.redComponent ?? 1) < 0.4, "thick blue brush along drag path")
        let emoji = (146..<206).contains { y in (382..<450).contains { x in
            guard let pixel = marked.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            return pixel.redComponent > 0.8 && pixel.greenComponent > 0.45 && pixel.blueComponent < 0.4
        } }
        try require(emoji, "emoji exported in color")
        try require(abs(redComponent(marked, 650, 188) - redComponent(marked, 654, 188)) < 0.02,
                    "mosaic replaces fine detail with blocks")
        try require(redComponent(marked, 650, 166) < 0.1 && redComponent(marked, 654, 166) > 0.9,
                    "mosaic does not affect unpainted pixels")

        try button("撤销", in: canvas).performClick(nil)
        let undone = try bitmap()
        try require(redComponent(undone, 650, 188) < 0.1 && redComponent(undone, 654, 188) > 0.9,
                    "undo restores the original pixels")
        let redo = try keyboard(kVK_ANSI_Z, "z", modifiers: [.command, .shift])
        try require(canvas.performKeyEquivalent(with: redo), "redo keyboard equivalent")
        let redone = try bitmap()
        try require(abs(redComponent(redone, 650, 188) - redComponent(redone, 654, 188)) < 0.02,
                    "redo restores the mosaic")
        print("PASS: native toolbar icons, arrow, colored freehand stroke, emoji, mosaic, undo and redo")
    }

    private static func verifyToolbarAlignment(_ snapshot: CGImage) throws {
        let wide = CGSize(width: 880, height: 500)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: wide), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = EditorCanvas(snapshot: snapshot, size: wide, mode: .fullScreen)
        window.contentView = canvas
        let toolbar = try unwrap(canvas.subviews.first, "toolbar")
        let rectangle = try button("矩形", in: toolbar)
        let copy = try button("复制到剪贴板", in: toolbar)
        for title in ["矩形", "马赛克"] {
            try button(title, in: toolbar).performClick(nil)
            canvas.layoutSubtreeIfNeeded()
            let first = toolbar.convert(rectangle.bounds, from: rectangle)
            let last = toolbar.convert(copy.bounds, from: copy)
            try require(abs(first.minX - toolbar.bounds.minX - 10) < 0.5, "first tool aligns left for \(title)")
            try require(abs(toolbar.bounds.maxX - last.maxX - 10) < 0.5, "copy aligns right for \(title)")
        }
        print("PASS: first tool aligns left and copy aligns right as tool options change")
    }

    private static func verifyCompactToolbar(_ snapshot: CGImage) throws {
        let narrow = CGSize(width: 320, height: 320)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: narrow), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = EditorCanvas(snapshot: snapshot, size: narrow, mode: .fullScreen)
        window.contentView = canvas
        canvas.layoutSubtreeIfNeeded()
        let save = try button("保存到本地…", in: canvas)
        let copy = try button("复制到剪贴板", in: canvas)
        try require(save.imagePosition == .imageLeft && copy.imagePosition == .imageLeft, "visible output labels")
        for item in [save, copy, try button("矩形", in: canvas), try button("取消", in: canvas)] {
            let bounds = canvas.convert(item.bounds, from: item)
            try require(bounds.width >= 44 && bounds.height >= 44 && canvas.bounds.contains(bounds),
                        "large reachable target for \(item.title) on a narrow display, actual \(bounds)")
            let center = canvas.convert(CGPoint(x: bounds.midX, y: bounds.midY), to: canvas.superview)
            try require(canvas.hitTest(center) === item, "button receives clicks for \(item.title)")
        }
        print("PASS: full-size toolbar actions wrap and remain visible at 320 points")
    }

    private static func verifyEditor(_ snapshot: CGImage) throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = EditorCanvas(snapshot: snapshot, size: size, mode: .region)
        window.contentView = canvas
        var lastOutput: (CGImage, Bool)?
        var canceled = false
        canvas.onOutput = { lastOutput = ($0, $1) }
        canvas.onCancel = { canceled = true }

        canvas.keyDown(with: try keyboard(kVK_Return, "\r"))
        try require(lastOutput == nil, "Return before selecting an area")
        try drag(canvas, from: CGPoint(x: 260, y: 220), to: CGPoint(x: 25, y: 20))
        canvas.layoutSubtreeIfNeeded()
        let finishButton = try button("复制到剪贴板", in: canvas)
        try require(finishButton.frame.width >= 44, "visible editing toolbar")
        try drag(canvas, from: CGPoint(x: 38, y: 32), to: CGPoint(x: 112, y: 72))
        try button("椭圆", in: canvas).performClick(nil)
        try drag(canvas, from: CGPoint(x: 128, y: 42), to: CGPoint(x: 196, y: 86))
        try button("文字", in: canvas).performClick(nil)
        let click = try mouse(.leftMouseDown, at: CGPoint(x: 42, y: 95), in: canvas)
        canvas.mouseDown(with: click)
        let field = try unwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first, "inline text field")
        if let editor = field.currentEditor() { editor.string = "截图 Text" } else { field.stringValue = "截图 Text" }
        try button("保存到本地…", in: canvas).performClick(nil)
        let (image, save) = try unwrap(lastOutput, "save action image")
        try require(save && image.width == 470 && image.height == 400, "2× region selection and save action")

        let bitmap = NSBitmapImageRep(cgImage: image)
        try require(isRed(bitmap, x: 80, y: 24), "rectangle at its expected coordinates")
        try require(isRed(bitmap, x: 274, y: 44), "ellipse at its expected coordinates")
        let hasText = (154..<202).contains { y in (34..<190).contains { x in isRed(bitmap, x: x, y: y) } }
        try require(hasText, "text near its expected coordinates")
        try require((bitmap.colorAt(x: 6, y: 6)?.redComponent ?? 0) > 0.9, "crop orientation near top")
        let bottom = bitmap.colorAt(x: 6, y: 390)?.redComponent ?? 0
        try require(bottom > 0.45 && bottom < 0.55, "crop orientation near bottom")

        let saveKey = try keyboard(kVK_ANSI_S, "s", modifiers: .command)
        lastOutput = nil
        try require(canvas.performKeyEquivalent(with: saveKey), "Command-S saves")
        try require(lastOutput?.1 == true, "Command-S uses file output")
        lastOutput = nil
        canvas.keyDown(with: try keyboard(kVK_Return, "\r"))
        let (copyImage, copyWasSave) = try unwrap(lastOutput, "Return action image")
        try require(!copyWasSave, "Return uses clipboard action")
        try verifyOutput(copyImage)
        canvas.keyDown(with: try keyboard(kVK_Escape, "\u{1B}"))
        try require(canceled, "Esc cancels editing")
        try button("重选", in: canvas).performClick(nil)
        lastOutput = nil
        canvas.keyDown(with: try keyboard(kVK_Return, "\r"))
        try require(lastOutput == nil, "reselect clears the active selection")

        let fullScreen = EditorCanvas(snapshot: snapshot, size: size, mode: .fullScreen)
        window.contentView = fullScreen
        fullScreen.onOutput = { lastOutput = ($0, $1) }
        fullScreen.keyDown(with: try keyboard(kVK_Return, "\r"))
        let (fullImage, _) = try unwrap(lastOutput, "full-screen action image")
        try require(fullImage.width == 960 && fullImage.height == 600, "full-screen keeps all pixels")
        print("PASS: region and full-screen editor, 2× crop, rectangle, ellipse, text, reselect, cancel, clipboard and PNG file")
    }

    private static func verifyOutput(_ image: CGImage) throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try CaptureOutput.copy(image, to: pasteboard)
        let png = try unwrap(pasteboard.data(forType: .png), "PNG through system pasteboard")
        try require(pasteboard.data(forType: .tiff) != nil, "TIFF through system pasteboard")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("已标记.png")
        try CaptureOutput.save(png, to: url)
        let contents = try Data(contentsOf: url)
        let saved = try unwrap(NSBitmapImageRep(data: contents), "decode saved PNG")
        try require(saved.pixelsWide == image.width && saved.pixelsHigh == image.height, "saved PNG dimensions")
        try require(isRed(saved, x: 80, y: 24), "saved PNG contains annotations")
    }

    private static func verifyShortcuts() throws {
        let domain = "app.suixinjie.macos.verify.\(UUID().uuidString)"
        let defaults = try unwrap(UserDefaults(suiteName: domain), "isolated shortcut preferences")
        defer { defaults.removePersistentDomain(forName: domain) }
        let hotKeys = HotKeys(defaults: defaults)
        defer { hotKeys.stop() }
        try require(hotKeys.isRegistered(.region) && hotKeys.isRegistered(.fullScreen), "default Carbon hotkeys")
        let settings = Settings(hotKeys: hotKeys)
        var updates = 0
        settings.onChange = { updates += 1 }
        let window = try unwrap(NSApp.windows.first { $0.title == "随心截设置" }, "settings window")
        let view = try unwrap(window.contentView, "settings view")
        let record = try button(hotKeys.shortcut(for: .region).description, in: view)
        record.performClick(nil)
        try require(window.firstResponder === record, "shortcut recorder receives keyboard focus")
        let event = try keyboard(kVK_ANSI_J, "j", modifiers: [.control, .option, .shift, .command])
        let shortcut = try unwrap(Shortcut(event: event), "shortcut from key event")
        try require(shortcut.description == "⌃⌥⇧⌘J", "shortcut display label")
        record.keyDown(with: event)
        try require(updates == 1 && hotKeys.isRegistered(.region) && record.title == shortcut.description,
                    "new Carbon registration from settings")
        try require(hotKeys.change(shortcut, for: .fullScreen) != nil, "reject duplicate shortcut")
        try require(hotKeys.shortcut(for: .fullScreen).matches(CaptureMode.fullScreen.defaultShortcut), "keep previous shortcut on conflict")
        let stored = try unwrap(defaults.data(forKey: "shortcut.region"), "persisted shortcut")
        let decoded = try JSONDecoder().decode(Shortcut.self, from: stored)
        try require(decoded.matches(shortcut), "correct persisted shortcut")
        print("PASS: default Carbon registration, key recording, custom registration, conflict and preference")
        withExtendedLifetime(settings) {}
    }

    private static func verifyScreenCapture() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            print("SKIP: screen capture from this test process requires user authorization")
            return
        }
        let screens = NSScreen.screens
        try require(!screens.isEmpty, "connected displays")
        for screen in screens {
            let id = try unwrap(ScreenSnapshot.displayID(for: screen), "display ID")
            let image = try await ScreenSnapshot.capture(displayID: id)
            let expectedWidth = Int((screen.frame.width * screen.backingScaleFactor).rounded())
            let expectedHeight = Int((screen.frame.height * screen.backingScaleFactor).rounded())
            try require(image.width == expectedWidth && image.height == expectedHeight, "captured display dimensions")
            print("PASS: ScreenCaptureKit captured a display at \(image.width)×\(image.height)")
        }
    }

    private static func isRed(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> Bool {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
        return color.redComponent > 0.8 && color.greenComponent < 0.45 && color.blueComponent < 0.45
    }

    private static func button(_ title: String, in view: NSView) throws -> NSButton {
        if let button = view as? NSButton, button.title == title { return button }
        for child in view.subviews {
            if let match = try? button(title, in: child) { return match }
        }
        throw CheckFailed(description: "Missing button: \(title)")
    }

    private static func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView) throws -> NSEvent {
        try unwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                      timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1), "mouse event")
    }

    private static func drag(_ canvas: EditorCanvas, from: CGPoint, to: CGPoint) throws {
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: from, in: canvas))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: to, in: canvas))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: to, in: canvas))
    }

    private static func keyboard(_ code: Int, _ character: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                     windowNumber: 0, context: nil, characters: character,
                                     charactersIgnoringModifiers: character, isARepeat: false, keyCode: UInt16(code)), "key event")
    }

    private static func unwrap<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw CheckFailed(description: "Missing \(name)") }
        return value
    }
}
