import Foundation

/// One agent session, e.g. Claude Code in T3 Code working in my-app.
struct AgentSession: Hashable {
    let agent: AgentKind
    let sessionID: String
    let host: String?
    let project: DevServer.Project

    var id: String { agent.rawValue + ":" + sessionID }
    /// "Claude Code · my-app"
    var label: String { agent.title + " · " + project.name }
    /// "Claude Code in T3 Code"
    var agentDescription: String { host.map { "\(agent.title) in \($0)" } ?? agent.title }
}

/// Which agent session is driving which device. Phase 1 only watches: the most recent
/// session to act on a device holds it until it's idle for `idleTimeout`, the session
/// ends, or the device is shut down. Nothing is blocked.
@MainActor
final class LeaseStore: ObservableObject {
    struct Lease: Identifiable, Hashable {
        let deviceID: String
        let session: AgentSession
        let since: Date
        var lastAction: Date
        var lastActionName: String

        var id: String { deviceID }
    }

    static let idleTimeout: TimeInterval = 10 * 60

    @Published private(set) var leases: [String: Lease] = [:]
    @Published private(set) var listening = false

    private let devices: DeviceStore
    private var server: BrokerServer?
    private var timer: Timer?

    init(devices: DeviceStore) {
        self.devices = devices
        server = BrokerServer { [weak self] data in
            Task { @MainActor in self?.receive(data) }
        }
        listening = server != nil
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
    }

    func lease(for device: DeviceItem) -> Lease? { leases[device.id] }

    /// Leases on devices that are still running, newest action first.
    var active: [Lease] { leases.values.sorted { $0.lastAction > $1.lastAction } }

    func forget(_ device: DeviceItem) {
        leases[device.id] = nil
    }

    private func receive(_ data: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = HookEvent(json: json)
        else { return }
        apply(event)
    }

    func apply(_ event: HookEvent, now: Date = .now) {
        let session = AgentSession(
            agent: event.agent, sessionID: event.sessionID, host: event.host,
            project: ServerScanner.project(for: event.cwd, fallback: event.agent.title))
        switch event.kind {
        case .sessionEnd:
            leases = leases.filter { $0.value.session.id != session.id }
        case .toolUse:
            for id in event.releases.flatMap(resolve) { leases[id] = nil }
            for id in event.targets.flatMap(resolve) {
                if var lease = leases[id], lease.session.id == session.id {
                    lease.lastAction = now
                    lease.lastActionName = event.action
                    leases[id] = lease
                } else {
                    leases[id] = Lease(
                        deviceID: id, session: session, since: now, lastAction: now, lastActionName: event.action)
                }
            }
        }
    }

    /// Matches a target to DevDeck's device ids (UDID, "avd:<name>" or adb serial).
    private func resolve(_ target: DeviceTarget) -> [String] {
        switch target {
        case .id(let key):
            let device = devices.devices.first { $0.id == key || $0.serial == key }
            return [device?.id ?? key]
        case .bootedSimulator:
            let booted = devices.running.filter { $0.kind == .simulator }
            return booted.count == 1 ? [booted[0].id] : []
        case .defaultAndroid:
            let connected = devices.running.filter { $0.platform == .android }
            return connected.count == 1 ? [connected[0].id] : []
        case .allSimulators:
            let simulators = Set(devices.devices.filter { $0.kind == .simulator }.map(\.id))
            return leases.keys.filter(simulators.contains)
        }
    }

    /// Drops idle leases and leases on devices that have stopped.
    private func prune(now: Date = .now) {
        let stopped = Set(devices.devices.filter { !$0.isRunning }.map(\.id))
        let kept = leases.filter { id, lease in
            now.timeIntervalSince(lease.lastAction) < Self.idleTimeout && !stopped.contains(id)
        }
        if kept.count != leases.count { leases = kept }
    }
}
