// Renders the Equinox app icon (Resources/AppIcon.icns) and docs/images/icon.png.
// Usage: swift scripts/make-icon.swift
import AppKit

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: 824×824 squircle centred in 1024, with a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let bg = CGGradient(colorsSpace: space, colors: [
        NSColor(red: 0.10, green: 0.08, blue: 0.20, alpha: 1).cgColor,
        NSColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Spectrum bars behind the curve.
    let bars = 18
    for i in 0..<bars {
        let x = 170 + CGFloat(i) * 38
        let h = 120 + 210 * abs(sin(CGFloat(i) * 0.55 + 0.6)) * (1 - CGFloat(i) / CGFloat(bars) * 0.55)
        let bar = CGRect(x: x, y: 190, width: 24, height: h)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.setFillColor(NSColor(red: 0.55, green: 0.40, blue: 1.0, alpha: 0.22).cgColor)
        ctx.fillPath()
    }

    // EQ curve: bass lift, mid dip, presence bump.
    func y(_ t: CGFloat) -> CGFloat {
        560 + 105 * exp(-pow((t - 0.18) / 0.15, 2)) - 70 * exp(-pow((t - 0.5) / 0.14, 2)) + 85 * exp(-pow((t - 0.8) / 0.11, 2))
    }
    let curve = CGMutablePath()
    for i in 0...200 {
        let t = CGFloat(i) / 200
        let p = CGPoint(x: 170 + t * 684, y: y(t))
        i == 0 ? curve.move(to: p) : curve.addLine(to: p)
    }
    let cyan = NSColor(red: 0.25, green: 0.88, blue: 1.0, alpha: 1), violet = NSColor(red: 0.62, green: 0.38, blue: 1.0, alpha: 1)
    let stroke = CGGradient(colorsSpace: space, colors: [cyan.cgColor, violet.cgColor] as CFArray, locations: [0, 1])!
    for (width, alpha, blur) in [(34.0, 0.5, 46.0), (24.0, 1.0, 0.0)] {
        ctx.saveGState()
        if blur > 0 { ctx.setShadow(offset: .zero, blur: blur, color: cyan.withAlphaComponent(0.9).cgColor) }
        ctx.setAlpha(alpha)
        ctx.addPath(curve)
        ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.replacePathWithStrokedPath(); ctx.clip()
        ctx.drawLinearGradient(stroke, start: CGPoint(x: 150, y: 0), end: CGPoint(x: 874, y: 0), options: [])
        ctx.restoreGState()
    }
    // Band nodes.
    for (t, c) in [(0.16, cyan), (0.5, NSColor(red: 0.45, green: 0.6, blue: 1, alpha: 1)), (0.8, violet)] {
        let center = CGPoint(x: 170 + t * 684, y: y(t))
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 30, color: c.cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - 34, y: center.y - 34, width: 68, height: 68))
        ctx.restoreGState()
        ctx.setFillColor(c.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - 20, y: center.y - 20, width: 40, height: 40))
    }
    ctx.restoreGState()

    // Subtle rim light.
    ctx.addPath(shape); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor); ctx.setLineWidth(4); ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Equinox.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let images = root.appendingPathComponent("docs/images")
try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
try render(size: 512).representation(using: .png, properties: [:])!.write(to: images.appendingPathComponent("icon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns and docs/images/icon.png" : "iconutil failed")
