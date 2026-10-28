import SwiftUI

enum DashboardPage: String, Hashable, CaseIterable {
    case devices, leases, resources, servers, sounds, packs, clients, general

    static let storageKey = "dashboardPage"

    var title: String {
        switch self {
        case .devices: "Devices"
        case .leases: "Leases"
        case .resources: "Resources"
        case .servers: "Dev Servers"
        case .sounds: "Agent Sounds"
        case .packs: "Voice Packs"
        case .clients: "Agent Apps"
        case .general: "General"
        }
    }

    var symbol: String {
        switch self {
        case .devices: "iphone.gen3"
        case .leases: "hand.raised.fill"
        case .resources: "gauge.with.dots.needle.67percent"
        case .servers: "server.rack"
        case .sounds: "speaker.wave.2.fill"
        case .packs: "person.wave.2.fill"
        case .clients: "app.connected.to.app.below.fill"
        case .general: "gearshape.fill"
        }
    }

    var color: Color {
        switch self {
        case .devices: .blue
        case .leases: .indigo
        case .resources: .teal
        case .servers: .green
        case .sounds: .pink
        case .packs: .orange
        case .clients: .purple
        case .general: .gray
        }
    }

    var summary: String {
        switch self {
        case .devices: "Simulators, emulators and connected phones. Boot them, or shut down the ones you're done with."
        case .resources: "How loaded this Mac is, and how much heavy work agents may start at once. Over a limit, or low on memory, they wait."
        case .leases: "Who is using each simulator and device, and who's waiting for it. Agents wait for you, and for each other."
        case .servers: "Dev servers running on this Mac, found by their listening ports. Stop the ones that are left over."
        case .sounds: "The sounds peon-ping plays when a coding agent finishes, fails or needs your input."
        case .packs: "The voice that plays agent sounds. Click a pack to use it, or the play button to hear it."
        case .clients: "Choose which coding agents and apps can play sounds and show notifications."
        case .general: "Start-up options and the menu bar icon."
        }
    }

    /// The peon-ping pages, hidden when peon-ping isn't installed.
    var needsPeon: Bool { [.sounds, .packs, .clients].contains(self) }
}

struct DashboardView: View {
    @EnvironmentObject private var devices: DeviceStore
    @EnvironmentObject private var leases: LeaseStore
    @EnvironmentObject private var servers: ServerStore
    @EnvironmentObject private var peon: PeonStore
    @AppStorage(DashboardPage.storageKey) private var storedPage: DashboardPage = .servers

    /// The stored page, unless it's a peon-ping page and peon-ping isn't installed.
    private var page: DashboardPage { storedPage.needsPeon && !peon.installed ? .servers : storedPage }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { page }, set: { if let value = $0 { storedPage = value } })) {
                Section {
                    row(.devices, badge: devices.running.count)
                    row(.leases, badge: leases.book.waiters.count - leases.waitingForRoom.count)
                    row(.resources, badge: leases.waitingForRoom.count)
                    row(.servers, badge: servers.devServers.count)
                }
                if peon.installed {
                    Section {
                        row(.sounds)
                        row(.packs)
                        row(.clients)
                    }
                }
                Section {
                    row(.general)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                switch page {
                case .devices: DevicesView()
                case .leases: LeasesView()
                case .resources: ResourcesView()
                case .servers: ServersView()
                case .sounds: SoundsView()
                case .packs: PacksView()
                case .clients: ClientsView()
                case .general: GeneralView()
                }
            }
            .navigationTitle(page.title)
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private func row(_ page: DashboardPage, badge: Int = 0) -> some View {
        Label {
            Text(page.title)
        } icon: {
            IconTile(symbol: page.symbol, color: page.color)
        }
        .badge(badge)
        .tag(page)
    }
}

/// The coloured rounded-square icon System Settings uses for its panes.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.55, weight: .medium))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// The card at the top of each page: icon, title and a line on what the page is for.
struct PageHeader: View {
    let page: DashboardPage

    var body: some View {
        Section {
            VStack(spacing: 6) {
                IconTile(symbol: page.symbol, color: page.color, size: 52)
                    .padding(.bottom, 4)
                Text(page.title).font(.title2.weight(.semibold))
                Text(page.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 24)
        }
    }
}

/// A red line for the last error a store reported.
struct ErrorRow: View {
    let errors: [String?]

    var body: some View {
        ForEach(errors.compactMap { $0 }, id: \.self) { error in
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
        }
    }
}

struct GeneralView: View {
    @EnvironmentObject private var app: AppSettings
    @EnvironmentObject private var peon: PeonStore
    @EnvironmentObject private var hooks: HookInstaller

    var body: some View {
        Form {
            PageHeader(page: .general)
            Section {
                Toggle("Open DevDeck at login", isOn: Binding(
                    get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
                Picker("Menu bar icon", selection: $app.menuBarIcon) {
                    ForEach(MenuBarIcon.allCases) { icon in
                        Image(nsImage: icon.image()).help(icon.title).tag(icon)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            } footer: {
                Text("The number next to the menu bar icon is how many dev servers are running."
                    + (peon.installed ? " The icon dims while sounds are muted." : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            AgentHooksSection()
            if peon.installed {
                Section("peon-ping") {
                    LabeledContent("Version", value: peon.version.isEmpty ? "unknown" : peon.version)
                    LabeledContent("Data folder") {
                        Text(peon.peonDir.path).textSelection(.enabled)
                    }
                    HStack {
                        Spacer()
                        Button("Open config.json") { peon.openConfig() }
                    }
                }
            }
            if app.lastError != nil || peon.lastError != nil || hooks.lastError != nil {
                Section { ErrorRow(errors: [app.lastError, peon.lastError, hooks.lastError]) }
            }
        }
        .formStyle(.grouped)
    }
}

/// Turns the agent hooks on and off. They tell DevDeck which device each agent is driving.
private struct AgentHooksSection: View {
    @EnvironmentObject private var app: AppSettings
    @EnvironmentObject private var hooks: HookInstaller
    @EnvironmentObject private var leases: LeaseStore

    var body: some View {
        Section {
            ForEach(AgentKind.allCases) { agent in
                Toggle(isOn: Binding(get: { hooks.installed.contains(agent) }, set: { hooks.set(agent, enabled: $0) })) {
                    Text(agent.title)
                    Text(hooks.isAvailable(agent)
                        ? HookInstaller.configURL(agent).path.replacingOccurrences(
                            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
                        : "Not installed")
                }
                .disabled(!hooks.isAvailable(agent))
            }
            Picker(selection: $app.holdReleaseMinutes) {
                ForEach([5, 10, 15, 30], id: \.self) { Text("After \($0) min away").tag($0) }
                Text("Never").tag(0)
            } label: {
                Text("Release my holds")
                Text("When you hold a device, agents wait. Your hold ends when you release it, or after this long without keyboard or mouse input on the Mac.")
            }
            Toggle(isOn: $app.notifyWaits) {
                Text("Notify me when an agent has to wait")
                Text("A notification says which agent waits and why, with Let Through and Turn Away buttons")
            }
            Toggle(isOn: $app.deviceMarkers) {
                Text("Show a marker on the device")
                Text("Installs the DevDeck companion on simulators and emulators an agent drives: a Live Activity in the Dynamic Island, or a silent notification on Android")
            }
        } header: {
            Text("Agent Activity")
        } footer: {
            Text(leases.listening
                ? "Agents report which simulator or device they're driving, and DevDeck marks it in purple. When you hold a device, an agent's next call on it waits (up to 9 minutes) until you release it. If DevDeck isn't running, nothing waits. Codex skips new or changed hooks until you trust them in /hooks."
                : "DevDeck couldn't open its socket, so agent activity isn't shown.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
