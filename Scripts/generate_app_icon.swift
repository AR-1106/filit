#!/usr/bin/env swift
import AppKit

let symbolName = "clipboard.fill"
let canvas = 1024
let fill = NSColor(srgbRed: 0.145, green: 0.275, blue: 0.365, alpha: 1) // ink
let cornerRatio: CGFloat = 0.223

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("No graphics context")
    }
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    ctx.shouldAntialias = true

    let rect = NSRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels))
    NSColor.clear.setFill()
    rect.fill()

    let radius = CGFloat(pixels) * cornerRatio
    let squircle = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
    fill.setFill()
    squircle.fill()

    let pointSize = CGFloat(pixels) * 0.48
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        fatalError("Missing SF Symbol \(symbolName)")
    }

    let symbolSize = symbol.size
    let origin = NSPoint(
        x: (CGFloat(pixels) - symbolSize.width) / 2,
        y: (CGFloat(pixels) - symbolSize.height) / 2 - CGFloat(pixels) * 0.01
    )
    symbol.draw(
        in: NSRect(origin: origin, size: symbolSize),
        from: .zero,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)]
    )

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encode failed")
    }
    try! data.write(to: url)
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Filit/Assets.xcassets/AppIcon.appiconset")
let docs = root.appendingPathComponent("docs")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

let master = drawIcon(pixels: 1024)
writePNG(master, to: docs.appendingPathComponent("icon.png"))

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]
for (name, px) in sizes {
    writePNG(drawIcon(pixels: px), to: iconset.appendingPathComponent(name))
    print("wrote \(name)")
}
