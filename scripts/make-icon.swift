// Renders the app icon (Tabler's filled layout-dashboard glyph on a rounded gradient tile) to a 1024 px PNG.
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

    // Same glyph as the default menu bar icon (Tabler Icons, MIT).
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="#73DB8C"><path d="M9 3a2 2 0 0 1 2 2v6a2 2 0 0 1 -2 2h-4a2 2 0 0 1 -2 -2v-6a2 2 0 0 1 2 -2zm0 12a2 2 0 0 1 2 2v2a2 2 0 0 1 -2 2h-4a2 2 0 0 1 -2 -2v-2a2 2 0 0 1 2 -2zm10 -4a2 2 0 0 1 2 2v6a2 2 0 0 1 -2 2h-4a2 2 0 0 1 -2 -2v-6a2 2 0 0 1 2 -2zm0 -8a2 2 0 0 1 2 2v2a2 2 0 0 1 -2 2h-4a2 2 0 0 1 -2 -2v-2a2 2 0 0 1 2 -2z"/></svg>
    """
    if let glyph = NSImage(data: Data(svg.utf8)) {
        let side = size * 0.5
        glyph.draw(in: NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
    }
    return true
}

guard let tiff = image.tiffRepresentation,
      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
else { fatalError("could not render icon") }
try png.write(to: URL(fileURLWithPath: output))
