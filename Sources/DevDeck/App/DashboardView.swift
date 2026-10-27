import SwiftUI

enum DashboardPage: String, Hashable, CaseIterable {
    case devices, servers, sounds, packs, clients, general

    static let storageKey = "dashboardPage"

    var title: String {
        switch self {
        case .devices: "Devices"
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
        case .servers: "Dev servers running on this Mac, found by their listening ports. Stop the ones that are left over."
        case .sounds: "The sounds peon-ping plays when a coding agent finishes, fails or needs your input."
        case .packs: "The voice that plays agent sounds. Click a pack to use it, or the play button to hear it."
        case .clients: "Choose which coding agents and apps can play sounds and show notifications."
        case .general: "Start-up options, and where peon-ping keeps its settings."
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var devices: DeviceStore
    @EnvironmentObject private var servers: ServerStore
    @AppStorage(DashboardPage.storageKey) private var page: DashboardPage = .servers

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { page }, set: { if let value = $0 { page = value } })) {
                Section {
                    row(.devices, badge: devices.running.count)
                    row(.servers, badge: servers.devServers.count)
                }
                Section {
                    row(.sounds)
                    row(.packs)
                    row(.clients)
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
                Text("The number next to the menu bar icon is how many dev servers are running. The icon dims while sounds are muted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            if app.lastError != nil || peon.lastError != nil {
                Section { ErrorRow(errors: [app.lastError, peon.lastError]) }
            }
        }
        .formStyle(.grouped)
    }
}
