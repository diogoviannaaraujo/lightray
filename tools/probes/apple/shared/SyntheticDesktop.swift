// Synthetic desktop frames shared by the Apple probes, so that the Mac and the iPad encode the
// same content: a wallpaper, a dark code editor, a light document window, a menu bar and a dock.
import CoreGraphics
import CoreText
import CoreVideo
import Foundation

struct ProbeRng {
    var s: UInt64
    mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 }
    mutating func unit() -> Double { Double(next() % 1_000_000) / 1_000_000.0 }
}

private let probeWords = ["func", "let", "var", "return", "struct", "import", "Lightray", "session", "packet", "frame",
                          "resume", "park", "encoder", "decoder", "latency", "if", "else", "guard", "while", "for",
                          "in", "0x7f", "self", "UInt32", "Double", "try", "await", "async", "stream", "keyframe",
                          "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "remote", "desktop"]

/// Draws a desktop into a 32BGRA pixel buffer. `variant` changes the text and window positions so
/// that two variants differ the way a screen changes over a few minutes.
func drawDesktop(into pb: CVPixelBuffer, variant: Int) {
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { fatalError("no CGContext") }
    let W = CGFloat(w), H = CGFloat(h)
    let scale = W / 1920.0
    let grad = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.10, green: 0.18, blue: 0.35, alpha: 1),
                                                   CGColor(red: 0.55, green: 0.30, blue: 0.45, alpha: 1)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: W, y: H), options: [])
    var rng = ProbeRng(s: 42)
    for _ in 0..<24 {
        ctx.setFillColor(CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 0.12))
        let r = CGFloat(80 + rng.unit() * 300) * scale
        ctx.fillEllipse(in: CGRect(x: CGFloat(rng.unit()) * W, y: CGFloat(rng.unit()) * H, width: r, height: r))
    }
    var trng = ProbeRng(s: UInt64(1000 + variant * 7919))
    func window(_ rect: CGRect, dark: Bool, font: String, size: CGFloat, lineGap: CGFloat) {
        ctx.setFillColor(dark ? CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1) : CGColor(red: 0.98, green: 0.98, blue: 0.97, alpha: 1))
        ctx.fill(rect)
        ctx.setFillColor(CGColor(red: 0.85, green: 0.85, blue: 0.86, alpha: 1))
        ctx.fill(CGRect(x: rect.minX, y: rect.maxY - 28 * scale, width: rect.width, height: 28 * scale))
        for (i, c) in [CGColor(red: 1, green: 0.37, blue: 0.34, alpha: 1), CGColor(red: 1, green: 0.74, blue: 0.18, alpha: 1),
                       CGColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1)].enumerated() {
            ctx.setFillColor(c)
            ctx.fillEllipse(in: CGRect(x: rect.minX + (10 + CGFloat(i) * 20) * scale, y: rect.maxY - 20 * scale, width: 12 * scale, height: 12 * scale))
        }
        let ctFont = CTFontCreateWithName(font as CFString, size * scale, nil)
        var y = rect.maxY - 28 * scale - (size + lineGap) * scale
        while y > rect.minY + 4 * scale {
            var line = String(repeating: "    ", count: Int(trng.next() % 4))
            for _ in 0..<(3 + Int(trng.next() % 9)) { line += probeWords[Int(trng.next() % UInt64(probeWords.count))] + " " }
            let color: CGColor = dark
                ? [CGColor(red: 0.8, green: 0.8, blue: 0.82, alpha: 1), CGColor(red: 0.99, green: 0.46, blue: 0.62, alpha: 1),
                   CGColor(red: 0.42, green: 0.75, blue: 0.99, alpha: 1), CGColor(red: 0.63, green: 0.9, blue: 0.5, alpha: 1)][Int(trng.next() % 4)]
                : CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
            let attrs = [kCTFontAttributeName: ctFont, kCTForegroundColorAttributeName: color] as CFDictionary
            let ctLine = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, line as CFString, attrs)!)
            ctx.textPosition = CGPoint(x: rect.minX + 12 * scale, y: y)
            ctx.saveGState()
            ctx.clip(to: rect)
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
            y -= (size + lineGap) * scale
        }
    }
    let dx = CGFloat(variant % 3) * 40 * scale, dy = CGFloat(variant % 2) * 30 * scale
    window(CGRect(x: 60 * scale + dx, y: 120 * scale + dy, width: 1000 * scale, height: 820 * scale), dark: true, font: "Menlo", size: 13, lineGap: 4)
    window(CGRect(x: 1000 * scale - dx, y: 200 * scale, width: 860 * scale, height: 700 * scale), dark: false, font: "Helvetica", size: 14, lineGap: 6)
    ctx.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.92, alpha: 0.85))
    ctx.fill(CGRect(x: 0, y: H - 30 * scale, width: W, height: 30 * scale))
    ctx.fill(CGRect(x: W * 0.25, y: 8 * scale, width: W * 0.5, height: 70 * scale))
    var irng = ProbeRng(s: 7)
    for i in 0..<16 {
        ctx.setFillColor(CGColor(red: irng.unit(), green: irng.unit(), blue: irng.unit(), alpha: 1))
        ctx.fill(CGRect(x: W * 0.25 + (12 + CGFloat(i) * 60) * scale, y: 16 * scale, width: 52 * scale, height: 52 * scale))
    }
}

/// An IOSurface-backed 32BGRA pixel buffer that CoreGraphics can draw into.
func makePixelBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                  kCVPixelBufferCGBitmapContextCompatibilityKey: true]
    let st = CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    precondition(st == kCVReturnSuccess, "CVPixelBufferCreate \(st)")
    return pb!
}
