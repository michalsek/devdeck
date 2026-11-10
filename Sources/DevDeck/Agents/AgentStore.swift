import Combine
import Darwin
import Foundation
import os

/// Something an agent session started that keeps running on the Mac.
struct OwnedProcess: Identifiable, Hashable {
    enum Kind: Hashable { case devServer, build }

    let pid: Int32
    let started: Date?
    let kind: Kind
    /// "Metro · Expo :8082", "Xcode build", "Gradle daemon"
    var label: String
    /// Memory it and its children use.
    var footprint: UInt64 = 0

    var id: Int32 { pid }
}

/// One agent session as DevDeck has seen it through the hooks: its process, what it's
/// doing, the devices it booted and the processes it started.
struct AgentRecord: Identifiable, Hashable {
    let session: AgentSession
    /// The agent's own process (the hook's parent), and when it started, so a reused pid
    /// isn't taken for it.
    var pid: Int32?
    var pidStarted: Date?
    var firstSeen: Date
    var lastSeen: Date
    var lastAction: String
    var turnEnded: Date?
    /// It sent SessionEnd, or its process is gone.
    var ended: Date?
    /// Simulators and emulators it booted.
    var booted: Set<String> = []
    var processes: [OwnedProcess] = []

    var id: String { session.id }

    enum State: Equatable { case working, idle, ended }

    /// Working until its turn has ended for a while; ended when the session is over.
    func state(now: Date, idleAfter: TimeInterval) -> State {
        if ended != nil { return .ended }
        if let turnEnded, now.timeIntervalSince(max(turnEnded, lastSeen)) >= idleAfter { return .idle }
        return .working
    }
}

/// What it left running: its processes, and the devices it booted that nobody else uses.
struct Leftovers: Equatable {
    var processes: [OwnedProcess] = []
    var devices: [DeviceItem] = []

    var isEmpty: Bool { processes.isEmpty && devices.isEmpty }
    var footprint: UInt64 { processes.reduce(0) { $0 + $1.footprint } }

    /// "Metro · Expo :8082, Pixel 9 and 2 Gradle daemons"
    var summary: String {
        var names = devices.map(\.name)
        var counted: [String: Int] = [:]
        var order: [String] = []
        for process in processes {
            if counted[process.label] == nil { order.append(process.label) }
            counted[process.label, default: 0] += 1
        }
        names += order.map { counted[$0]! == 1 ? $0 : "\(counted[$0]!) \($0)s" }
        guard names.count > 1 else { return names.first ?? "nothing" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}

/// The agent sessions DevDeck has heard from, with what each started, and Clean Up for
/// what a finished session left running.
@MainActor
final class AgentStore: ObservableObject {
    private static let log = Logger(subsystem: "dev.devdeck.app", category: "agents")

    /// A session whose turn ended this long ago counts as idle: done for now.
    static let idleAfter: TimeInterval = 30 * 60
    /// Finished sessions with nothing left running drop off the list after this long.
    static let forgetAfter: TimeInterval = 3600

    @Published private(set) var records: [String: AgentRecord] = [:]
    @Published private(set) var cleaning: Set<String> = []

    private let devices: DeviceStore
    private let servers: ServerStore
    private let monitor: ResourceMonitor
    private let notifier: Notifier
    private let activity: ActivityLog
    private let leases: LeaseStore
    private let claims: ClaimStore
    private var subscription: AnyCancellable?
    private var scanning = false
    /// Sessions the user has been told about.
    private var told: Set<String> = []

    init(
        devices: DeviceStore, servers: ServerStore, monitor: ResourceMonitor, notifier: Notifier, activity: ActivityLog,
        leases: LeaseStore, claims: ClaimStore
    ) {
        self.leases = leases
        self.claims = claims
        self.devices = devices
        self.servers = servers
        self.monitor = monitor
        self.notifier = notifier
        self.activity = activity
        if Demo.isOn {
            records = Demo.agents
            return
        }
        notifier.onCleanUp = { [weak self] id in self?.cleanUp(id) }
        // Each dev server scan (each `Pulse` tick) is a good moment to look at the process tree.
        subscription = servers.$servers.sink { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    var sorted: [AgentRecord] { records.values.sorted { $0.lastSeen > $1.lastSeen } }

    // MARK: From the hooks

    /// The agent made a call DevDeck heard about.
    func note(_ event: HookEvent, session: AgentSession, now: Date) {
        var record = records[session.id] ?? AgentRecord(
            session: session, pid: nil, firstSeen: now, lastSeen: now, lastAction: event.action)
        if let pid = event.agentPID, record.pid != pid {
            record.pid = pid
            record.pidStarted = nil
            // One agent process runs one session at a time: a new one (after /clear, say)
            // carries on with what the previous one started.
            for (id, other) in records where id != session.id && other.pid == pid && other.ended == nil {
                record.processes += other.processes
                record.booted.formUnion(other.booted)
                records[id]?.processes = []
                records[id]?.booted = []
                records[id]?.ended = now
            }
        }
        record.lastSeen = now
        switch event.kind {
        case .toolUse, .deviceInUse, .result:
            record.lastAction = event.action
            record.turnEnded = nil
            record.ended = nil
        case .turnEnd:
            record.turnEnded = now
        case .sessionEnd:
            record.ended = now
        }
        records[session.id] = record
        if event.kind == .sessionEnd { offerCleanUp(session.id) }
    }

    /// Devices a call of the session booted, once it ran.
    func noteBooted(_ devices: [String], by id: String) {
        records[id]?.booted.formUnion(devices)
    }

    /// The session that started each process DevDeck saw started.
    var owners: [Int32: AgentSession] {
        var owners: [Int32: AgentSession] = [:]
        for record in records.values {
            for process in record.processes { owners[process.pid] = record.session }
        }
        return owners
    }

    func forget(_ id: String) {
        records[id] = nil
    }

    // MARK: Leftovers

    func leftovers(of record: AgentRecord) -> Leftovers {
        let running = devices.running
        return Leftovers(
            processes: record.processes,
            devices: running.filter { record.booted.contains($0.id) && !isInUse($0, by: record.session) })
    }

    /// Someone else holds, drives or has claimed the device, so it isn't a leftover to shut down.
    private func isInUse(_ device: DeviceItem, by session: AgentSession) -> Bool {
        if let holder = leases.lease(for: device)?.holder, holder.session?.id != session.id { return true }
        return claims.claims(for: device).contains { claims.owner(of: $0)?.session.id != session.id }
    }

    /// Stops what the session left running: its processes, and the devices it booted that
    /// nobody else is using.
    func cleanUp(_ id: String) {
        guard let record = records[id], !cleaning.contains(id) else { return }
        let left = leftovers(of: record)
        guard !left.isEmpty else { return }
        cleaning.insert(id)
        notifier.clearLeftovers(id)
        Task {
            for process in left.processes {
                _ = await Task.detached { await ServerScanner.stop(process.pid) }.value
            }
            for device in left.devices { devices.stop(device) }
            activity.add(
                .cleanedUp, agent: record.session.label, subject: record.session.project.name,
                "Stopped what the session left running: \(left.summary).", session: id)
            records[id]?.processes.removeAll { process in left.processes.contains { $0.pid == process.pid } }
            records[id]?.booted.subtract(left.devices.map(\.id))
            cleaning.remove(id)
            await servers.refresh()
        }
    }

    /// Stops one process the session started.
    func stop(_ process: OwnedProcess, of id: String) {
        Task {
            _ = await Task.detached { await ServerScanner.stop(process.pid) }.value
            records[id]?.processes.removeAll { $0.pid == process.pid }
            await servers.refresh()
        }
    }

    private func offerCleanUp(_ id: String) {
        guard let record = records[id], !told.contains(id) else { return }
        let left = leftovers(of: record)
        guard !left.isEmpty else { return }
        told.insert(id)
        let memory = left.footprint > 0 ? String(format: " (%.1f GB)", Double(left.footprint) / 1_073_741_824) : ""
        notifier.leftovers(
            id, title: "\(record.session.label) left things running",
            body: "\(left.summary)\(memory). Clean Up stops them; nothing else is touched.")
    }

    // MARK: Scanning

    /// Finds the processes each session started (its process's descendants that are dev
    /// servers, builds, emulators or build daemons), and notices sessions whose process
    /// is gone. Processes stay attributed after their parent exits.
    private func scan() {
        guard !scanning, !records.isEmpty else { return }
        scanning = true
        // Only live sessions start things; an ended one's pid may belong to someone else now.
        let roots = records.filter { $0.value.ended == nil }.compactMapValues(\.pid)
        let agents = Dictionary(roots.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let serverPIDs = Dictionary(servers.devServers.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let buildPIDs = Set(monitor.builds.map(\.pid))
        Task.detached(priority: .utility) {
            let table = ServerScanner.recentProcessTable()
            let found = Self.owned(roots: roots, table: table, servers: serverPIDs, builds: buildPIDs) {
                Self.starter(environment: LibProc.environment($0), agents: agents)
            }
            await MainActor.run { self.apply(found, table: table) }
        }
    }

    /// The session a process was started in, from its environment, which outlives the shell
    /// that started it: DevDeck's `DEVDECK_SESSION` in the Metro it runs for an agent, and
    /// Claude Code's `CLAUDE_PID` (a live agent process, which carries on after `/clear`) or
    /// `CLAUDE_CODE_SESSION_ID`. Subagents share their parent's session.
    nonisolated static func starter(environment: [String: String], agents: [Int32: String]) -> String? {
        if let id = environment[MetroKeeper.sessionVariable] { return id }
        if let pid = environment["CLAUDE_PID"].flatMap(Int32.init), let id = agents[pid] { return id }
        return environment["CLAUDE_CODE_SESSION_ID"].map { AgentKind.claude.rawValue + ":" + $0 }
    }

    private func apply(_ found: [String: Owned], table: [Int32: ServerScanner.ProcessRow]) {
        scanning = false
        let now = Date.now
        for (id, var record) in records {
            // Keep what it started while it's still running (the same process, not a reused pid).
            var processes = record.processes.filter { process in table[process.pid]?.started == process.started }
            record.booted.formUnion(found[id]?.emulators ?? [])
            for process in found[id]?.processes ?? [] {
                if let index = processes.firstIndex(where: { $0.pid == process.pid }) {
                    processes[index].footprint = process.footprint
                    processes[index].label = process.label
                } else {
                    processes.append(process)
                }
            }
            record.processes = processes
            if record.ended == nil, let pid = record.pid {
                if record.pidStarted == nil { record.pidStarted = table[pid]?.started }
                if table[pid] == nil || table[pid]?.started != record.pidStarted {
                    record.ended = now
                    claims.sessionEnded(id, now: now)
                    Self.log.info("\(record.session.label, privacy: .public): process \(pid) is gone")
                }
            }
            if record.ended.map({ now.timeIntervalSince($0) > Self.forgetAfter }) == true, leftovers(of: record).isEmpty {
                records[id] = nil
                continue
            }
            if records[id] != record { records[id] = record }
            if record.ended != nil { offerCleanUp(id) }
        }
    }

    /// What a session's process tree holds: processes to stop, and emulators (as "avd:<name>"),
    /// which are shut down like devices.
    struct Owned: Equatable {
        var processes: [OwnedProcess] = []
        var emulators: Set<String> = []
    }

    /// `starter` names the session a server or build outside every tree was started in: one
    /// started with `nohup … &` loses its parent as soon as the shell exits.
    nonisolated static func owned(
        roots: [String: Int32], table: [Int32: ServerScanner.ProcessRow], servers: [Int32: DevServer], builds: Set<Int32>,
        starter: (Int32) -> String?
    ) -> [String: Owned] {
        var children: [Int32: [Int32]] = [:]
        for row in table.values { children[row.ppid, default: []].append(row.pid) }
        var result: [String: Owned] = [:]
        for (id, root) in roots {
            var queue = children[root] ?? []
            var seen: Set<Int32> = []
            while let pid = queue.popLast() {
                guard seen.insert(pid).inserted, let row = table[pid] else { continue }
                if let avd = emulatorAVD(row) {
                    result[id, default: Owned()].emulators.insert(DeviceItem.avdID(avd))
                    continue
                }
                if let process = classify(row, servers: servers, builds: builds) {
                    var process = process
                    process.footprint = footprint(of: pid, children: children)
                    result[id, default: Owned()].processes.append(process)
                    // Its own children are part of it.
                    continue
                }
                queue += children[pid] ?? []
            }
        }
        let inTrees = Set(result.values.flatMap { $0.processes.map(\.pid) })
        for pid in Set(servers.keys).union(builds).subtracting(inTrees) {
            guard let row = table[pid], let id = starter(pid), var process = classify(row, servers: servers, builds: builds)
            else { continue }
            process.footprint = footprint(of: pid, children: children)
            result[id, default: Owned()].processes.append(process)
        }
        return result
    }

    nonisolated static func classify(
        _ row: ServerScanner.ProcessRow, servers: [Int32: DevServer], builds: Set<Int32>
    ) -> OwnedProcess? {
        if let server = servers[row.pid] {
            return OwnedProcess(pid: row.pid, started: row.started, kind: .devServer, label: "\(server.kind) :\(server.portList)")
        }
        if builds.contains(row.pid), let kind = ResourceMonitor.buildKind(row) {
            return OwnedProcess(pid: row.pid, started: row.started, kind: .build, label: kind)
        }
        return nil
    }

    /// The AVD an Android emulator process runs: `qemu-system-aarch64 … -avd Pixel_9 …`.
    nonisolated static func emulatorAVD(_ row: ServerScanner.ProcessRow) -> String? {
        guard row.executable.hasPrefix("qemu-system") || row.executable == "emulator" else { return nil }
        let words = row.command.split(separator: " ")
        guard let index = words.firstIndex(of: "-avd"), index + 1 < words.count else { return nil }
        return String(words[index + 1])
    }

    nonisolated private static func footprint(of pid: Int32, children: [Int32: [Int32]]) -> UInt64 {
        var total: UInt64 = 0
        var queue = [pid]
        var seen: Set<Int32> = []
        while let next = queue.popLast() {
            guard seen.insert(next).inserted else { continue }
            total += ResourceMonitor.footprint(next)
            queue += children[next] ?? []
        }
        return total
    }
}
