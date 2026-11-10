import Combine
import DevDeckProtocol
import Foundation
import os

/// Receives agent hook calls from `devdeck-hook` and scripts' commands on the broker
/// socket, and routes them: the call's rules (`CallPolicy`), Metro for the agent
/// (`MetroKeeper`), the agent's record (`AgentStore`), then the lease book (`LeaseStore`),
/// which answers the hook. If DevDeck isn't running, hooks don't wait at all.
@MainActor
final class Broker: ObservableObject {
    private static let log = Logger(subsystem: "dev.devdeck.app", category: "broker")

    @Published private(set) var listening = false
    /// The last build, install or launch an agent ran on each device, and how it went.
    @Published private(set) var results: [String: CallResult] = [:]

    struct CallResult: Hashable {
        let action: String
        let agent: String
        let failed: Bool
        /// The end of its output.
        let output: String
        let date: Date
    }

    private let leases: LeaseStore
    private let agents: AgentStore
    private let claims: ClaimStore
    private let keeper: MetroKeeper
    private let devices: DeviceStore
    private let servers: ServerStore
    private let monitor: ResourceMonitor
    private let settings: AppSettings
    private let notifier: Notifier
    private let activity: ActivityLog
    private let pulse: Pulse
    private let sounds: SoundStore
    private var server: BrokerServer?
    /// "session|device|Metro pid" the agent has been warned about.
    private var metroWarned: Set<String> = []
    private var subscription: AnyCancellable?

    init(
        leases: LeaseStore, agents: AgentStore, claims: ClaimStore, keeper: MetroKeeper, devices: DeviceStore,
        servers: ServerStore, monitor: ResourceMonitor, settings: AppSettings, notifier: Notifier, activity: ActivityLog,
        pulse: Pulse, sounds: SoundStore
    ) {
        self.leases = leases
        self.agents = agents
        self.claims = claims
        self.keeper = keeper
        self.devices = devices
        self.servers = servers
        self.monitor = monitor
        self.settings = settings
        self.notifier = notifier
        self.activity = activity
        self.pulse = pulse
        self.sounds = sounds
        guard !Demo.isOn else { return }
        // A call that boots a simulator or emulator, once it runs: the agent booted it.
        subscription = leases.ran.sink { [agents] waiter in
            guard waiter.pools.contains(.iosSimulator) || waiter.pools.contains(.androidEmulator) else { return }
            agents.noteBooted(waiter.devices, by: waiter.session.id)
        }
        openSocket()
    }

    /// Something replaced or removed the socket file: open a fresh one.
    func reopenSocketIfStale() {
        if server?.isStale ?? true { openSocket() }
    }

    private func openSocket() {
        server = BrokerServer { [weak self] data, connection in
            Task { @MainActor in self?.receive(data, connection) }
        }
        listening = server != nil
    }

    // MARK: Hook calls

    private func receive(_ data: Data, _ connection: BrokerConnection) {
        pulse.noteActivity()
        if let script = try? JSONDecoder().decode(ScriptCommand.self, from: data) {
            return run(script, connection)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let agent = (json[HookProtocol.Field.agent] as? String).flatMap(AgentKind.init),
              let sessionID = json["session_id"] as? String
        else { return connection.respond(.allow) }
        let session = AgentSession(
            agent: agent, sessionID: sessionID, host: json[HookProtocol.Field.host] as? String,
            project: ServerScanner.project(for: json["cwd"] as? String, fallback: agent.title))
        sounds.hear(json, session: session, agentPID: (json[HookProtocol.Field.agentPID] as? Int).map(Int32.init))
        // Events that only play sounds end here; their hook doesn't wait for an answer.
        guard let event = HookEvent(json: json) else { return connection.close() }
        let now = Date.now

        switch event.kind {
        case .sessionEnd:
            agents.note(event, session: session, now: now)
            claims.sessionEnded(session.id, now: now)
            leases.sessionEnded(session.id, now: now)
            connection.close()
        case .turnEnd:
            agents.note(event, session: session, now: now)
            claims.turnEnded(session.id, now: now)
            leases.turnEnded(session.id, now: now)
            connection.close()
        case .deviceInUse:
            agents.note(event, session: session, now: now)
            connection.respond(HookReply(context: deviceInUse(event, asker: session)))
        case .result(let failed):
            agents.note(event, session: session, now: now)
            for id in event.targets.flatMap(devices.index.resolve) {
                results[id] = CallResult(
                    action: event.action, agent: session.label, failed: failed, output: event.output ?? "", date: now)
            }
            connection.close()
        case .toolUse:
            toolUse(event, session: session, connection: connection, now: now)
        }
    }

    private func toolUse(_ event: HookEvent, session: AgentSession, connection: BrokerConnection, now: Date) {
        agents.note(event, session: session, now: now)
        let claimDevices = event.agentDevice.map(claims.devices(for:)) ?? []
        if let call = event.agentDevice { claims.noteCall(call, by: session, now: now) }
        let index = devices.index
        // A Metro DevDeck runs belongs to the session it was started for, whichever of its
        // processes listens.
        var owners = agents.owners
        for server in servers.servers {
            if let id = keeper.kept(for: server)?.session, let owner = agents.records[id]?.session { owners[server.pid] = owner }
        }
        let policy = CallPolicy(
            devices: index, servers: servers.servers, builds: monitor.builds, leases: leases.book.leases,
            owners: owners, androidTesting: settings.androidTesting, metroWarned: metroWarned)
        var waiter = LeaseBook.Waiter(event, session: session, claimDevices: claimDevices, devices: index, now: now)
        waiter.approval = policy.approval(event, by: session)
        waiter.needsUser = CallPolicy.needsUser(waiter, devices: index)

        if let refusal = policy.refusal(waiter) {
            refuse(refusal, waiter)
            return connection.respond(.deny(refusal.reason))
        }
        // DevDeck runs Metro for the agent, so the agent's shell ending doesn't stop it.
        if waiter.pools == [.devServer], leases.hasRoom(for: waiter), let command = event.command,
           let start = keeper.recognize(command, cwd: event.cwd) {
            Task {
                switch await keeper.start(start, path: event.path, session: session) {
                case .taken(let reply, let started):
                    if let metro = started { agents.adopt(metro.pid, label: "Metro :\(metro.port)", by: session.id) }
                    connection.respond(.deny(reply))
                case .failed:
                    leases.submit(waiter, connection: connection, now: .now)
                }
            }
            return
        }
        leases.submit(waiter, connection: connection, now: now)
    }

    private func refuse(_ refusal: CallPolicy.Refusal, _ waiter: LeaseBook.Waiter) {
        let session = waiter.session
        switch refusal {
        case .phonesOnly(let reason, let noPhone):
            activity.add(.guarded, agent: session.label, subject: waiter.action, "Turned away: " + reason, session: session.id)
            if noPhone {
                notifier.plain(
                    "phone-\(session.id)", title: "\(session.label) needs an Android phone",
                    body: "You asked agents to test Android on a physical phone. Connect one with USB debugging on.",
                    page: .devices)
            }
        case .wrongMetro(let reason, let key):
            metroWarned.insert(key)
            activity.add(.metro, agent: session.label, subject: waiter.action, "Warned the agent: " + reason, session: session.id)
        }
    }

    /// agent-device turned a command away with `DEVICE_IN_USE`: tell the agent who holds the
    /// device and whether waiting helps, and tell the user when the holder looks abandoned.
    private func deviceInUse(_ event: HookEvent, asker: AgentSession) -> String? {
        guard let holder = event.holder, let status = claims.claim(heldBy: holder) else { return nil }
        let now = Date.now
        let state = claims.state(of: status, now: now)
        let index = devices.index
        let device = index.device(status.claim.deviceID)
        let name = device?.name ?? status.claim.deviceName
        let free = device.map { wanted in
            index.running.filter {
                $0.isSameKind(as: wanted) && $0.kind != .physical && $0.id != wanted.id
                    && leases.lease(for: $0) == nil && !leases.isQueued(for: $0) && claims.claims(for: $0).isEmpty
            }
        } ?? []
        Self.log.info("\(asker.label, privacy: .public) DEVICE_IN_USE on \(name, privacy: .public), held by \(holder, privacy: .public), \(state.isStale ? "stale" : "active", privacy: .public)")
        if state.isStale, settings.notifyWaits {
            notifier.staleClaim(
                session: holder, title: "\(name) has a stale agent-device claim",
                body: "\(asker.label) can't use it: session \(AgentDevice.shortName(holder)) (\(status.claim.project))"
                    + " has run nothing for \(Format.age(since: status.lastActivity, now: now)).")
        }
        return ClaimText.advice(
            deviceName: name, status: status, owner: claims.owner(of: status), state: state,
            program: event.agentDevice?.program, freeDevices: free, now: now)
    }

    // MARK: Scripts

    /// Commands for scripts, e.g. `{"command": "hold", "device": "<udid or serial>"}`:
    /// hold, release, queue, leave; `front` / `run` / `dismiss` with `"waiter": "<id>"`; or status.
    private func run(_ script: ScriptCommand, _ connection: BrokerConnection) {
        func fail(_ error: String) { connection.respond(json: BrokerError(error: error)) }
        if script.command != "status" {
            if let id = script.waiter.flatMap(UUID.init(uuidString:)),
               let waiter = leases.book.waiters.first(where: { $0.id == id }) {
                switch script.command {
                case "front": leases.moveToFront(waiter)
                case "run": leases.runNow(waiter)
                case "dismiss": leases.dismiss(waiter)
                default: return fail("unknown command")
                }
            } else {
                guard let device = script.device.flatMap(devices.index.device) else { return fail("unknown device") }
                switch script.command {
                case "hold": leases.hold(device)
                case "release": leases.release(device)
                case "queue": leases.joinQueue(device)
                case "leave": leases.leaveQueue(device)
                default: return fail("unknown command")
                }
            }
        }
        let now = Date.now
        connection.respond(json: BrokerStatus(
            book: leases.book, claims: claims.claims.map { ($0, claims.state(of: $0, now: now), claims.owner(of: $0)) },
            memoryFree: monitor.snapshot.memoryFree, now: now))
    }
}
