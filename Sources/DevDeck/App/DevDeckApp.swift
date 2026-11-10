import AppKit
import Combine
import SwiftUI

/// DevDeck is an AppKit app: the menu bar item is a native `NSMenu` (so it gets the
/// system menu material and placement), and the dashboard is a SwiftUI window.
@main
enum DevDeckMain {
    static func main() {
        MainActor.assumeIsolated {
            // One DevDeck at a time: a second copy would take over the agents' socket.
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let running = others.first {
                running.activate()
                return
            }
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
    let stores = Stores()
    lazy var markers = MarkerController(leases: stores.leases, devices: stores.devices, settings: stores.settings)

    private var statusMenu: StatusMenu?
    private var pageItems: [DashboardPage: NSMenuItem] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private lazy var dashboard = DashboardWindow(pulse: stores.pulse) { [unowned self] in
        AnyView(DashboardView().environment(stores))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = mainMenu()
        stores.notifier.onOpen = { [unowned self] page in dashboard.show(page) }
        stores.peon.$installed.removeDuplicates()
            .sink { [unowned self] installed in updatePageItems(peonInstalled: installed) }
            .store(in: &subscriptions)
        statusMenu = StatusMenu(
            stores: stores, markers: markers, openDashboard: { [unowned self] page in dashboard.show(page) })
        handleLaunchArguments()
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        dashboard.show(nil)
        return false
    }

    /// `--open dashboard[:page]`, e.g. `open -a DevDeck --args --open dashboard:servers`.
    /// Handy for screenshots. `--hooks claude,codex` (or `--hooks none`) sets up the
    /// agent hooks without the dashboard.
    private func handleLaunchArguments() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--hooks"), index + 1 < args.count {
            let wanted = Set(args[index + 1].split(separator: ",").compactMap { AgentKind(rawValue: String($0)) })
            for agent in AgentKind.allCases where stores.hooks.isAvailable(agent) {
                stores.hooks.set(agent, enabled: wanted.contains(agent))
            }
        }
        guard let index = args.firstIndex(of: "--open"), index + 1 < args.count else { return }
        let target = args[index + 1].split(separator: ":").map(String.init)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            if target.first == "dashboard" {
                dashboard.show(target.count > 1 ? DashboardPage(rawValue: target[1]) : nil)
            }
        }
    }

    /// The menu bar shown while the dashboard is open (DevDeck is a regular app then).
    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
            return menu
        }
        func item(_ title: String, _ action: Selector, _ key: String = "",
                  _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }

        _ = submenu("DevDeck", [
            item("About DevDeck", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            ActionItem("Settings…", key: ",") { [unowned self] in dashboard.show(.general) },
            .separator(),
            item("Hide DevDeck", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit DevDeck", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        let pages = DashboardPage.allCases.map { page in
            ActionItem(page.title) { [unowned self] in dashboard.show(page) }
        }
        pageItems = Dictionary(uniqueKeysWithValues: zip(DashboardPage.allCases, pages))
        _ = submenu("View", pages + [
            .separator(),
            item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        NSApp.windowsMenu = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        return main
    }

    /// Hides the peon-ping pages without peon-ping, and numbers ⌘1, ⌘2… over the visible ones.
    private func updatePageItems(peonInstalled: Bool) {
        var number = 0
        for page in DashboardPage.allCases {
            guard let item = pageItems[page] else { continue }
            item.isHidden = page.needsPeon && !peonInstalled
            if item.isHidden {
                item.keyEquivalent = ""
            } else {
                number += 1
                item.keyEquivalent = "\(number)"
            }
        }
    }
}

/// The dashboard window. AppKit owns it so the menu can open it at any time;
/// SwiftUI's title and toolbar are bridged into it. While it's open DevDeck is a
/// regular app (Dock icon, menu bar, ⌘-Tab); closing it goes back to menu bar only.
@MainActor
final class DashboardWindow: NSObject, NSWindowDelegate {
    private let pulse: Pulse
    private let content: () -> AnyView
    private var window: NSWindow?

    init(pulse: Pulse, content: @escaping () -> AnyView) {
        self.pulse = pulse
        self.content = content
    }

    func show(_ page: DashboardPage?) {
        if let page { UserDefaults.standard.set(page.rawValue, forKey: DashboardPage.storageKey) }
        let window = window ?? makeWindow()
        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        // Deprecated, but the cooperative `activate()` gets declined when another app
        // is in front, which left the window behind other windows.
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        pulse.setViewing("dashboard", false)
    }

    /// On screen (not minimized, hidden or covered): the pages show live data.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        pulse.setViewing("dashboard", window?.occlusionState.contains(.visible) ?? false)
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
        window.delegate = self
        window.setContentSize(NSSize(width: 860, height: 640))
        window.center()
        window.setFrameAutosaveName("DevDeckDashboard")
        self.window = window
        return window
    }
}

/// Every store the app runs, made once at launch.
@MainActor
struct Stores {
    let pulse = Pulse()
    let peon = PeonStore()
    let devices = DeviceStore()
    let servers = ServerStore()
    let settings = AppSettings()
    let monitor = ResourceMonitor()
    let claims = ClaimStore()
    let notifier = Notifier()
    let hooks = HookInstaller()
    let activity = ActivityLog()
    let leases: LeaseStore
    let agents: AgentStore
    let keeper: MetroKeeper
    let broker: Broker
    let metroWatcher: MetroWatcher

    init() {
        if !Demo.isOn { notifier.setUp() }
        leases = LeaseStore(
            devices: devices, settings: settings, servers: servers, monitor: monitor, claims: claims, notifier: notifier,
            activity: activity)
        agents = AgentStore(
            devices: devices, servers: servers, monitor: monitor, notifier: notifier, activity: activity, leases: leases,
            claims: claims)
        keeper = MetroKeeper(servers: servers, activity: activity)
        broker = Broker(
            leases: leases, agents: agents, claims: claims, keeper: keeper, devices: devices, servers: servers,
            monitor: monitor, settings: settings, notifier: notifier, activity: activity, pulse: pulse)
        metroWatcher = MetroWatcher(
            devices: devices, servers: servers, leases: leases, notifier: notifier, activity: activity)
        guard !Demo.isOn else { return }
        pulse.hasWork = { [leases] in !leases.book.waiters.isEmpty }
        pulse.start([
            { [devices] in Task { await devices.refresh() } },
            { [servers] in Task { await servers.refresh() } },
            { [monitor] in Task { await monitor.refresh() } },
            claims.refresh,
            leases.tick,
            broker.reopenSocketIfStale,
            peon.reload,
        ])
    }
}

extension View {
    func environment(_ stores: Stores) -> some View {
        environmentObject(stores.peon).environmentObject(stores.devices).environmentObject(stores.servers)
            .environmentObject(stores.settings).environmentObject(stores.leases).environmentObject(stores.hooks)
            .environmentObject(stores.monitor).environmentObject(stores.claims).environmentObject(stores.activity)
            .environmentObject(stores.agents).environmentObject(stores.keeper).environmentObject(stores.broker)
    }
}
