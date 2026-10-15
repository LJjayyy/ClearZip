import AppKit

// Original ClearZip artwork: a folded Z ribbon, drawn only from geometric paths.
// Do not substitute SF Symbols or other system-provided images into this app icon.
func polygon(_ points: [(CGFloat, CGFloat)]) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: points[0].0, y: points[0].1))
    for point in points.dropFirst() { path.line(to: NSPoint(x: point.0, y: point.1)) }
    path.close()
    return path
}

func render(size: Int, to output: URL) throws {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    bitmap.bitmapData!.initialize(repeating: 0, count: bitmap.bytesPerRow * size)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(size) / 1024)
    transform.concat()

    let tile = NSBezierPath(
        roundedRect: NSRect(x: 96, y: 96, width: 832, height: 832),
        xRadius: 184, yRadius: 184
    )
    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    tileShadow.shadowBlurRadius = 20
    tileShadow.shadowOffset = NSSize(width: 0, height: -8)
    tileShadow.set()
    NSColor(white: 0.92, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(white: 0.995, alpha: 1),
               ending: NSColor(white: 0.86, alpha: 1))!.draw(in: tile, angle: -90)
    NSColor(white: 0.77, alpha: 1).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    let ribbon = polygon([
        (306, 718), (718, 718), (718, 610), (474, 408), (718, 408),
        (718, 300), (306, 300), (306, 408), (550, 610), (306, 610)
    ])
    NSGraphicsContext.saveGraphicsState()
    let ribbonShadow = NSShadow()
    ribbonShadow.shadowColor = NSColor(calibratedRed: 0.02, green: 0.19, blue: 0.16, alpha: 0.22)
    ribbonShadow.shadowBlurRadius = 14
    ribbonShadow.shadowOffset = NSSize(width: 0, height: -9)
    ribbonShadow.set()
    NSColor(calibratedRed: 0.05, green: 0.48, blue: 0.39, alpha: 1).setFill()
    ribbon.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.68, blue: 0.54, alpha: 1),
               ending: NSColor(calibratedRed: 0.02, green: 0.39, blue: 0.34, alpha: 1))!
        .draw(in: ribbon, angle: -90)

    NSColor(calibratedRed: 0.02, green: 0.33, blue: 0.29, alpha: 0.55).setFill()
    polygon([(718, 718), (718, 610), (550, 610)]).fill()
    NSColor(calibratedRed: 0.27, green: 0.79, blue: 0.63, alpha: 0.6).setFill()
    polygon([(306, 300), (306, 408), (474, 408)]).fill()

    if size >= 128 {
        NSColor.white.withAlphaComponent(0.45).setFill()
        NSBezierPath(rect: NSRect(x: 308, y: 714, width: 408, height: 3)).fill()
    }
    try bitmap.representation(using: .png, properties: [:])!.write(to: output)
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("用法：swift Scripts/make-icon.swift 输出.png或AppIcon.iconset\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
if output.pathExtension == "iconset" {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let suffix = scale == 2 ? "@2x" : ""
            let name = "icon_\(points)x\(points)\(suffix).png"
            try render(size: points * scale, to: output.appendingPathComponent(name))
        }
    }
} else {
    try render(size: 1024, to: output)
}
