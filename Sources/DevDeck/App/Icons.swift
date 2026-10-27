import AppKit

/// Menu bar icon choices: filled icons from Tabler Icons (MIT, https://tabler.io/icons).
/// macOS draws SVG natively, so the path data is embedded as-is.
enum MenuBarIcon: String, CaseIterable, Identifiable {
    case dashboard, stack, cards, gauge, apps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .stack: "Stack"
        case .cards: "Cards"
        case .gauge: "Gauge"
        case .apps: "Apps"
        }
    }

    var paths: [String] {
        switch self {
        case .dashboard:
            ["M9 3a2 2 0 0 1 2 2v6a2 2 0 0 1 -2 2h-4a2 2 0 0 1 -2 -2v-6a2 2 0 0 1 2 -2zm0 12a2 2 0 0 1 2 2v2a2 2 0 0 1 -2 2h-4a2 2 0 0 1 -2 -2v-2a2 2 0 0 1 2 -2zm10 -4a2 2 0 0 1 2 2v6a2 2 0 0 1 -2 2h-4a2 2 0 0 1 -2 -2v-6a2 2 0 0 1 2 -2zm0 -8a2 2 0 0 1 2 2v2a2 2 0 0 1 -2 2h-4a2 2 0 0 1 -2 -2v-2a2 2 0 0 1 2 -2z"]
        case .stack:
            ["M20.894 15.553a1 1 0 0 1 -.447 1.341l-8 4a1 1 0 0 1 -.894 0l-8 -4a1 1 0 0 1 .894 -1.788l7.553 3.774l7.554 -3.775a1 1 0 0 1 1.341 .447m0 -4a1 1 0 0 1 -.447 1.341l-8 4a1 1 0 0 1 -.894 0l-8 -4a1 1 0 0 1 .894 -1.788l7.552 3.775l7.554 -3.775a1 1 0 0 1 1.341 .447m-8.887 -8.552q .056 0 .111 .007l.111 .02l.086 .024l.012 .006l.012 .002l.029 .014l.05 .019l.016 .009l.012 .005l8 4a1 1 0 0 1 0 1.788l-8 4a1 1 0 0 1 -.894 0l-8 -4a1 1 0 0 1 0 -1.788l8 -4l.011 -.005l.018 -.01l.078 -.032l.011 -.002l.013 -.006l.086 -.024l.11 -.02l.056 -.005z"]
        case .cards:
            ["M10.348 3.169l-7.15 3.113a2 2 0 0 0 -1.03 2.608l4.92 11.895a1.96 1.96 0 0 0 2.59 1.063l7.142 -3.11a2.002 2.002 0 0 0 1.036 -2.611l-4.92 -11.894a1.96 1.96 0 0 0 -2.588 -1.064z",
             "M16 3a2 2 0 0 1 1.995 1.85l.005 .15v3.5a1 1 0 0 1 -1.993 .117l-.007 -.117v-3.5h-1a1 1 0 0 1 -.117 -1.993l.117 -.007h1z",
             "M19.08 5.61a1 1 0 0 1 1.31 -.53c.257 .108 .505 .21 .769 .314a2 2 0 0 1 1.114 2.479l-.056 .146l-2.298 5.374a1 1 0 0 1 -1.878 -.676l.04 -.11l2.296 -5.371l-.366 -.148l-.402 -.167a1 1 0 0 1 -.53 -1.312z"]
        case .gauge:
            ["M12 2.954a10 10 0 0 1 6.222 17.829a1 1 0 0 1 -.622 .217h-11.2a1 1 0 0 1 -.622 -.217a10 10 0 0 1 6.222 -17.829m4.207 5.839a1 1 0 0 0 -1.414 0l-2.276 2.274a2.003 2.003 0 0 0 -2.514 1.815l-.003 .118a2 2 0 1 0 3.933 -.517l2.274 -2.276a1 1 0 0 0 0 -1.414"]
        case .apps:
            ["M9 3h-4a2 2 0 0 0 -2 2v4a2 2 0 0 0 2 2h4a2 2 0 0 0 2 -2v-4a2 2 0 0 0 -2 -2z",
             "M9 13h-4a2 2 0 0 0 -2 2v4a2 2 0 0 0 2 2h4a2 2 0 0 0 2 -2v-4a2 2 0 0 0 -2 -2z",
             "M19 13h-4a2 2 0 0 0 -2 2v4a2 2 0 0 0 2 2h4a2 2 0 0 0 2 -2v-4a2 2 0 0 0 -2 -2z",
             "M17 3a1 1 0 0 1 .993 .883l.007 .117v2h2a1 1 0 0 1 .117 1.993l-.117 .007h-2v2a1 1 0 0 1 -1.993 .117l-.007 -.117v-2h-2a1 1 0 0 1 -.117 -1.993l.117 -.007h2v-2a1 1 0 0 1 1 -1z"]
        }
    }

    /// A template image, so the menu bar tints it for light and dark menu bars.
    func image(size: CGFloat = 16) -> NSImage {
        let body = paths.map { "<path d=\"\($0)\"/>" }.joined()
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\" viewBox=\"0 0 24 24\" fill=\"black\">\(body)</svg>"
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        image.accessibilityDescription = "DevDeck"
        return image
    }
}

extension NSImage {
    /// The coloured status dot shown next to devices and servers in the menu.
    static func statusDot(_ color: NSColor, diameter: CGFloat = 8) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
