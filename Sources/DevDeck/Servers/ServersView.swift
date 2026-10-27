import AppKit
import SwiftUI

struct ServersView: View {
    @EnvironmentObject private var store: ServerStore
    @State private var selection: DevServer.ID?
    @State private var showInspector = true

    var body: some View {
        List(selection: $selection) {
            Section("Dev servers") {
                if store.devServers.isEmpty {
                    Text("No dev servers running").foregroundStyle(.secondary)
                }
                ForEach(store.devServers) { ServerRow(server: $0).tag($0.id) }
            }
            if !store.agentTools.isEmpty {
                Section("Agent tools") {
                    ForEach(store.agentTools) { ServerRow(server: $0).tag($0.id) }
                }
            }
            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .overlay {
            if !store.loaded { ProgressView() }
        }
        .navigationTitle("Dev Servers")
        .navigationSubtitle("\(store.devServers.count) running")
        .inspector(isPresented: $showInspector) {
            Group {
                if let server = store.servers.first(where: { $0.id == selection }) {
                    ServerInspector(server: server)
                } else {
                    Placeholder(title: "No selection", systemImage: "server.rack",
                                detail: "Select a server to see its details.")
                }
            }
            .inspectorColumnWidth(min: 240, ideal: 280, max: 400)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                Button("Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
            }
        }
        .onAppear {
            if selection == nil { selection = store.devServers.first?.id }
        }
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
}

struct ServerRow: View {
    @EnvironmentObject private var store: ServerStore
    let server: DevServer
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(tone: server.tone)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.project.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !compact {
                Pill(text: server.kind).frame(width: 130, alignment: .leading)
                Text(server.portList).font(.system(.body, design: .monospaced))
                    .frame(width: 56, alignment: .leading)
                Text(Format.age(since: server.started)).monospacedDigit()
                    .frame(width: 44, alignment: .leading)
            }
            ConfirmButton(title: "Stop", busy: store.stopping.contains(server.pid)) { store.stop(server) }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if server.url != nil { Button("Open in Browser") { store.open(server) } }
            if server.cwd != nil {
                Button("Reveal in Finder") { store.reveal(server) }
                Button("Open in Terminal") { store.openTerminal(server) }
            }
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(server.command, forType: .string)
            }
        }
    }

    private var subtitle: String {
        if compact {
            return [server.kind + " :" + server.portList, "up " + Format.age(since: server.started), server.statusNote]
                .compactMap { $0 }.joined(separator: " · ")
        }
        return [server.project.subtitle, server.statusNote].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

struct ServerInspector: View {
    @EnvironmentObject private var store: ServerStore
    let server: DevServer

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(server.project.name).font(.headline)
                    HStack {
                        Pill(text: server.kind)
                        if let note = server.statusNote {
                            Pill(text: note, tint: server.tone == .attention ? .orange : .green)
                        }
                    }
                }
                HStack {
                    if server.url != nil { Button("Open") { store.open(server) } }
                    Spacer()
                    ConfirmButton(title: "Stop", busy: store.stopping.contains(server.pid)) { store.stop(server) }
                }
            }
            Section("Details") {
                LabeledContent("Ports", value: server.portList)
                LabeledContent("Running for", value: Format.age(since: server.started))
                if let started = server.started {
                    LabeledContent("Started", value: started.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("PID", value: String(server.pid))
                if let apps = server.metro?.apps, !apps.isEmpty {
                    LabeledContent("Apps", value: apps.joined(separator: "\n"))
                }
            }
            if let cwd = server.cwd {
                Section("Folder") {
                    Text(cwd).font(.caption).textSelection(.enabled)
                    HStack {
                        Button("Reveal in Finder") { store.reveal(server) }
                        Button("Terminal") { store.openTerminal(server) }
                    }
                }
            }
            Section("Command") {
                Text(server.command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(8)
            }
        }
        .formStyle(.grouped)
    }
}
