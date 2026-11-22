import AppKit
import ScreenCaptureKit

enum CaptureFailure: LocalizedError {
    case displayUnavailable, imageConversion, clipboard

    var errorDescription: String? {
        switch self {
        case .displayUnavailable: return "找不到当前显示器，请重试。"
        case .imageConversion: return "无法生成图片，请重试。"
        case .clipboard: return "无法写入剪贴板，请重试。"
        }
    }
}

@MainActor
enum ScreenSnapshot {
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func capture(displayID: CGDirectDisplayID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureFailure.displayUnavailable
        }
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded()))
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

struct Annotation {
    enum Mark {
        case rectangle(CGRect), ellipse(CGRect), arrow(CGPoint, CGPoint)
        case brush([CGPoint]), mosaic([CGPoint])
        case text(String, CGPoint), emoji(String, CGPoint)
    }

    enum Size: Int, CaseIterable {
        case small, medium, large

        var lineWidth: CGFloat { [2, 3, 6][rawValue] }
        var mosaicWidth: CGFloat { [14, 24, 40][rawValue] }
        var textFont: NSFont { .systemFont(ofSize: [14, 18, 26][rawValue], weight: .semibold) }
        var emojiFont: NSFont { .systemFont(ofSize: [22, 30, 42][rawValue]) }
    }

    let mark: Mark
    let color: NSColor
    let size: Size

    var usesMosaic: Bool {
        if case .mosaic = mark { return true }
        return false
    }

    func draw(pixelation: CGImage?, displaySize: CGSize) {
        let path: NSBezierPath
        switch mark {
        case .rectangle(let rect): path = NSBezierPath(rect: rect)
        case .ellipse(let rect): path = NSBezierPath(ovalIn: rect)
        case .arrow(let start, let end):
            drawArrow(from: start, to: end)
            return
        case .brush(let points):
            color.setFill()
            brushOutline(points, width: size.lineWidth).fill()
            return
        case .mosaic(let points):
            guard let pixelation, let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            context.setShouldAntialias(false)
            brushOutline(points, width: size.mosaicWidth).addClip()
            context.translateBy(x: 0, y: displaySize.height)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .none
            context.draw(pixelation, in: CGRect(origin: .zero, size: displaySize))
            context.restoreGState()
            return
        case .text(let value, let point):
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
            shadow.shadowBlurRadius = 2
            value.draw(at: point, withAttributes: [.font: size.textFont, .foregroundColor: color, .shadow: shadow])
            return
        case .emoji(let value, let point):
            let attributes: [NSAttributedString.Key: Any] = [.font: size.emojiFont]
            let extent = value.size(withAttributes: attributes)
            value.draw(at: CGPoint(x: point.x - extent.width / 2, y: point.y - extent.height / 2),
                       withAttributes: attributes)
            return
        }
        color.setStroke()
        path.lineWidth = size.lineWidth
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return }
        let head = min(length, 8 + 3 * size.lineWidth)
        let x = dx / length
        let y = dy / length
        let base = CGPoint(x: end.x - x * head, y: end.y - y * head)
        let wing = head * 0.4
        let line = NSBezierPath()
        line.move(to: start)
        line.line(to: CGPoint(x: base.x + x * head / 4, y: base.y + y * head / 4))
        line.lineWidth = size.lineWidth
        line.lineCapStyle = .round
        color.setStroke()
        line.stroke()

        let tip = NSBezierPath()
        tip.move(to: end)
        tip.line(to: CGPoint(x: base.x + y * wing, y: base.y - x * wing))
        tip.line(to: CGPoint(x: base.x - y * wing, y: base.y + x * wing))
        tip.close()
        color.setFill()
        tip.fill()
    }

    private func brushOutline(_ points: [CGPoint], width: CGFloat) -> NSBezierPath {
        guard let start = points.first else { return NSBezierPath() }
        if points.count == 1 {
            return NSBezierPath(ovalIn: CGRect(x: start.x - width / 2, y: start.y - width / 2,
                                               width: width, height: width))
        }
        let path = CGMutablePath()
        path.move(to: start)
        for point in points.dropFirst() { path.addLine(to: point) }
        return NSBezierPath(cgPath: path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1))
    }
}

enum CaptureOutput {
    // Keep one small image anchored to the display so adjacent brush strokes share the same pixel grid.
    static func makePixelation(from snapshot: CGImage, displaySize: CGSize) throws -> CGImage {
        let width = max(1, Int((displaySize.width / 12).rounded(.up)))
        let height = max(1, Int((displaySize.height / 12).rounded(.up)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CaptureFailure.imageConversion
        }
        context.interpolationQuality = .high
        context.draw(snapshot, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw CaptureFailure.imageConversion }
        return image
    }

    // Selection and annotation coordinates are in display points, with the origin at the upper left.
    static func render(snapshot: CGImage, displaySize: CGSize, selection: CGRect,
                       annotations: [Annotation], pixelation: CGImage?) throws -> CGImage {
        guard displaySize.width > 0, displaySize.height > 0 else { throw CaptureFailure.imageConversion }
        let scaleX = CGFloat(snapshot.width) / displaySize.width
        let scaleY = CGFloat(snapshot.height) / displaySize.height
        let pixels = selection.applying(CGAffineTransform(scaleX: scaleX, y: scaleY)).integral
            .intersection(CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height))
        guard !pixels.isEmpty, let cropped = snapshot.cropping(to: pixels) else {
            throw CaptureFailure.imageConversion
        }
        if annotations.isEmpty { return cropped }
        let pixelation = annotations.contains(where: \.usesMosaic)
            ? try pixelation ?? makePixelation(from: snapshot, displaySize: displaySize) : nil

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: cropped.width, height: cropped.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureFailure.imageConversion
        }
        context.draw(cropped, in: CGRect(origin: .zero, size: pixels.size))
        context.translateBy(x: -pixels.minX, y: pixels.maxY)
        context.scaleBy(x: scaleX, y: -scaleY)
        context.clip(to: selection)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for annotation in annotations { annotation.draw(pixelation: pixelation, displaySize: displaySize) }
        NSGraphicsContext.restoreGraphicsState()
        guard let output = context.makeImage() else { throw CaptureFailure.imageConversion }
        return output
    }

    static func png(from image: CGImage) throws -> Data {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CaptureFailure.imageConversion
        }
        return png
    }

    @MainActor
    static func copy(_ image: CGImage, to pasteboard: NSPasteboard = .general) throws {
        let item = NSPasteboardItem()
        let png = try png(from: image)
        guard item.setData(png, forType: .png) else { throw CaptureFailure.clipboard }
        let bitmap = NSBitmapImageRep(cgImage: image)
        if let tiff = bitmap.tiffRepresentation(using: .lzw, factor: 0) {
            item.setData(tiff, forType: .tiff)
        }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.writeObjects([item]) else { throw CaptureFailure.clipboard }
    }

    static func save(_ png: Data, to url: URL) throws {
        try png.write(to: url, options: .atomic)
    }
}
