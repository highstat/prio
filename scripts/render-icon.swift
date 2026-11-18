// Renders Prio's app icon into an .iconset folder.
// Usage: render-icon <output.iconset>
// The geometry matches assets/icon.svg (1024 x 1024 canvas).
import AppKit

let teal = NSColor(srgbRed: 0x0D / 255.0, green: 0x94 / 255.0, blue: 0x88 / 255.0, alpha: 1)

func drawIcon(in ctx: CGContext) {
    // Canvas is 1024 x 1024, origin top-left (we flip below).
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)

    // Rounded-square body on the standard macOS icon grid.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.setFillColor(teal.cgColor)
    ctx.fillPath()

    // Three bars of decreasing length and strength: a ranked list.
    let bars: [(width: CGFloat, alpha: CGFloat)] = [(520, 1.0), (390, 0.82), (260, 0.64)]
    let height: CGFloat = 96
    let gap: CGFloat = 72
    var y: CGFloat = 296
    for bar in bars {
        let rect = CGRect(x: 252, y: y, width: bar.width, height: height)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        ctx.setFillColor(NSColor(white: 1, alpha: bar.alpha).cgColor)
        ctx.fillPath()
        y += height + gap
    }
}

func png(size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(in: ctx)
    gc.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: render-icon <output.iconset>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        guard let data = png(size: base * scale) else {
            FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
            exit(1)
        }
        try data.write(to: out.appendingPathComponent(name))
    }
}
