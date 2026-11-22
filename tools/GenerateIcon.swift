import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func render(_ px: Int) -> CGImage {
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let factor = CGFloat(px) / 1024
    c.scaleBy(x: factor, y: factor)
    let tile = CGRect(x: 94, y: 94, width: 836, height: 836)
    let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -13), blur: 24, color: color(0x001C11, 0.35))
    c.setFillColor(color(0x122722))
    c.addPath(shape); c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(shape); c.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x25483C), color(0x101F1C), color(0x091513)] as CFArray,
                              locations: [0, 0.57, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 205, y: 930), end: CGPoint(x: 755, y: 94), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
    c.setStrokeColor(color(0xA7CFBC, 0.22)); c.setLineWidth(5)
    c.addPath(CGPath(roundedRect: tile.insetBy(dx: 3, dy: 3), cornerWidth: 183, cornerHeight: 183, transform: nil)); c.strokePath()

    let field = CGRect(x: 322, y: 342, width: 380, height: 340)
    c.setFillColor(color(0x51EAAF, 0.10))
    c.addPath(CGPath(roundedRect: field, cornerWidth: 28, cornerHeight: 28, transform: nil)); c.fillPath()
    c.setStrokeColor(color(0x87F0C5)); c.setLineWidth(44); c.setLineJoin(.round); c.setLineCap(.round)
    for (x,y,dx,dy) in [(280.0,300.0,1.0,1.0), (744,300,-1,1), (280,724,1,-1), (744,724,-1,-1)] {
        c.move(to: CGPoint(x: x, y: y + dy * 119))
        c.addLine(to: CGPoint(x: x, y: y))
        c.addLine(to: CGPoint(x: x + dx * 119, y: y))
        c.strokePath()
    }
    c.setFillColor(color(0xD1FFE8))
    c.fillEllipse(in: CGRect(x: 480, y: 480, width: 64, height: 64))
    return c.makeImage()!
}
func write(_ name: String, _ px: Int) {
    let url = output.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, render(px), nil)
    precondition(CGImageDestinationFinalize(destination))
}
for size in [16, 32, 128, 256, 512] {
    write("icon_\(size)x\(size).png", size)
    write("icon_\(size)x\(size)@2x.png", size * 2)
}
