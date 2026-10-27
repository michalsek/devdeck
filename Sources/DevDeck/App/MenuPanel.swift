import AppKit
import SwiftUI

/// The dropdown from the menu bar icon: what's running, and the quick sound controls.
struct MenuPanel: View {
    @EnvironmentObject private var peon: PeonStore
    @EnvironmentObject private var devices: DeviceStore
    @EnvironmentObject private var servers: ServerStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menuShowsCategories") private var showsCategories = false
    @AppStorage("dashboardPage") private var page: DashboardPage = .servers

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sounds
            Divider()
            header("Devices", count: devices.running.count, page: .devices)
            if devices.running.isEmpty {
                empty(devices.loaded ? "Nothing running" : "Loading…")
            }
            ForEach(devices.running) { DeviceRow(device: $0, compact: true) }

            Divider()
            header("Dev Servers", count: servers.devServers.count, page: .servers)
            if servers.devServers.isEmpty {
                empty(servers.loaded ? "Nothing running" : "Loading…")
            }
            ForEach(servers.devServers) { ServerRow(server: $0, compact: true) }

            ForEach([devices.lastError, servers.lastError, peon.lastError].compactMap { $0 }, id: \.self) {
                Text($0).font(.caption).foregroundStyle(.red).lineLimit(3)
            }

            Divider()
            HStack {
                Button("Open Dashboard…") { open(nil) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private var sounds: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agent Sounds").font(.headline)
                Spacer()
                Toggle("Mute all", isOn: Binding(get: { peon.paused }, set: { peon.setPaused($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Group {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                    CommitSlider(value: peon.volume, commit: peon.setVolume)
                }
                Picker("Voice pack", selection: Binding(get: { peon.defaultPack }, set: { peon.usePack($0) })) {
                    ForEach(peon.packs) { Text($0.displayName).tag($0.id) }
                }
                DisclosureGroup("Per-sound volume", isExpanded: $showsCategories) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(SoundCategory.all) { CategoryRow(category: $0) }
                    }
                    .padding(.top, 4)
                }
            }
            .disabled(peon.paused)
        }
    }

    private func header(_ title: String, count: Int, page target: DashboardPage) -> some View {
        HStack {
            Text(title).font(.headline)
            Text("\(count) running").foregroundStyle(.secondary)
            Spacer()
            Button("Show All") { open(target) }
                .buttonStyle(.link)
                .controlSize(.small)
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).font(.callout)
    }

    private func open(_ target: DashboardPage?) {
        if let target { page = target }
        openWindow(id: "dashboard")
        NSApplication.bringToFront()
    }
}
