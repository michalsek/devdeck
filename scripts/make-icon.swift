// Renders the app icon (an SF Symbol on a rounded gradient tile) to a 1024 px PNG.
//   swift scripts/make-icon.swift <output.png>
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "icon.png"
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let tile = rect.insetBy(dx: size * 0.1, dy: size * 0.1)
    let path = NSBezierPath(roundedRect: tile, xRadius: size * 0.18, yRadius: size * 0.18)
    NSGradient(colors: [
        NSColor(red: 0.20, green: 0.24, blue: 0.33, alpha: 1),
        NSColor(red: 0.07, green: 0.09, blue: 0.14, alpha: 1),
    ])?.draw(in: path, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(red: 0.45, green: 0.86, blue: 0.55, alpha: 1)]))
    if let symbol = NSImage(systemSymbolName: "switch.2", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = symbol.size
        symbol.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
    }
    return true
}

guard let tiff = image.tiffRepresentation,
      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
else { fatalError("could not render icon") }
try png.write(to: URL(fileURLWithPath: output))
