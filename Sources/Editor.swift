import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

@MainActor
final class EditorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private var saving = false
    private var finished = false
    var onFinish: (() -> Void)?

    init(screen: NSScreen, snapshot: CGImage, mode: CaptureMode) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        hasShadow = false

        let canvas = EditorCanvas(snapshot: snapshot, size: screen.frame.size, mode: mode)
        contentView = canvas
        initialFirstResponder = canvas
        canvas.onCancel = { [weak self] in self?.finish() }
        canvas.onOutput = { [weak self] image, save in self?.output(image, save: save) }
        canvas.onError = { [weak self] error in self?.showError(error) }
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func present() {
        guard !saving, !finished else { return }
        makeKeyAndOrderFront(nil)
        makeFirstResponder(contentView)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        orderOut(nil)
        contentView = nil
        onFinish?()
    }

    private func output(_ image: CGImage, save: Bool) {
        do {
            if save {
                chooseDestination(for: try CaptureOutput.png(from: image))
            } else {
                try CaptureOutput.copy(image)
                finish()
            }
        } catch { showError(error) }
    }

    private func chooseDestination(for data: Data) {
        let panel = NSSavePanel()
        panel.title = "保存截图"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        panel.nameFieldStringValue = "截图 \(formatter.string(from: Date())).png"
        saving = true
        orderOut(nil)
        panel.begin { [weak self] response in
            guard let self else { return }
            self.saving = false
            if response == .OK, let url = panel.url {
                do {
                    try CaptureOutput.save(data, to: url)
                    self.finish()
                    return
                } catch { self.showError(error) }
            }
            self.present()
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        if isVisible {
            level = .floating
            alert.runModal()
            level = .screenSaver
            present()
        } else {
            alert.runModal()
        }
    }
}

@MainActor
final class EditorCanvas: NSView, NSTextFieldDelegate {
    private enum Tool: Int, CaseIterable {
        case rectangle, ellipse, arrow, brush, mosaic, text, emoji

        var title: String {
            switch self {
            case .rectangle: return "矩形"
            case .ellipse: return "椭圆"
            case .arrow: return "箭头"
            case .brush: return "画笔"
            case .mosaic: return "马赛克"
            case .text: return "文字"
            case .emoji: return "表情"
            }
        }

        var symbol: String {
            switch self {
            case .rectangle: return "rectangle"
            case .ellipse: return "oval"
            case .arrow: return "arrow.up.right"
            case .brush: return "pencil.tip"
            case .mosaic: return "squareshape.split.3x3"
            case .text: return "textformat"
            case .emoji: return "face.smiling"
            }
        }

        var drawsStroke: Bool { self == .brush || self == .mosaic }
        var usesColor: Bool { self != .mosaic && self != .emoji }
    }

    private static let palette: [(String, NSColor)] = [
        ("红色", NSColor(srgbRed: 1, green: 0.24, blue: 0.25, alpha: 1)),
        ("橙色", NSColor(srgbRed: 1, green: 0.53, blue: 0.10, alpha: 1)),
        ("黄色", NSColor(srgbRed: 1, green: 0.81, blue: 0.18, alpha: 1)),
        ("绿色", NSColor(srgbRed: 0.22, green: 0.78, blue: 0.39, alpha: 1)),
        ("蓝色", NSColor(srgbRed: 0.24, green: 0.56, blue: 1, alpha: 1)),
        ("白色", .white), ("黑色", .black)
    ]
    private static let emojis = ["👍", "✅", "❌", "⭐", "🙂", "❗"]
    private static let selectionTint = NSColor(srgbRed: 0.60, green: 0.80, blue: 1, alpha: 1)

    private let snapshot: CGImage
    private let preview: NSImage
    private let mode: CaptureMode
    private let toolbar = NSVisualEffectView()
    private let toolbarStack = NSStackView()
    private let mainRow = NSStackView()
    private let optionsRow = NSStackView()
    private let colorOptions = NSStackView()
    private let emojiOptions = NSStackView()
    private let sizeOptions = NSStackView()
    private var toolButtons: [NSButton] = []
    private var undoButton: NSButton?
    private var redoButton: NSButton?
    private var colorIndex = 0
    private var emojiIndex = 0
    private var annotationSize: Annotation.Size = .medium
    private var annotationColor: NSColor { Self.palette[colorIndex].1 }
    private var tool: Tool = .rectangle
    private var selection: CGRect?
    private var dragOrigin: CGPoint?
    private var dragEnd: CGPoint?
    private var selectionDraft: CGRect?
    private var strokePoints: [CGPoint] = []
    private var constrainShape = false
    private var pixelation: CGImage?
    private var annotations: [Annotation] = []
    private var undoneAnnotations: [Annotation] = []
    private var textField: NSTextField?
    private var textOrigin: CGPoint?
    var onOutput: ((CGImage, Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onError: ((Error) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    init(snapshot: CGImage, size: CGSize, mode: CaptureMode) {
        self.snapshot = snapshot
        self.preview = NSImage(cgImage: snapshot, size: size)
        self.mode = mode
        self.selection = mode == .fullScreen ? CGRect(origin: .zero, size: size) : nil
        super.init(frame: CGRect(origin: .zero, size: size))
        setAccessibilityLabel("截图编辑")
        setUpToolbar()
        updateToolbar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        preview.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)

        let visible = selection ?? selectionDraft
        if mode == .region {
            let shade = NSBezierPath(rect: bounds)
            if let visible { shade.appendRect(visible) }
            shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.42).setFill()
            shade.fill()
        }

        guard let visible else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: visible).addClip()
        for annotation in annotations { annotation.draw(pixelation: pixelation, displaySize: bounds.size) }
        dragAnnotation()?.draw(pixelation: pixelation, displaySize: bounds.size)
        NSGraphicsContext.restoreGraphicsState()

        if mode == .region {
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: visible)
            border.lineWidth = 1.5
            border.stroke()
        }
    }

    override func layout() {
        super.layout()
        guard let selection else { return }
        let size = toolbarStack.fittingSize
        let width = size.width + 16
        let height = size.height + 10
        let margin: CGFloat = 7
        let x = max(margin, min(selection.maxX - width, bounds.maxX - width - margin))
        let below = selection.maxY + margin
        let above = selection.minY - height - margin
        let y = below + height <= bounds.maxY ? below : max(margin, above >= margin ? above : bounds.maxY - height - margin)
        toolbar.frame = CGRect(x: x, y: y, width: width, height: height)
        toolbarStack.frame = toolbar.bounds.insetBy(dx: 8, dy: 5)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if let selection {
            addCursorRect(selection, cursor: tool == .text ? .iBeam : .crosshair)
        } else {
            addCursorRect(bounds, cursor: .crosshair)
        }
        if !toolbar.isHidden { addCursorRect(toolbar.frame, cursor: .arrow) }
    }

    override func mouseDown(with event: NSEvent) {
        finishText()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let selection {
            guard selection.contains(point) else { return }
            if tool == .text {
                startText(at: point, within: selection)
                return
            }
            if tool == .emoji {
                append(makeAnnotation(.emoji(Self.emojis[emojiIndex], point)))
                return
            }
            if tool == .mosaic, pixelation == nil {
                do { pixelation = try CaptureOutput.makePixelation(from: snapshot, displaySize: bounds.size) }
                catch { onError?(error); return }
            }
            if tool.drawsStroke { strokePoints = [point] }
        }
        dragOrigin = clamped(point, to: selection ?? bounds)
        dragEnd = dragOrigin
        constrainShape = event.modifierFlags.contains(.shift)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) { updateDrag(event) }

    override func mouseUp(with event: NSEvent) {
        guard dragOrigin != nil else { return }
        updateDrag(event)
        let annotation = dragAnnotation()
        dragOrigin = nil
        dragEnd = nil
        strokePoints.removeAll(keepingCapacity: true)
        if let candidate = selectionDraft, candidate.width >= 4, candidate.height >= 4 {
            selection = candidate
        }
        selectionDraft = nil
        if let annotation { append(annotation) } else { updateToolbar() }
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape: onCancel?()
        case kVK_Return, kVK_ANSI_KeypadEnter: output(save: false)
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.charactersIgnoringModifiers?.lowercased() == "z", textField == nil {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers == .command, !annotations.isEmpty { undo(); return true }
            if modifiers == [.command, .shift], !undoneAnnotations.isEmpty { redo(); return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)):
            finishText()
            return true
        case #selector(cancelOperation(_:)):
            finishText(commit: false)
            return true
        default: return false
        }
    }

    private func updateDrag(_ event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let end = clamped(convert(event.locationInWindow, from: nil), to: selection ?? bounds)
        dragEnd = end
        constrainShape = event.modifierFlags.contains(.shift)
        if selection == nil {
            selectionDraft = rect(from: origin, to: end)
        } else if tool.drawsStroke, strokePoints.last != end {
            strokePoints.append(end)
        }
        needsDisplay = true
    }

    private func dragAnnotation() -> Annotation? {
        guard selection != nil, let origin = dragOrigin, let end = dragEnd else { return nil }
        switch tool {
        case .rectangle, .ellipse:
            let rect = rect(from: origin, to: end, square: constrainShape)
            guard rect.width >= 3, rect.height >= 3 else { return nil }
            return makeAnnotation(tool == .ellipse ? .ellipse(rect) : .rectangle(rect))
        case .arrow:
            return hypot(end.x - origin.x, end.y - origin.y) >= 3 ? makeAnnotation(.arrow(origin, end)) : nil
        case .brush, .mosaic:
            return makeAnnotation(tool == .brush ? .brush(strokePoints) : .mosaic(strokePoints))
        case .text, .emoji:
            return nil
        }
    }

    private func rect(from start: CGPoint, to end: CGPoint, square: Bool = false) -> CGRect {
        let width = abs(end.x - start.x)
        let height = abs(end.y - start.y)
        let side = min(width, height)
        let w = square ? side : width
        let h = square ? side : height
        return CGRect(x: end.x < start.x ? start.x - w : start.x,
                      y: end.y < start.y ? start.y - h : start.y, width: w, height: h)
    }

    private func makeAnnotation(_ mark: Annotation.Mark) -> Annotation {
        Annotation(mark: mark, color: annotationColor, size: annotationSize)
    }

    private func append(_ annotation: Annotation) {
        annotations.append(annotation)
        undoneAnnotations.removeAll()
        updateToolbar()
        needsDisplay = true
    }

    private func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: max(rect.minX, min(point.x, rect.maxX)), y: max(rect.minY, min(point.y, rect.maxY)))
    }

    private func setUpToolbar() {
        toolbar.appearance = NSAppearance(named: .darkAqua)
        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 11
        toolbar.layer?.masksToBounds = true
        toolbar.layer?.borderWidth = 1
        toolbar.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        toolbarStack.orientation = .vertical
        toolbarStack.alignment = .leading
        toolbarStack.spacing = 4
        for row in [mainRow, optionsRow, colorOptions, emojiOptions, sizeOptions] {
            row.alignment = .centerY
            row.spacing = 2
        }

        for tool in Tool.allCases {
            let button = makeButton(tool.title, symbol: tool.symbol, action: #selector(selectTool(_:)), in: mainRow)
            button.setButtonType(.pushOnPushOff)
            button.tag = tool.rawValue
            toolButtons.append(button)
        }
        addDivider(to: mainRow)
        undoButton = makeButton("撤销", symbol: "arrow.uturn.backward", action: #selector(undo), in: mainRow)
        redoButton = makeButton("重做", symbol: "arrow.uturn.forward", action: #selector(redo), in: mainRow)
        if mode == .region {
            _ = makeButton("重选", symbol: "crop", action: #selector(reselect), in: mainRow)
        }
        _ = makeButton("保存…", symbol: "square.and.arrow.down", action: #selector(save), in: mainRow)
        _ = makeButton("取消", symbol: "xmark", action: #selector(cancel), in: mainRow)
        let copy = makeButton("完成并复制", symbol: "checkmark", action: #selector(copyImage), in: mainRow)
        copy.contentTintColor = .white
        copy.layer?.backgroundColor = NSColor(srgbRed: 0.19, green: 0.43, blue: 0.76, alpha: 1).cgColor
        copy.toolTip = "完成并复制（Return）"
        undoButton?.toolTip = "撤销（⌘Z）"
        redoButton?.toolTip = "重做（⇧⌘Z）"

        for (index, swatch) in Self.palette.enumerated() {
            let button = makeButton(swatch.0, symbol: "circle.fill", width: 25,
                                    action: #selector(chooseColor(_:)), in: colorOptions)
            button.tag = index
            button.contentTintColor = swatch.1
            button.setButtonType(.pushOnPushOff)
        }
        for (index, emoji) in Self.emojis.enumerated() {
            let button = makeButton(emoji, width: 28, action: #selector(chooseEmoji(_:)), in: emojiOptions)
            button.font = .systemFont(ofSize: 16)
            button.tag = index
            button.setButtonType(.pushOnPushOff)
        }
        for size in Annotation.Size.allCases {
            let button = makeButton(["小", "中", "大"][size.rawValue], symbol: "circle.fill", width: 26,
                                    symbolSize: [5, 9, 13][size.rawValue], action: #selector(chooseSize(_:)), in: sizeOptions)
            button.tag = size.rawValue
            button.setButtonType(.pushOnPushOff)
        }
        optionsRow.addArrangedSubview(colorOptions)
        optionsRow.addArrangedSubview(emojiOptions)
        optionsRow.addArrangedSubview(sizeOptions)
        optionsRow.spacing = 9
        toolbarStack.addArrangedSubview(mainRow)
        toolbarStack.addArrangedSubview(optionsRow)
        toolbar.addSubview(toolbarStack)
        addSubview(toolbar)
    }

    private func addDivider(to row: NSStackView) {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.21).cgColor
        row.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 17).isActive = true
    }

    private func makeButton(_ title: String, symbol: String? = nil, width: CGFloat = 30, symbolSize: CGFloat = 14,
                            action: Selector, in row: NSStackView) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            button.image = image.withSymbolConfiguration(.init(pointSize: symbolSize, weight: .medium))
            button.imagePosition = .imageOnly
        }
        button.isBordered = false
        button.setAccessibilityLabel(title)
        button.toolTip = title
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        row.addArrangedSubview(button)
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.heightAnchor.constraint(equalToConstant: 27).isActive = true
        return button
    }

    private func updateToolbar() {
        toolbar.isHidden = selection == nil
        undoButton?.isEnabled = !annotations.isEmpty
        redoButton?.isEnabled = !undoneAnnotations.isEmpty
        colorOptions.isHidden = !tool.usesColor
        emojiOptions.isHidden = tool != .emoji
        for button in toolButtons { highlight(button, selected: button.tag == tool.rawValue) }
        for case let button as NSButton in colorOptions.arrangedSubviews {
            highlight(button, selected: button.tag == colorIndex, tint: Self.palette[button.tag].1)
        }
        for case let button as NSButton in emojiOptions.arrangedSubviews {
            highlight(button, selected: button.tag == emojiIndex)
        }
        for case let button as NSButton in sizeOptions.arrangedSubviews {
            highlight(button, selected: button.tag == annotationSize.rawValue)
        }
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    private func highlight(_ button: NSButton, selected: Bool, tint: NSColor? = nil) {
        button.state = selected ? .on : .off
        button.contentTintColor = tint ?? (selected ? Self.selectionTint : .white)
        button.layer?.borderWidth = selected ? 1 : 0
        button.layer?.borderColor = Self.selectionTint.withAlphaComponent(0.62).cgColor
        let swatchBackground = tint == .black ? NSColor.white.withAlphaComponent(0.24) : .clear
        button.layer?.backgroundColor = (selected ? Self.selectionTint.withAlphaComponent(0.28) : swatchBackground).cgColor
    }

    @objc private func selectTool(_ button: NSButton) {
        finishText()
        if let selected = Tool(rawValue: button.tag) { tool = selected }
        window?.makeFirstResponder(self)
        updateToolbar()
    }

    @objc private func chooseColor(_ button: NSButton) {
        finishText()
        colorIndex = button.tag
        window?.makeFirstResponder(self)
        updateToolbar()
    }

    @objc private func chooseEmoji(_ button: NSButton) {
        emojiIndex = button.tag
        window?.makeFirstResponder(self)
        updateToolbar()
    }

    @objc private func chooseSize(_ button: NSButton) {
        finishText()
        if let size = Annotation.Size(rawValue: button.tag) { annotationSize = size }
        window?.makeFirstResponder(self)
        updateToolbar()
    }

    @objc private func undo() {
        finishText()
        if let annotation = annotations.popLast() { undoneAnnotations.append(annotation) }
        window?.makeFirstResponder(self)
        updateToolbar()
        needsDisplay = true
    }

    @objc private func redo() {
        finishText()
        if let annotation = undoneAnnotations.popLast() { annotations.append(annotation) }
        window?.makeFirstResponder(self)
        updateToolbar()
        needsDisplay = true
    }

    @objc private func reselect() {
        finishText(commit: false)
        selection = nil
        annotations.removeAll()
        undoneAnnotations.removeAll()
        window?.makeFirstResponder(self)
        updateToolbar()
        needsDisplay = true
    }

    @objc private func cancel() { onCancel?() }
    @objc private func save() { output(save: true) }
    @objc private func copyImage() { output(save: false) }

    private func startText(at point: CGPoint, within rect: CGRect) {
        let height = annotationSize.textFont.pointSize + 8
        let x = min(point.x, rect.maxX - min(72, rect.width))
        let y = max(rect.minY, min(point.y, rect.maxY - height))
        let width = min(220, rect.maxX - x)
        let field = NSTextField(frame: CGRect(x: x, y: y, width: width, height: height))
        field.placeholderString = "输入文字"
        field.font = annotationSize.textFont
        field.textColor = annotationColor
        field.backgroundColor = NSColor.black.withAlphaComponent(0.65)
        field.drawsBackground = true
        field.usesSingleLineMode = true
        field.delegate = self
        textField = field
        textOrigin = CGPoint(x: x + 2, y: y + 2)
        addSubview(field, positioned: .below, relativeTo: toolbar)
        window?.makeFirstResponder(field)
    }

    private func finishText(commit: Bool = true) {
        guard let field = textField, let origin = textOrigin else { return }
        let value = ((window?.firstResponder as? NSTextView)?.string ?? field.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        textField = nil
        textOrigin = nil
        window?.makeFirstResponder(self)
        field.removeFromSuperview()
        if commit, !value.isEmpty { append(makeAnnotation(.text(value, origin))) }
    }

    private func output(save: Bool) {
        guard let selection else { return }
        finishText()
        do {
            let image = try CaptureOutput.render(snapshot: snapshot, displaySize: bounds.size, selection: selection,
                                                 annotations: annotations, pixelation: pixelation)
            onOutput?(image, save)
        } catch { onError?(error) }
    }
}
