import Combine
import Foundation

/// The Metro server an app on a device is attached to.
struct MetroLink: Hashable {
    let server: DevServer
    /// The app's name or bundle id, when known.
    let app: String?

    var port: Int { server.metro?.port ?? server.ports.first ?? 0 }

    /// "Metro :8081 · weather-app"
    var summary: String { "Metro :\(port) · \(server.project.name)" }
}

extension Array where Element == DevServer {
    /// The Metro the device's app is attached to. Simulator apps are matched by their
    /// connection to Metro; other devices by the name their app gives Metro, and for
    /// emulators (and when that's ambiguous) by `adb reverse`.
    func metro(for device: DeviceItem) -> MetroLink? {
        let metros = filter { $0.metro != nil }
        if device.kind == .simulator {
            for server in metros {
                if let app = server.metro?.simulators[device.id] { return MetroLink(server: server, app: app) }
            }
            return nil
        }
        let names = [device.name, device.model].compactMap { $0.map(Self.normalized) }
        let candidates = metros.compactMap { server -> MetroLink? in
            guard let target = server.metro?.targets.first(where: { names.contains(Self.normalized($0.deviceName)) })
            else { return nil }
            return MetroLink(server: server, app: target.app)
        }
        // Every emulator gives Metro the same model name, so an emulator needs its adb reverse
        // rule to tell which Metro is its own.
        if candidates.count <= 1, device.kind != .emulator { return candidates.first }
        let reversed = candidates.filter { device.reversePorts.contains($0.port) }
        return reversed.count == 1 ? reversed[0] : nil
    }

    private static func normalized(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ").lowercased()
    }
}

extension MetroLink {
    /// The app is attached to another checkout's Metro than the agent working on the
    /// device, so the agent's changes won't show.
    func isWrong(for project: DevServer.Project) -> Bool { !server.project.isSameCheckout(as: project) }

    /// What the agent reads the first time it acts on such a device.
    func warning(device: String, project: DevServer.Project) -> String {
        "DevDeck: the app on \(device) is attached to Metro on port \(port), which serves "
            + "\(server.project.name)\(server.project.worktree.map { " (worktree \($0))" } ?? ""), not your checkout "
            + "(\(project.name)\(project.worktree.map { ", worktree \($0)" } ?? "")). Your JavaScript changes won't show, "
            + "so this call was not run. Start your own project's Metro on a free port and point the app at it "
            + "(iOS simulator: launch with -RCT_jsLocation 127.0.0.1:<port>; Android: adb reverse tcp:8081 tcp:<port>), "
            + "then try again. If this Metro is the right one, run the same call again and DevDeck lets it through."
    }
}

/// Tells the user when an agent works on a device whose app loads another project's
/// Metro, once per agent, device and server.
@MainActor
final class MetroWatcher {
    private let devices: DeviceStore
    private let servers: ServerStore
    private let leases: LeaseStore
    private let notifier: Notifier
    private let activity: ActivityLog
    private var subscription: AnyCancellable?
    private var told: Set<String> = []

    init(devices: DeviceStore, servers: ServerStore, leases: LeaseStore, notifier: Notifier, activity: ActivityLog) {
        self.devices = devices
        self.servers = servers
        self.leases = leases
        self.notifier = notifier
        self.activity = activity
        guard !Demo.isOn else { return }
        subscription = Publishers.CombineLatest3(devices.$devices, servers.$servers, leases.$book)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.check() }
    }

    private func check() {
        for device in devices.running {
            guard let session = leases.lease(for: device)?.holder.session,
                  let link = servers.servers.metro(for: device), link.isWrong(for: session.project)
            else { continue }
            let key = "\(session.id)|\(device.id)|\(link.server.pid)"
            guard told.insert(key).inserted else { continue }
            let detail = "\(session.label) is working on it, but its app is attached to \(link.server.project.name)'s "
                + "Metro on port \(link.port), so the agent's changes won't show."
            activity.add(.metro, agent: session.label, subject: device.name, detail)
            notifier.plain(
                "metro-\(key)", title: "\(device.name) loads \(link.server.project.name)'s Metro", body: detail,
                page: .devices)
        }
    }
}
