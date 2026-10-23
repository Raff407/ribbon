// Draws Ribbon's app icon and writes Resources/AppIcon.icns.
//   swiftc Scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon
// The icon: a strip of window columns on a blue squircle. The focused column is solid
// white; its neighbours fade towards the edges, the way the strip scrolls off-screen.
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let s = size / 1024
        // Apple's icon grid: an 824pt rounded square centred on the 1024pt canvas.
        let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 24 * s
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.set()
        NSColor(srgbRed: 0.13, green: 0.23, blue: 0.55, alpha: 1).setFill()
        tilePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(colors: [
            NSColor(srgbRed: 0.24, green: 0.55, blue: 1.0, alpha: 1),
            NSColor(srgbRed: 0.33, green: 0.24, blue: 0.86, alpha: 1),
        ])?.draw(in: tilePath, angle: -60)

        tilePath.setClip()
        let top = 290 * s, height = 444 * s, width = 236 * s, gap = 34 * s, radius = 34 * s
        let centreX = 512 * s - width / 2
        let columns: [(x: CGFloat, alpha: CGFloat)] = [
            (centreX - 2 * (width + gap), 0.22), (centreX - (width + gap), 0.5),
            (centreX, 1.0),
            (centreX + (width + gap), 0.5), (centreX + 2 * (width + gap), 0.22),
        ]
        for column in columns {
            let rect = CGRect(x: column.x, y: top, width: width, height: height)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSColor.white.withAlphaComponent(column.alpha).setFill()
            path.fill()
            // Title bar strip on each window.
            let bar = CGRect(x: rect.minX, y: rect.maxY - 58 * s, width: rect.width, height: 58 * s)
            let barPath = NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius)
            barPath.append(NSBezierPath(rect: CGRect(x: bar.minX, y: bar.minY, width: bar.width, height: bar.height / 2)))
            NSColor(srgbRed: 0.13, green: 0.2, blue: 0.45, alpha: 0.18 * column.alpha).setFill()
            barPath.fill()
        }
        // The strip indicator: a track with the visible part highlighted.
        let track = CGRect(x: 262 * s, y: 196 * s, width: 500 * s, height: 22 * s)
        NSColor.white.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: track, xRadius: 11 * s, yRadius: 11 * s).fill()
        let thumb = CGRect(x: 412 * s, y: 196 * s, width: 200 * s, height: 22 * s)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 11 * s, yRadius: 11 * s).fill()
        return true
    }
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try png(drawIcon(size: CGFloat(pixels)), pixels: pixels).write(to: iconset.appendingPathComponent(name))
    }
}
try png(drawIcon(size: 1024), pixels: 1024).write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
