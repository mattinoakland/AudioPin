// make-icon.swift
// Draws the AudioPin app icon (a white pushpin on a blue-to-indigo rounded
// square, the macOS icon shape) at every size macOS wants and writes
// Resources/AppIcon.icns. Run with: swift scripts/make-icon.swift
//
// Re-run this if you change the look; the .icns is checked in so normal
// builds don't need it.

import AppKit

let outDir = "Resources"
let iconset = "\(outDir)/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let size = NSSize(width: pixels, height: pixels)
    let image = NSImage(size: size)
    image.lockFocus()

    let s = CGFloat(pixels)
    // macOS icons leave a transparent margin around the squircle.
    let inset = s * 0.08
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.height * 0.225)

    // Soft shadow under the tile.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Gradient tile.
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.62, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.22, green: 0.33, blue: 0.85, alpha: 1),
    ])!
    gradient.draw(in: path, angle: -90)

    // Pushpin symbol, white, centered, slightly tilted like a real pin.
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.52, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        NSColor.white.set()
        symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        tinted.unlockFocus()

        NSGraphicsContext.saveGraphicsState()
        let pinShadow = NSShadow()
        pinShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        pinShadow.shadowBlurRadius = s * 0.03
        pinShadow.shadowOffset = NSSize(width: 0, height: -s * 0.02)
        pinShadow.set()
        let transform = NSAffineTransform()
        transform.translateX(by: s / 2, yBy: s / 2)
        transform.rotate(byDegrees: -20)
        transform.concat()
        let drawRect = NSRect(x: -tinted.size.width / 2, y: -tinted.size.height / 2,
                              width: tinted.size.width, height: tinted.size.height)
        tinted.draw(in: drawRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    image.unlockFocus()
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// Name -> pixel size, as iconutil expects.
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    try! render(px).write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
try! render(256).write(to: URL(fileURLWithPath: "\(outDir)/AppIcon-preview.png"))

let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", iconset, "-o", "\(outDir)/AppIcon.icns"]
task.launch()
task.waitUntilExit()
try? FileManager.default.removeItem(atPath: iconset)
print(task.terminationStatus == 0 ? "Wrote \(outDir)/AppIcon.icns" : "iconutil failed")
