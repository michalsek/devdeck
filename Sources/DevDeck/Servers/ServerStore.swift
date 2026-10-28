import AppKit
import Foundation

@MainActor
final class ServerStore: ObservableObject {
    @Published private(set) var servers: [DevServer] = []
    @Published private(set) var stopping: Set<Int32> = []
    @Published private(set) var reloading: Set<Int32> = []
    @Published private(set) var lastError: String?
    @Published private(set) var loaded = false

    private var timer: Timer?
    private var refreshing = false

    init() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    var devServers: [DevServer] { servers.filter { $0.group == .devServer } }
    var agentTools: [DevServer] { servers.filter { $0.group == .agentTool } }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let scanned = await Task.detached(priority: .utility) { await ServerScanner.scan() }.value
        servers = scanned
        loaded = true
    }

    func stop(_ server: DevServer) {
        stopping.insert(server.pid)
        Task {
            let stopped = await Task.detached { await ServerScanner.stop(server.pid) }.value
            lastError = stopped ? nil : "\(server.project.name) (pid \(server.pid)) didn't stop."
            await refresh()
            stopping.remove(server.pid)
        }
    }

    func reloadApps(_ server: DevServer) {
        guard let port = server.metro?.port else { return }
        reloading.insert(server.pid)
        Task {
            let sent = await ServerScanner.reloadApps(port: port)
            lastError = sent ? nil : "Couldn't reach Metro on port \(port) to reload \(server.project.name)'s apps."
            try? await Task.sleep(for: .seconds(1))
            reloading.remove(server.pid)
        }
    }

    func open(_ server: DevServer) {
        if let url = server.url { NSWorkspace.shared.open(url) }
    }

    func reveal(_ server: DevServer) {
        guard let cwd = server.cwd else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
    }

    func openTerminal(_ server: DevServer) {
        guard let cwd = server.cwd else { return }
        Task { _ = await Shell.run("/usr/bin/open", ["-a", "Terminal", cwd]) }
    }
}
