import AppKit

// Shapes a full-bleed square PNG into macOS rounded-squircle app-icon sizes.
// usage: IconGen <source.png> <outDir>
func render(_ px: Int, _ src: NSImage) -> Data {
    let size = CGFloat(px)
    let margin = size * 0.04
    let body = size - 2 * margin
    let radius = body * 0.2237
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    let old = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bodyRect = NSRect(x: margin, y: margin, width: body, height: body)
    NSBezierPath(roundedRect: bodyRect, xRadius: radius, yRadius: radius).addClip()
    src.draw(in: bodyRect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.current = old
    return rep.representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
guard args.count >= 3, let src = NSImage(contentsOfFile: args[1]) else {
    FanErr: do {}; fatalError("usage: IconGen <src.png> <outDir>")
}
let outDir = args[2]
for px in [16, 32, 64, 128, 256, 512, 1024] {
    let data = render(px, src)
    try! data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("icon_\(px).png"))
    print("wrote icon_\(px).png")
}
