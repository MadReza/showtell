// Draws Resources/AppIcon.icns: a waveform inside a camera viewfinder. The square is filled edge to
// edge with no transparency: macOS 26 rounds it itself, where an icon with transparent margins gets
// shrunk onto a light plate.
//   swift scripts/make-icon.swift
import AppKit

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let path = NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size))
    NSGradient(colors: [NSColor(red: 0.98, green: 0.45, blue: 0.27, alpha: 1),
                        NSColor(red: 0.85, green: 0.22, blue: 0.42, alpha: 1)])!.draw(in: path, angle: -60)
    NSColor.white.setStroke()
    NSColor.white.setFill()
    // Small sizes (lists such as Login Items, Spotlight) get fewer, thicker bars and no corners.
    let small = size <= 64
    // Viewfinder corners.
    let inset: CGFloat = 190 * s, len: CGFloat = 165 * s
    let lo = inset, hi = 1024 * s - inset
    let corners = NSBezierPath()
    corners.lineWidth = 56 * s
    corners.lineCapStyle = .round
    corners.lineJoinStyle = .round
    for (x, y, dx, dy) in [(lo, lo, 1.0, 1.0), (hi, lo, -1.0, 1.0), (lo, hi, 1.0, -1.0), (hi, hi, -1.0, -1.0)] {
        corners.move(to: NSPoint(x: x + dx * len, y: y))
        corners.line(to: NSPoint(x: x, y: y))
        corners.line(to: NSPoint(x: x, y: y + dy * len))
    }
    if !small { corners.stroke() }
    // Waveform bars.
    let heights: [CGFloat] = small ? [300, 620, 440, 220] : [150, 310, 460, 270, 390, 200]
    let bar: CGFloat = (small ? 130 : 66) * s, gap: CGFloat = (small ? 80 : 40) * s
    let total = CGFloat(heights.count) * bar + CGFloat(heights.count - 1) * gap
    var x = (1024 * s - total) / 2
    for h in heights {
        let r = NSRect(x: x, y: 512 * s - h * s / 2, width: bar, height: h * s)
        NSBezierPath(roundedRect: r, xRadius: bar / 2, yRadius: bar / 2).fill()
        x += bar + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(CGFloat(base * scale)).representation(using: .png, properties: [:])!
            .write(to: set.appendingPathComponent(name))
    }
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try! p.run()
p.waitUntilExit()
print("wrote \(out.path)")
