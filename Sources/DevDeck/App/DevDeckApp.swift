import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// DevDeck is an AppKit app: the menu bar item is a native `NSMenu` (so it gets the
/// system menu material and placement), and the dashboard is a SwiftUI window.
@main
enum DevDeckMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let peon = PeonStore()
    let devices = DeviceStore()
    let servers = ServerStore()
    let settings = AppSettings()

    private var statusMenu: StatusMenu?
    private lazy var dashboard = DashboardWindow { [unowned self] in
        AnyView(DashboardView().environmentObjects(peon, devices, servers, settings))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.mainMenu()
        statusMenu = StatusMenu(
            peon: peon, devices: devices, servers: servers, settings: settings,
            openDashboard: { [unowned self] page in dashboard.show(page) })
        handleLaunchArguments()
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        dashboard.show(nil)
        return false
    }

    /// `--open dashboard[:page]`, e.g. `open -a DevDeck --args --open dashboard:servers`.
    /// Handy for screenshots.
    private func handleLaunchArguments() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--open"), index + 1 < args.count else { return }
        let target = args[index + 1].split(separator: ":").map(String.init)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            if target.first == "dashboard" {
                dashboard.show(target.count > 1 ? DashboardPage(rawValue: target[1]) : nil)
            }
        }
    }

    /// The app has no visible menu bar of its own, but a main menu makes the
    /// standard shortcuts (⌘W, ⌘Q, ⌘C/⌘V in text) work in the dashboard.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        }
        func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
            NSMenuItem(title: title, action: action, keyEquivalent: key)
        }
        submenu("DevDeck", [item("Quit DevDeck", #selector(NSApplication.terminate(_:)), "q")])
        submenu("Edit", [
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        return main
    }
}

/// The dashboard window. AppKit owns it so the menu can open it at any time;
/// SwiftUI's title and toolbar are bridged into it.
@MainActor
final class DashboardWindow {
    private let content: () -> AnyView
    private var window: NSWindow?

    init(content: @escaping () -> AnyView) {
        self.content = content
    }

    func show(_ page: DashboardPage?) {
        if let page { UserDefaults.standard.set(page.rawValue, forKey: DashboardPage.storageKey) }
        let window = window ?? makeWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: content())
        controller.sceneBridgingOptions = [.title, .toolbars]
        controller.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.title = "DevDeck"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 860, height: 640))
        window.center()
        window.setFrameAutosaveName("DevDeckDashboard")
        self.window = window
        return window
    }
}

/// App-level settings that aren't peon-ping's.
@MainActor
final class AppSettings: ObservableObject {
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var lastError: String?
    @Published var menuBarIcon: MenuBarIcon {
        didSet { UserDefaults.standard.set(menuBarIcon.rawValue, forKey: "menuBarIcon") }
    }

    init() {
        menuBarIcon = UserDefaults.standard.string(forKey: "menuBarIcon").flatMap(MenuBarIcon.init) ?? .dashboard
    }

    func setLaunchAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            lastError = "Open at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

extension View {
    func environmentObjects(
        _ peon: PeonStore, _ devices: DeviceStore, _ servers: ServerStore, _ app: AppSettings
    ) -> some View {
        environmentObject(peon).environmentObject(devices).environmentObject(servers).environmentObject(app)
    }
}
