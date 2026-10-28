// Turns the macOS-style icon from scripts/make-icon.swift (tile inset 10% on a transparent
// canvas) into a full-bleed, opaque 1024 px iOS icon: crops to the tile and fills the
// rounded corners with the same gradient, so iOS's own mask gives the final shape.
//   swift helpers/ios/scripts/flatten-icon.swift <in.png> <out.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]) else {
    fatalError("usage: flatten-icon.swift <in.png> <out.png>")
}
let size = 1024
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fatalError("no context") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let rect = NSRect(x: 0, y: 0, width: size, height: size)
NSGradient(colors: [
    NSColor(red: 0.20, green: 0.24, blue: 0.33, alpha: 1),
    NSColor(red: 0.07, green: 0.09, blue: 0.14, alpha: 1),
])?.draw(in: rect, angle: -90)
// The tile spans the middle 80% of the source; scale it to fill the canvas.
let s = source.size.width
source.draw(in: rect, from: NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8),
            operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
guard let cg = ctx.makeImage(),
      let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
else { fatalError("png") }
try png.write(to: URL(fileURLWithPath: args[2]))
