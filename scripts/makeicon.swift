import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: makeicon <output-iconset-dir>")
    exit(1)
}
let outDir = args[1]

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

func render(px: Int, to path: String) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0),
        let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        print("could not create bitmap context"); exit(1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let s = CGFloat(px)
    let inset = s * 0.05
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: s * 0.185, yRadius: s * 0.185)
    let top = NSColor(calibratedRed: 0.22, green: 0.36, blue: 0.86, alpha: 1)
    let bottom = NSColor(calibratedRed: 0.07, green: 0.12, blue: 0.35, alpha: 1)
    NSGradient(starting: top, ending: bottom)?.draw(in: shape, angle: -90)
    let str = NSAttributedString(string: "🔐", attributes: [.font: NSFont.systemFont(ofSize: s * 0.52)])
    let size = str.size()
    str.draw(at: NSPoint(x: (s - size.width) / 2, y: (s - size.height) / 2))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("could not encode png"); exit(1)
    }
    try! png.write(to: URL(fileURLWithPath: path))
}

for (name, px) in variants {
    render(px: px, to: "\(outDir)/\(name).png")
}
print("icon pngs written to \(outDir)")
