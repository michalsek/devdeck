import AppKit
import Combine
import SwiftUI

/// The menu bar item and its menu. A native `NSMenu`, rebuilt each time it opens;
/// the volume sliders are SwiftUI views hosted in menu items.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let peon: PeonStore
    private let devices: DeviceStore
    private let servers: ServerStore
    private let settings: AppSettings
    private let leases: LeaseStore
    private let hooks: HookInstaller
    private let markers: MarkerController
    private let openDashboard: (DashboardPage?) -> Void
    private var subscriptions = Set<AnyCancellable>()

    init(
        peon: PeonStore, devices: DeviceStore, servers: ServerStore, settings: AppSettings,
        leases: LeaseStore, hooks: HookInstaller, markers: MarkerController,
        openDashboard: @escaping (DashboardPage?) -> Void
    ) {
        self.peon = peon
        self.devices = devices
        self.servers = servers
        self.settings = settings
        self.leases = leases
        self.hooks = hooks
        self.markers = markers
        self.openDashboard = openDashboard
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        menu.minimumWidth = 300
        item.menu = menu
        item.button?.imagePosition = .imageLeading

        Publishers.CombineLatest4(peon.$paused, servers.$servers, settings.$menuBarIcon, leases.$book)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paused, servers, icon, book in
                self?.updateButton(
                    paused: paused, count: servers.filter { $0.group == .devServer }.count, icon: icon,
                    driven: book.leases.values.filter { !$0.isUser }.count,
                    held: book.leases.values.filter(\.isUser).count, waiting: book.waiters.count)
            }
            .store(in: &subscriptions)
    }

    private func updateButton(paused: Bool, count: Int, icon: MenuBarIcon, driven: Int, held: Int, waiting: Int) {
        guard let button = item.button else { return }
        button.image = icon.image()
        button.title = count > 0 ? "\(count)" : ""
        // Muted: the icon dims, like a menu extra that's switched off.
        button.appearsDisabled = paused
        let summary = "\(count) dev server\(count == 1 ? "" : "s") running"
            + (driven > 0 ? ", \(driven) device\(driven == 1 ? "" : "s") driven by agents" : "")
            + (held > 0 ? ", \(held) held by you" : "")
            + (waiting > 0 ? ", \(waiting) agent call\(waiting == 1 ? "" : "s") waiting" : "")
            + (paused ? ", sounds muted" : "")
        button.toolTip = "DevDeck: " + summary
        button.setAccessibilityLabel("DevDeck, " + summary)
    }

    // MARK: Building the menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if peon.installed {
            addSounds()
            menu.addItem(.separator())
        }
        addDevices()
        menu.addItem(.separator())
        addServers()
        menu.addItem(.separator())
        for error in [devices.lastError, servers.lastError, peon.lastError, settings.lastError, hooks.lastError].compactMap({ $0 }) {
            let item = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            item.attributedTitle = NSAttributedString(string: error, attributes: [.foregroundColor: NSColor.systemRed])
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(ActionItem("Open Dashboard…", key: ",") { [weak self] in self?.openDashboard(nil) })
        menu.addItem(ActionItem("Quit DevDeck", key: "q") { NSApp.terminate(nil) })
    }

    private func addSounds() {
        menu.addItem(.sectionHeader(title: "Agent Sounds"))
        let mute = ActionItem("Mute All Sounds") { [peon] in peon.setPaused(!peon.paused) }
        mute.state = peon.paused ? .on : .off
        menu.addItem(mute)
        menu.addItem(hosted(MenuVolumeRow()))

        let pack = NSMenuItem(title: "Voice Pack", action: nil, keyEquivalent: "")
        pack.subtitle = peon.activePack?.displayName
        let packs = NSMenu()
        for option in peon.packs {
            let item = ActionItem(option.displayName) { [peon] in peon.usePack(option.id) }
            item.state = option.id == peon.defaultPack ? .on : .off
            packs.addItem(item)
        }
        if peon.packs.isEmpty { packs.addItem(disabled("No packs installed")) }
        packs.addItem(.separator())
        packs.addItem(ActionItem("Manage Voice Packs…") { [weak self] in self?.openDashboard(.packs) })
        pack.submenu = packs
        menu.addItem(pack)

        let categories = NSMenuItem(title: "Per-Sound Volume", action: nil, keyEquivalent: "")
        let list = NSMenu()
        list.addItem(hosted(MenuCategoryList(), width: 360))
        categories.submenu = list
        menu.addItem(categories)
    }

    private func addDevices() {
        menu.addItem(.sectionHeader(title: "Devices"))
        let running = devices.running
        if running.isEmpty { menu.addItem(disabled(devices.loaded ? "No devices running" : "Loading…")) }
        for device in running {
            let row = NSMenuItem(title: device.name, action: nil, keyEquivalent: "")
            row.subtitle = [device.detail, device.connection].compactMap { $0 }.filter { !$0.isEmpty }
                .joined(separator: " · ")
            row.image = .statusDot(.systemGreen)
            let actions = NSMenu()
            addLease(of: device, to: actions, row: row)
            if device.canStop {
                actions.addItem(devices.busy.contains(device.id)
                    ? disabled("Shutting Down…")
                    : ActionItem(device.stopLabel) { [devices] in devices.stop(device) })
                actions.addItem(.separator())
            }
            if device.kind == .simulator, settings.deviceMarkers, MarkerController.companionApp != nil {
                // Starting the Live Activity brings the companion to the front for a moment.
                let start = ActionItem("Start Device Marker") { [markers] in markers.startMarker(on: device) }
                start.subtitle = "Briefly opens the DevDeck app on the simulator"
                actions.addItem(start)
            }
            actions.addItem(ActionItem("Copy ID") { Pasteboard.copy(device.serial ?? device.id) })
            row.submenu = actions
            menu.addItem(row)
        }

        // Booting from the menu: shut-down simulators and stopped emulators.
        let startable = devices.devices.filter(\.canStart)
        if !startable.isEmpty {
            let start = NSMenuItem(title: "Start a Device", action: nil, keyEquivalent: "")
            let list = NSMenu()
            for (title, kind) in [("iOS Simulators", DeviceItem.Kind.simulator), ("Android Emulators", .emulator)] {
                let group = startable.filter { $0.kind == kind }
                guard !group.isEmpty else { continue }
                list.addItem(.sectionHeader(title: title))
                for device in group {
                    let item = ActionItem(device.name) { [devices] in devices.start(device) }
                    item.subtitle = device.detail.isEmpty ? nil : device.detail
                    item.isEnabled = !devices.busy.contains(device.id)
                    list.addItem(item)
                }
            }
            start.submenu = list
            menu.addItem(start)
        }
    }

    private func addServers() {
        menu.addItem(.sectionHeader(title: "Dev Servers"))
        let running = servers.devServers
        if running.isEmpty { menu.addItem(disabled(servers.loaded ? "No dev servers running" : "Loading…")) }
        for server in running {
            let row = NSMenuItem(title: server.project.name, action: nil, keyEquivalent: "")
            row.subtitle = server.summary
            row.image = .statusDot(server.tone == .attention ? .systemOrange : .systemGreen)
            let actions = NSMenu()
            actions.autoenablesItems = false
            if server.metro != nil {
                let reload = ActionItem("Reload Apps") { [servers] in servers.reloadApps(server) }
                reload.subtitle = server.canReloadApps ? "Like pressing r in Metro" : "No app connected"
                reload.isEnabled = server.canReloadApps
                actions.addItem(reload)
                actions.addItem(.separator())
            }
            if server.url != nil {
                actions.addItem(ActionItem("Open in Browser") { [servers] in servers.open(server) })
            }
            if server.cwd != nil {
                actions.addItem(ActionItem("Reveal in Finder") { [servers] in servers.reveal(server) })
                actions.addItem(ActionItem("Open in Terminal") { [servers] in servers.openTerminal(server) })
            }
            actions.addItem(ActionItem("Copy Command") { Pasteboard.copy(server.command) })
            actions.addItem(.separator())
            actions.addItem(servers.stopping.contains(server.pid)
                ? disabled("Stopping…")
                : ActionItem("Stop Server") { [servers] in servers.stop(server) })
            row.submenu = actions
            menu.addItem(row)
        }
    }

    /// Who holds the device, and the hold / take over / queue / release actions.
    private func addLease(of device: DeviceItem, to actions: NSMenu, row: NSMenuItem) {
        let queued = leases.isQueued(for: device)
        switch leases.lease(for: device)?.holder {
        case .agent(let session):
            let lease = leases.lease(for: device)!
            // Driven by an agent: say who, so the device is left alone.
            row.subtitle = "\(session.agent.title) · \(Format.age(since: lease.lastAction)) ago · \(session.project.name)"
                + (queued ? " · you're next" : "")
            row.image = .statusDot(.systemPurple)
            let driver = disabled("Driven by \(session.agentDescription)")
            driver.subtitle = [session.project.name, session.project.subtitle, lease.lastActionName]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            actions.addItem(driver)
            let takeOver = ActionItem("Take Over Now") { [leases] in leases.hold(device) }
            takeOver.subtitle = "The agent waits until you release it"
            actions.addItem(takeOver)
            if queued {
                actions.addItem(ActionItem("Leave Queue") { [leases] in leases.leaveQueue(device) })
            } else {
                let join = ActionItem("Join Queue") { [leases] in leases.joinQueue(device) }
                join.subtitle = "Yours when the agent is done with it"
                actions.addItem(join)
            }
            actions.addItem(ActionItem("Forget This Agent") { [leases] in leases.forget(device) })
        case .user:
            let waiting = leases.waiters(for: device)
            row.subtitle = "Held by you" + (waiting.isEmpty ? "" : " · \(waiting.count) agent call\(waiting.count == 1 ? "" : "s") waiting")
            row.image = .statusDot(.systemBlue)
            let header = disabled("Held by You")
            header.subtitle = "Agents wait until you release it"
            actions.addItem(header)
            for waiter in waiting {
                let item = disabled("Waiting: \(waiter.session.label)")
                item.subtitle = "\(waiter.action) · \(Format.age(since: waiter.since))"
                actions.addItem(item)
            }
            actions.addItem(ActionItem("Release") { [leases] in leases.release(device) })
        case nil:
            let hold = ActionItem("Hold Device") { [leases] in leases.hold(device) }
            hold.subtitle = "Agents wait until you release it"
            actions.addItem(hold)
        }
        actions.addItem(.separator())
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func hosted(_ view: some View, width: CGFloat = 300) -> NSMenuItem {
        let host = NSHostingView(rootView: view
            .frame(minWidth: width, maxWidth: .infinity, alignment: .leading)
            .environmentObjects(peon, devices, servers, settings, leases, hooks))
        host.frame.size = host.fittingSize
        host.autoresizingMask = [.width]
        let item = NSMenuItem()
        item.view = host
        return item
    }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

enum Pasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

private struct MenuVolumeRow: View {
    @EnvironmentObject private var peon: PeonStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
            CommitSlider(value: peon.volume, commit: peon.setVolume)
        }
        .disabled(peon.paused)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

private struct MenuCategoryList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(SoundCategory.all) { CategoryRow(category: $0) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
