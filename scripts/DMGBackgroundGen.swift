import AppKit
import Foundation

// Renders the Tscribe installer (.dmg) window background: charcoal with a teal
// glow behind the app icon, the "Tscribe" wordmark + tagline, a teal arrow, and
// a drag instruction. Icon positions here must match the AppleScript layout in
// scripts/package.sh (app icon centered at 170,200; Applications at 470,200).
//
// Usage: swiftc -O DMGBackgroundGen.swift -o dmgbg && ./dmgbg <outdir>
//   writes background.png (1x, 640x400) and background@2x.png (2x, 1280x800);
//   scripts/package.sh combines them into a HiDPI background.tiff via tiffutil.

let W: CGFloat = 640, H: CGFloat = 400

// Layout (top-left origin, to match Finder icon coordinates).
let appIconCenter = CGPoint(x: 170, y: 200)
let appsIconCenter = CGPoint(x: 470, y: 200)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// Convert a top-left Y into the bottom-left space AppKit draws in.
func flipY(_ topY: CGFloat) -> CGFloat { H - topY }

func drawText(_ s: String, size: CGFloat, weight: NSFont.Weight,
              color: NSColor, topLeftY: CGFloat, x: CGFloat = 48,
              centered: Bool = false, tracking: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .kern: tracking,
    ]
    let str = NSAttributedString(string: s, attributes: attrs)
    let sz = str.size()
    let drawX = centered ? (W - sz.width) / 2 : x
    // draw(at:) in a non-flipped context places text upright with the point as
    // its lower-left; convert the desired top-left Y accordingly.
    str.draw(at: NSPoint(x: drawX, y: flipY(topLeftY) - sz.height))
}

func drawBackground() {
    // Vertical charcoal gradient.
    NSGradient(colors: [rgb(0.13, 0.15, 0.18), rgb(0.07, 0.08, 0.10)])!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    // Teal glow behind the app icon.
    let center = NSPoint(x: appIconCenter.x, y: flipY(appIconCenter.y))
    NSGradient(colors: [rgb(0.16, 0.73, 0.76, 0.42), rgb(0.16, 0.73, 0.76, 0.0)])!
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: 205, options: [])

    // Wordmark + tagline (top-left, like the Firefox installer).
    drawText("Tscribe", size: 46, weight: .semibold, color: rgb(0.95, 0.97, 0.98),
             topLeftY: 42, x: 48, tracking: 0.5)
    drawText("Private, on-device transcription", size: 15, weight: .regular,
             color: rgb(0.60, 0.66, 0.72), topLeftY: 104, x: 50)

    // Teal arrow from the app icon toward Applications.
    let ay = flipY(200)
    let shaftL: CGFloat = 262, shaftR: CGFloat = 360, tip: CGFloat = 396
    let th: CGFloat = 7, hh: CGFloat = 19
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: shaftL, y: ay - th))
    arrow.line(to: NSPoint(x: shaftR, y: ay - th))
    arrow.line(to: NSPoint(x: shaftR, y: ay - hh))
    arrow.line(to: NSPoint(x: tip, y: ay))
    arrow.line(to: NSPoint(x: shaftR, y: ay + hh))
    arrow.line(to: NSPoint(x: shaftR, y: ay + th))
    arrow.line(to: NSPoint(x: shaftL, y: ay + th))
    arrow.close()
    rgb(0.17, 0.72, 0.79).setFill()
    arrow.fill()

    // Drag instruction, centered near the bottom.
    drawText("Drag Tscribe into Applications", size: 13, weight: .medium,
             color: rgb(0.58, 0.64, 0.70), topLeftY: 338, centered: true, tracking: 0.3)
}

func makeImage(scale: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(W) * scale, pixelsHigh: Int(H) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)   // draw in points; render at `scale`x pixels
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawBackground()
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try! makeImage(scale: 1).write(to: URL(fileURLWithPath: "\(outDir)/background.png"))
try! makeImage(scale: 2).write(to: URL(fileURLWithPath: "\(outDir)/background@2x.png"))
print("wrote background.png + background@2x.png to \(outDir)")
