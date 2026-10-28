import AppKit
import SwiftUI

struct ServersView: View {
    @EnvironmentObject private var store: ServerStore
    @State private var details: DevServer?

    var body: some View {
        Form {
            PageHeader(page: .servers)
            Section("Dev Servers") {
                if store.devServers.isEmpty {
                    Text(store.loaded ? "No dev servers running" : "Loading…").foregroundStyle(.secondary)
                }
                ForEach(store.devServers) { ServerRow(server: $0) { details = $0 } }
            }
            if !store.agentTools.isEmpty {
                Section {
                    ForEach(store.agentTools) { ServerRow(server: $0) { details = $0 } }
                } header: {
                    Text("Agent Tools")
                } footer: {
                    Text("Helpers started by coding agents, such as the argent tool server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if store.lastError != nil {
                Section { ErrorRow(errors: [store.lastError]) }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $details) { ServerDetails(snapshot: $0) }
    }
}

extension DevServer {
    var tone: StatusDot.Tone {
        if let metro, metro.apps.isEmpty { return .attention }
        return .running
    }

    var statusNote: String? {
        guard let metro else { return nil }
        if metro.apps.isEmpty { return "no app connected" }
        return metro.apps.count == 1 ? "1 app connected" : "\(metro.apps.count) apps connected"
    }

    /// Metro with at least one app attached, so a reload has someone to reach.
    var canReloadApps: Bool { !(metro?.apps.isEmpty ?? true) }

    /// "Metro · Expo · :8082 · up 3 d · no app connected"
    var summary: String {
        [kind, ":" + portList, "up " + Format.age(since: started), statusNote].compactMap { $0 }
            .joined(separator: " · ")
    }
}

struct ServerRow: View {
    @EnvironmentObject private var store: ServerStore
    let server: DevServer
    let showDetails: (DevServer) -> Void

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(tone: server.tone)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.project.name).lineLimit(1)
                    if !server.project.subtitle.isEmpty {
                        Text(server.project.subtitle).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text(server.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if server.metro != nil { ReloadButton(server: server) }
            ConfirmButton(title: "Stop", busy: store.stopping.contains(server.pid)) { store.stop(server) }
            Button { showDetails(server) } label: {
                Image(systemName: "info.circle").font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .help("Details")
        }
        .padding(.vertical, 2)
        .contextMenu {
            if server.canReloadApps { Button("Reload Apps") { store.reloadApps(server) } }
            if server.url != nil { Button("Open in Browser") { store.open(server) } }
            if server.cwd != nil {
                Button("Reveal in Finder") { store.reveal(server) }
                Button("Open in Terminal") { store.openTerminal(server) }
            }
            Button("Copy Command") { Pasteboard.copy(server.command) }
            Divider()
            Button("Details…") { showDetails(server) }
        }
    }
}

/// Reloads the apps attached to a Metro server, like pressing `r` in its terminal.
/// The arrow spins while the reload goes out.
struct ReloadButton: View {
    @EnvironmentObject private var store: ServerStore
    let server: DevServer

    var body: some View {
        Button { store.reloadApps(server) } label: {
            Label("Reload", systemImage: "arrow.clockwise")
                .symbolEffect(.rotate, isActive: store.reloading.contains(server.pid))
        }
        .buttonStyle(.bordered)
        .disabled(!server.canReloadApps)
        .help(server.canReloadApps ? "Reload the connected apps, like pressing r in Metro" : "No app connected")
    }
}

/// Everything known about one server, in a sheet like System Settings' "Details…".
struct ServerDetails: View {
    @EnvironmentObject private var store: ServerStore
    @Environment(\.dismiss) private var dismiss
    let snapshot: DevServer

    /// The live entry, so the sheet notices when the server stops.
    private var server: DevServer? { store.servers.first { $0.id == snapshot.id } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 12) {
                        IconTile(symbol: "server.rack", color: .green, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.project.name).font(.headline)
                            Text(server.map(\.summary) ?? "Not running")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if let server {
                    Section {
                        LabeledContent("Kind", value: server.kind)
                        LabeledContent("Ports", value: server.portList)
                        LabeledContent("Running for", value: Format.age(since: server.started))
                        if let started = server.started {
                            LabeledContent("Started", value: started.formatted(date: .abbreviated, time: .shortened))
                        }
                        LabeledContent("PID", value: String(server.pid))
                        if let apps = server.metro?.apps {
                            LabeledContent("Connected apps", value: apps.isEmpty ? "None" : apps.joined(separator: "\n"))
                        }
                    }
                    if let cwd = server.cwd {
                        Section("Folder") {
                            Text(cwd).textSelection(.enabled)
                            HStack {
                                Spacer()
                                Button("Reveal in Finder") { store.reveal(server) }
                                Button("Open in Terminal") { store.openTerminal(server) }
                            }
                        }
                    }
                    Section("Command") {
                        Text(server.command)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(10)
                    }
                } else {
                    Section { Text("This server is no longer running.").foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)

            HStack {
                if let server {
                    ConfirmButton(title: "Stop Server", busy: store.stopping.contains(server.pid)) { store.stop(server) }
                }
                Spacer()
                if let server, server.metro != nil { ReloadButton(server: server) }
                if let server, server.url != nil {
                    Button("Open in Browser") { store.open(server) }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 500, height: 560)
    }
}
