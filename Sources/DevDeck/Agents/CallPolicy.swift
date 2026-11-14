import Foundation

/// The rules an agent's call meets before the lease book, read from a snapshot of what's
/// on the Mac: the user's rules, warnings, and what needs the user's OK or hands.
struct CallPolicy {
    let devices: DeviceIndex
    let servers: [DevServer]
    let builds: [ResourceMonitor.BuildJob]
    let leases: [String: LeaseBook.Lease]
    /// The session that started each process DevDeck knows about.
    let owners: [Int32: AgentSession]
    let androidTesting: AppSettings.AndroidTesting
    /// "session|device|Metro pid" the agent has been warned about.
    let metroWarned: Set<String>
    /// For a call that stops processes: the processes the agent may signal, and the process
    /// of each live agent session.
    var processes: [Int32: ServerScanner.ProcessRow] = [:]
    var agents: [Int32: AgentSession] = [:]

    /// A call turned away before it reaches the book.
    enum Refusal: Equatable {
        /// The user wants Android tested on a phone; `noPhone` when none is connected.
        case phonesOnly(reason: String, noPhone: Bool)
        /// The app on the device loads another checkout's Metro; asking again goes through.
        case wrongMetro(reason: String, key: String)
        /// The command stops the agent's own processes and others' too; it can stop just its own.
        case notOnlyYours(reason: String, segment: String)

        var reason: String {
            switch self {
            case .phonesOnly(let reason, _), .wrongMetro(let reason, _), .notOnlyYours(let reason, _): reason
            }
        }
    }

    func refusal(_ waiter: LeaseBook.Waiter) -> Refusal? {
        if androidTesting == .phonesOnly,
           waiter.pools.contains(.androidEmulator) || waiter.devices.contains(where: { devices.device($0)?.kind == .emulator }) {
            let phones = devices.running.filter {
                guard $0.platform == .android, $0.kind == .physical else { return false }
                guard let holder = leases[$0.id]?.holder else { return true }
                return holder.session?.id == waiter.session.id
            }
            return .phonesOnly(reason: AgentText.phonesOnly(phones), noPhone: phones.isEmpty)
        }
        guard !Self.rewiresApp.contains(waiter.action) else { return nil }
        for id in waiter.devices {
            guard let device = devices.device(id), let link = servers.metro(for: device),
                  link.isWrong(for: waiter.session, owners: owners)
            else { continue }
            let key = "\(waiter.session.id)|\(id)|\(link.server.pid)"
            guard !metroWarned.contains(key) else { continue }
            return .wrongMetro(reason: link.warning(device: device.name, project: waiter.session.project), key: key)
        }
        return nil
    }

    /// What a call does beyond the agent's own work.
    enum Reach: Equatable {
        /// It waits for the user's OK, for at most `wait` when that's shorter than any call's.
        case needsOK(LeaseBook.Approval, wait: TimeInterval?)
        case refused(Refusal)
    }

    /// A kill of processes the agent didn't start waits this long for the user's OK. They're
    /// another agent's or the user's, and an agent blocked for minutes on a kill it most
    /// likely got wrong helps nobody: it's then told which processes are whose.
    static let killWait: TimeInterval = 60

    /// What the call does beyond the agent's own work: something every agent relies on
    /// ("shuts down every simulator"), or processes another agent or the user started. A
    /// command that stops some of the agent's own processes too is turned away at once with
    /// the `kill` that stops just those.
    func reach(_ event: HookEvent, by session: AgentSession) -> Reach? {
        if let effect = event.everyoneEffect { return .needsOK(effect, wait: nil) }
        var own: [Int32] = []
        var others: [(segment: String, pid: Int32)] = []
        var shared: LeaseBook.Approval?
        for kill in event.kills {
            for pid in targets(of: kill, agentPID: event.agentPID) {
                if let effect = processes[pid].flatMap(CommandGuard.sharedEffect) {
                    shared = shared ?? LeaseBook.Approval(segment: kill.segment, effect: effect)
                    others.append((kill.segment, pid))
                } else if owner(of: pid)?.id == session.id {
                    own.append(pid)
                } else {
                    others.append((kill.segment, pid))
                }
            }
        }
        guard let first = others.first else { return nil }
        let names = Self.list(Array(Set(others.map(\.pid))).sorted().map(describe))
        if !own.isEmpty {
            return .refused(.notOnlyYours(
                reason: "DevDeck: `\(first.segment)` would also stop \(names), so nothing in this command was run."
                    + " To stop only your own processes, run: kill \(Array(Set(own)).sorted().map(String.init).joined(separator: " ")).",
                segment: first.segment))
        }
        if let shared { return .needsOK(shared, wait: nil) }
        return .needsOK(LeaseBook.Approval(segment: first.segment, effect: "stops \(names)"), wait: Self.killWait)
    }

    /// The processes a kill stops that DevDeck judges: dev servers and builds for a pid or
    /// port, everything a pattern matches (except the agent and its ancestors, which
    /// `pkill` skips).
    private func targets(of kill: CommandGuard.Kill, agentPID: Int32?) -> [Int32] {
        switch kill.target {
        case .pid(let pid):
            return servers.contains { $0.pid == pid } || builds.contains { $0.pid == pid } ? [pid] : []
        case .port(let port):
            return servers.filter { $0.ports.contains(port) }.map(\.pid)
        case .processes(let pattern):
            var excluded: Set<Int32> = []
            var walker = agentPID
            while let pid = walker, pid > 1, excluded.insert(pid).inserted { walker = processes[pid]?.ppid }
            return pattern.matches(in: processes, excluding: excluded).map(\.pid)
        }
    }

    /// The session a process belongs to: DevDeck saw the session start it or one of its
    /// ancestors, or it runs under a live agent's process. The environment isn't asked, since
    /// daemons that serve every agent (adb, Gradle, argent's tool server) carry the session
    /// that happened to start them.
    private func owner(of pid: Int32) -> AgentSession? {
        var walker: Int32? = pid
        var seen: Set<Int32> = []
        while let current = walker, current > 1, seen.insert(current).inserted {
            if let owner = owners[current] ?? agents[current] { return owner }
            walker = processes[current]?.ppid
        }
        return nil
    }

    /// "maps-app's Metro on :8081 (Codex · maps-app started it)", "node (pid 4121, you or another app started it)"
    private func describe(_ pid: Int32) -> String {
        let starter = owner(of: pid).map { "\($0.label) started it" } ?? "you or another app started it"
        if let server = servers.first(where: { $0.pid == pid }) {
            return "\(server.project.name)'s \(server.kind) on :\(server.portList) (\(starter))"
        }
        if let build = builds.first(where: { $0.pid == pid }) {
            return "\(build.project ?? "another project")'s \(build.kind) (\(starter))"
        }
        return "\(processes[pid]?.name ?? "process") (pid \(pid), \(starter))"
    }

    /// "a, b and 3 more"
    private static func list(_ names: [String]) -> String {
        let shown = names.count > 3 ? Array(names.prefix(2)) + ["\(names.count - 2) more"] : names
        guard shown.count > 1 else { return shown.first ?? "" }
        return shown.dropLast().joined(separator: ", ") + " and " + shown.last!
    }

    /// "Test iPhone is locked: unlock it" when a physical device the call needs can't be used
    /// until the user steps in. A locked phone only holds calls that need it awake.
    static func needsUser(_ waiter: LeaseBook.Waiter, devices: DeviceIndex) -> String? {
        let installs = waiter.pools.contains(.build) || waiter.action.contains("install")
        for id in waiter.devices {
            guard let device = devices.device(id), device.kind == .physical, let problem = device.problem,
                  problem.blocksEverything || !installs
            else { continue }
            return problem.waiting(for: device.name)
        }
        return nil
    }

    /// Calls that change which Metro an app loads, so a warning about it never holds them up.
    private static let rewiresApp: Set<String> = [
        "adb reverse", "adb install", "simctl launch", "simctl terminate", "simctl install", "simctl boot", "emulator",
        "launch-app", "restart-app", "reinstall-app", "boot-device", "open-url",
        "stop-simulator-server", "stop-all-simulator-servers",
    ]
}
