import AppKit

// Reproducible, code-drawn app artwork; no image downloads or build-time dependencies.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        let background = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 214, yRadius: 214)
        NSGradient(starting: NSColor(srgbRed: 0.025, green: 0.10, blue: 0.20, alpha: 1),
                   ending: NSColor(srgbRed: 0.02, green: 0.32, blue: 0.40, alpha: 1))!.draw(in: background, angle: 45)
        let beam = NSBezierPath()
        beam.move(to: NSPoint(x: 232, y: 232))
        beam.line(to: NSPoint(x: 390, y: 766))
        beam.line(to: NSPoint(x: 584, y: 766))
        beam.line(to: NSPoint(x: 481, y: 423))
        beam.line(to: NSPoint(x: 790, y: 423))
        beam.line(to: NSPoint(x: 732, y: 232))
        beam.close()
        NSGradient(starting: NSColor(srgbRed: 0.18, green: 0.86, blue: 0.90, alpha: 1),
                   ending: .white)!.draw(in: beam, angle: 65)
        let glint = NSBezierPath()
        glint.move(to: NSPoint(x: 646, y: 545))
        glint.line(to: NSPoint(x: 794, y: 816))
        glint.line(to: NSPoint(x: 743, y: 561))
        glint.close()
        NSColor(srgbRed: 0.41, green: 0.94, blue: 0.96, alpha: 1).setFill()
        glint.fill()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
