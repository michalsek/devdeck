import SwiftUI

enum DashboardPage: String, Hashable, CaseIterable {
    case devices, servers, sounds, packs, clients, general
}

struct DashboardView: View {
    @EnvironmentObject private var devices: DeviceStore
    @EnvironmentObject private var servers: ServerStore
    @AppStorage("dashboardPage") private var page: DashboardPage = .servers

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { page }, set: { if let value = $0 { page = value } })) {
                Section("Dev Environment") {
                    Label("Devices", systemImage: "iphone.gen3")
                        .badge(devices.running.count)
                        .tag(DashboardPage.devices)
                    Label("Dev Servers", systemImage: "server.rack")
                        .badge(servers.devServers.count)
                        .tag(DashboardPage.servers)
                }
                Section("Agent Sounds") {
                    Label("Sounds", systemImage: "speaker.wave.2").tag(DashboardPage.sounds)
                    Label("Voice Packs", systemImage: "person.wave.2").tag(DashboardPage.packs)
                    Label("Clients", systemImage: "app.connected.to.app.below.fill").tag(DashboardPage.clients)
                }
                Section {
                    Label("General", systemImage: "gearshape").tag(DashboardPage.general)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch page {
            case .devices: DevicesView()
            case .servers: ServersView()
            case .sounds: SoundsView()
            case .packs: PacksView()
            case .clients: ClientsView()
            case .general: GeneralView()
            }
        }
    }
}

struct GeneralView: View {
    @EnvironmentObject private var app: AppSettings
    @EnvironmentObject private var peon: PeonStore

    var body: some View {
        Form {
            Section {
                Toggle("Open DevDeck at login", isOn: Binding(
                    get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
            }
            Section("peon-ping") {
                LabeledContent("Version", value: peon.version.isEmpty ? "unknown" : peon.version)
                LabeledContent("Data folder", value: peon.peonDir.path)
                Button("Open config.json") { peon.openConfig() }
            }
            ForEach([app.lastError, peon.lastError].compactMap { $0 }, id: \.self) { error in
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}
