import AppKit
import ServiceManagement
import SwiftUI

@main
struct DevDeckApp: App {
    @StateObject private var peon = PeonStore()
    @StateObject private var devices = DeviceStore()
    @StateObject private var servers = ServerStore()
    @StateObject private var app = AppSettings()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environmentObjects(peon, devices, servers, app)
        } label: {
            MenuBarLabel(muted: peon.paused, servers: servers.devServers.count)
                #if DEBUG
                .task { Snapshot.runIfRequested(peon, devices, servers, app) }
                #endif
        }
        .menuBarExtraStyle(.window)

        Window("DevDeck", id: "dashboard") {
            DashboardView()
                .environmentObjects(peon, devices, servers, app)
        }
        .defaultSize(width: 1120, height: 640)
    }
}

struct MenuBarLabel: View {
    let muted: Bool
    let servers: Int

    var body: some View {
        // The label renders as a template image; a count next to it shows running dev servers.
        HStack(spacing: 2) {
            Image(systemName: muted ? "speaker.slash.fill" : "switch.2")
            if servers > 0 { Text("\(servers)") }
        }
        .accessibilityLabel("DevDeck, \(servers) dev servers\(muted ? ", sounds muted" : "")")
    }
}

/// App-level settings that aren't peon-ping's.
@MainActor
final class AppSettings: ObservableObject {
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var lastError: String?

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

extension NSApplication {
    /// Menu-bar-only apps don't come to the front on their own when opening a window.
    @MainActor static func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
