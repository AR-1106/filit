#!/usr/bin/env swift
import AppKit

let symbolName = "clipboard"
let fill = NSColor.black
let cornerRatio: CGFloat = 0.223

func makeRep(pixels: Int) -> NSBitmapImageRep {
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
    return rep
}

func withContext(_ rep: NSBitmapImageRep, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("No graphics context") }
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    ctx.shouldAntialias = true
    body()
    NSGraphicsContext.restoreGraphicsState()
}

func renderSymbol(pixels: Int) -> NSBitmapImageRep {
    let pointSize = CGFloat(pixels) * 0.72
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        fatalError("Missing SF Symbol \(symbolName)")
    }
    let rep = makeRep(pixels: pixels)
    withContext(rep) {
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
        let size = symbol.size
        let origin = NSPoint(
            x: (CGFloat(pixels) - size.width) / 2,
            y: (CGFloat(pixels) - size.height) / 2
        )
        symbol.draw(
            in: NSRect(origin: origin, size: size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)]
        )
    }
    return rep
}

func opaqueBounds(_ rep: NSBitmapImageRep) -> NSRect {
    let w = rep.pixelsWide
    let h = rep.pixelsHigh
    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in 0..<h {
        for x in 0..<w {
            var pixel = [Int](repeating: 0, count: 4)
            rep.getPixel(&pixel, atX: x, y: y)
            guard pixel[3] > 24 else { continue }
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }
    if maxX < minX { return NSRect(x: 0, y: 0, width: w, height: h) }
    return NSRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let symbolRep = renderSymbol(pixels: pixels * 2)
    let bounds = opaqueBounds(symbolRep)
    let target = CGFloat(pixels) * 0.54
    let scale = min(target / bounds.width, target / bounds.height)
    let drawSize = NSSize(width: bounds.width * scale, height: bounds.height * scale)
    let origin = NSPoint(
        x: (CGFloat(pixels) - drawSize.width) / 2,
        y: (CGFloat(pixels) - drawSize.height) / 2
    )

    let rep = makeRep(pixels: pixels)
    withContext(rep) {
        let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        NSColor.clear.setFill()
        rect.fill()

        let radius = CGFloat(pixels) * cornerRatio
        let squircle = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
        fill.setFill()
        squircle.fill()

        guard let cg = symbolRep.cgImage else { return }
        let cropped = cg.cropping(to: CGRect(
            x: bounds.origin.x,
            y: bounds.origin.y,
            width: bounds.width,
            height: bounds.height
        ))
        if let cropped {
            let image = NSImage(cgImage: cropped, size: drawSize)
            image.draw(
                in: NSRect(origin: origin, size: drawSize),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)]
            )
        }
    }
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encode failed")
    }
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath)
let catalog = root.appendingPathComponent("Filit/Assets.xcassets/AppIcon.appiconset")
let iconset = root.appendingPathComponent("build/Filit.iconset")
let docs = root.appendingPathComponent("docs")
let resources = root.appendingPathComponent("Filit/Resources")
try! FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

writePNG(drawIcon(pixels: 1024), to: docs.appendingPathComponent("app-icon.png"))

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
    let image = drawIcon(pixels: px)
    writePNG(image, to: catalog.appendingPathComponent(name))
    writePNG(image, to: iconset.appendingPathComponent(name))
    print("wrote \(name)")
}

let icns = resources.appendingPathComponent("AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(icns.path)")
