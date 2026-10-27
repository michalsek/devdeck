#if DEBUG
import AppKit
import SwiftUI

/// Debug aid: `DEVDECK_SNAPSHOT_DIR=/tmp/shots DevDeck` renders the menu panel and
/// each dashboard page to PNG files, then exits. Uses real AppKit controls, so it
/// shows what the user sees without needing screen-recording permission.
enum Snapshot {
    @MainActor static func runIfRequested(
        _ peon: PeonStore, _ devices: DeviceStore, _ servers: ServerStore, _ app: AppSettings
    ) {
        guard let dir = ProcessInfo.processInfo.environment["DEVDECK_SNAPSHOT_DIR"] else { return }
        // Give the first device and server scans time to finish.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            func render(_ view: some View, _ name: String, size: CGSize? = nil) {
                let host = NSHostingView(rootView: view.environmentObjects(peon, devices, servers, app))
                host.frame.size = size ?? host.fittingSize
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
            let page = CGSize(width: 1120, height: 560)
            render(MenuPanel(), "menu")
            for target in DashboardPage.allCases {
                UserDefaults.standard.set(target.rawValue, forKey: "dashboardPage")
                render(DashboardView(), "dashboard-\(target.rawValue)", size: page)
            }
            exit(0)
        }
    }
}
#endif
