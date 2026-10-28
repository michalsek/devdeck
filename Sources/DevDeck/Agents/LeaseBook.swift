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

/// Who holds which device, who waits for it, and the rules between them. No side effects:
/// `LeaseStore` feeds it events and carries out the `Effects` it returns.
///
/// - An agent that acts on a device leases it. The lease ends when the agent has been idle
///   on it for `Timing.agentIdle`, its session ends, or the device stops.
/// - The user comes first. They can hold a device; agent calls on it wait until the hold
///   ends. They can queue for a device an agent leases; it becomes theirs when that agent
///   is done (turn or session ended, or idle).
/// - Agents wait for each other: another session's call on a leased device waits until the
///   lease is free to hand over (the holder's turn ended, or it's been idle for
///   `Timing.handoff`). If a free device of the same kind is running, the call is turned
///   away at once with that device's name instead of waiting.
/// - Subagents share their parent's session, so they never wait for each other.
/// - Heavy work (device boots, native builds, dev servers) also waits for room: each
///   `Pool` has a limit, and nothing new starts while memory is low. A call let through
///   reserves its room for a minute, until its process shows up in `Resources.usage`.
struct LeaseBook {
    enum Holder: Hashable {
        case agent(AgentSession)
        case user

        var session: AgentSession? {
            if case .agent(let session) = self { return session }
            return nil
        }
    }

    struct Lease: Identifiable, Hashable {
        let deviceID: String
        let holder: Holder
        let since: Date
        var lastAction: Date
        var lastActionName: String
        /// The agent finished its turn and hasn't acted on the device since.
        var turnEnded = false

        var id: String { deviceID }
        var isUser: Bool { holder == .user }
    }

    /// An agent call waiting for a device.
    struct Waiter: Identifiable, Hashable {
        let id: UUID
        let session: AgentSession
        let action: String
        let devices: [String]
        let releases: [String]
        let since: Date
        let deadline: Date
        /// Heavy work the call starts.
        var pools: [Pool] = []

        var touched: [String] { devices + releases }
    }

    /// What's running on the Mac and how much is allowed, from `LeaseStore`.
    struct Resources: Equatable {
        var usage: [Pool: Int] = [:]
        var limits: [Pool: Int] = [:]
        /// Free memory is below the user's threshold: start nothing heavy.
        var memoryLow = false
    }

    struct Reservation: Hashable {
        let pool: Pool
        let until: Date
    }

    struct Timing {
        /// An agent's lease ends after this long without a call.
        var agentIdle: TimeInterval = 10 * 60
        /// Another agent may take a lease whose holder has been idle this long.
        var handoff: TimeInterval = 2 * 60
    }

    enum Decision: Equatable {
        case allow
        case wait
        /// Turned away at once: the devices are busy, these free ones can be used instead.
        case redirect([String])
    }

    enum DenyReason: Equatable { case timedOut, dismissed }

    struct Denial: Equatable {
        let waiter: UUID
        let reason: DenyReason
    }

    /// What `LeaseStore` has to do after a change.
    struct Effects: Equatable {
        /// Waiting calls that may run now.
        var allowed: [UUID] = []
        /// Waiting calls that are turned away.
        var denied: [Denial] = []
        /// Devices that just became the user's because they queued for them.
        var handedToUser: [String] = []

        var isEmpty: Bool { allowed.isEmpty && denied.isEmpty && handedToUser.isEmpty }

        mutating func merge(_ other: Effects) {
            allowed += other.allowed
            denied += other.denied
            handedToUser += other.handedToUser
        }
    }

    var timing = Timing()
    var resources = Resources()
    private(set) var reservations: [Reservation] = []
    private(set) var leases: [String: Lease] = [:]
    /// Devices the user is queued for.
    private(set) var queue: Set<String> = []
    /// Waiting agent calls, in the order they'll be let through.
    private(set) var waiters: [Waiter] = []

    func isHeldByUser(_ device: String) -> Bool { leases[device]?.isUser == true }

    func waiters(for device: String) -> [Waiter] { waiters.filter { $0.touched.contains(device) } }

    /// Whether `session` has to wait for `device` at `now`.
    func isBlocked(_ device: String, for session: AgentSession, now: Date) -> Bool {
        guard let lease = leases[device] else { return false }
        switch lease.holder {
        case .user:
            return true
        case .agent(let holder):
            if holder.id == session.id { return false }
            // The user is next in line for it.
            if queue.contains(device) { return true }
            return !isFreeToHandOver(lease, now: now)
        }
    }

    /// Running plus reserved work in `pool`.
    func used(_ pool: Pool, now: Date) -> Int {
        resources.usage[pool, default: 0] + reservations.filter { $0.pool == pool && $0.until > now }.count
    }

    func isFull(_ pool: Pool, now: Date) -> Bool {
        used(pool, now: now) >= resources.limits[pool, default: Int.max]
    }

    /// The call starts heavy work and there's no room for it now.
    func needsRoom(_ waiter: Waiter, now: Date) -> Bool {
        !waiter.pools.isEmpty && (resources.memoryLow || waiter.pools.contains { isFull($0, now: now) })
    }

    /// An agent lease another agent may take: its turn ended, or it's been idle a while.
    func isFreeToHandOver(_ lease: Lease, now: Date) -> Bool {
        lease.turnEnded || now.timeIntervalSince(lease.lastAction) >= timing.handoff
    }

    // MARK: Agents

    /// An agent call on `waiter.devices` (and done with `waiter.releases`).
    /// `alternatives` lists, per device, other running devices of the same kind.
    mutating func request(_ waiter: Waiter, alternatives: [String: [String]] = [:], now: Date) -> Decision {
        let blocked = waiter.touched.filter { isBlocked($0, for: waiter.session, now: now) }
        if blocked.isEmpty {
            if needsRoom(waiter, now: now) {
                waiters.append(waiter)
                return .wait
            }
            apply(waiter, now: now)
            return .allow
        }
        // Busy only because of other agents, and there's somewhere else to go: say so now.
        if !blocked.contains(where: { isHeldByUser($0) }) {
            var free: [String] = []
            for device in blocked.flatMap({ alternatives[$0] ?? [] })
            where !free.contains(device) && !isBlocked(device, for: waiter.session, now: now) {
                free.append(device)
            }
            if !free.isEmpty { return .redirect(free) }
        }
        waiters.append(waiter)
        return .wait
    }

    /// The hook gave up waiting (the agent was interrupted).
    mutating func cancel(_ waiter: UUID) {
        waiters.removeAll { $0.id == waiter }
    }

    mutating func endSession(_ sessionID: String, now: Date) -> Effects {
        waiters.removeAll { $0.session.id == sessionID }
        var effects = Effects()
        for (device, lease) in leases where lease.holder.session?.id == sessionID {
            endAgentLease(device, now: now, effects: &effects)
        }
        effects.merge(admitWaiters(now: now))
        return effects
    }

    /// The agent finished its turn: devices the user queued for go to the user now, and
    /// the others may be taken by waiting agents.
    mutating func agentStopped(_ sessionID: String, now: Date) -> Effects {
        var effects = Effects()
        for (device, lease) in leases where lease.holder.session?.id == sessionID {
            if queue.contains(device) {
                endAgentLease(device, now: now, effects: &effects)
            } else {
                leases[device]?.turnEnded = true
            }
        }
        effects.merge(admitWaiters(now: now))
        return effects
    }

    // MARK: The user

    /// Holds a device now, taking it from any agent. Waiting agents keep waiting.
    mutating func hold(_ device: String, now: Date) {
        queue.remove(device)
        leases[device] = Lease(deviceID: device, holder: .user, since: now, lastAction: now, lastActionName: "held")
    }

    /// Queues for a device an agent is using, or holds it right away if no agent is.
    mutating func joinQueue(_ device: String, now: Date) {
        if let lease = leases[device], lease.holder.session != nil {
            // An agent that's done anyway hands over now.
            if isFreeToHandOver(lease, now: now) {
                hold(device, now: now)
            } else {
                queue.insert(device)
            }
        } else if !isHeldByUser(device) {
            hold(device, now: now)
        }
    }

    mutating func leaveQueue(_ device: String) {
        queue.remove(device)
    }

    /// Ends the user's hold (or their place in the queue) and lets waiting agents through.
    mutating func release(_ device: String, now: Date) -> Effects {
        queue.remove(device)
        if isHeldByUser(device) { leases[device] = nil }
        return admitWaiters(now: now)
    }

    /// Drops whatever is known about a device, e.g. an agent lease that is clearly over.
    mutating func forget(_ device: String, now: Date) -> Effects {
        leases[device] = nil
        queue.remove(device)
        return admitWaiters(now: now)
    }

    /// Lets this waiting call go next among those waiting for the same devices.
    mutating func moveToFront(_ waiter: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiter }) else { return }
        waiters.insert(waiters.remove(at: index), at: 0)
    }

    /// Lets a waiting call through now, whatever it's waiting for.
    mutating func forceAllow(_ waiter: UUID, now: Date) -> Effects {
        guard let found = waiters.first(where: { $0.id == waiter }) else { return Effects() }
        waiters.removeAll { $0.id == waiter }
        apply(found, now: now)
        return Effects(allowed: [waiter])
    }

    /// Turns a waiting call away now.
    mutating func dismiss(_ waiter: UUID) -> Effects {
        guard waiters.contains(where: { $0.id == waiter }) else { return Effects() }
        waiters.removeAll { $0.id == waiter }
        return Effects(denied: [Denial(waiter: waiter, reason: .dismissed)])
    }

    // MARK: Time

    /// - `running`: devices that are still running (leases on others end).
    /// - `userAway`: how long the user hasn't touched the Mac; with `userHoldTimeout`
    ///   set, longer than that ends their holds.
    mutating func tick(
        now: Date, running: Set<String>, userAway: TimeInterval, userHoldTimeout: TimeInterval?
    ) -> Effects {
        var effects = Effects()
        for (device, lease) in leases {
            if !running.contains(device) {
                leases[device] = nil
                queue.remove(device)
            } else if lease.isUser {
                if let userHoldTimeout, userAway >= userHoldTimeout { leases[device] = nil }
            } else if now.timeIntervalSince(lease.lastAction) >= timing.agentIdle {
                endAgentLease(device, now: now, effects: &effects)
            } else if queue.contains(device), isFreeToHandOver(lease, now: now) {
                // The user is next and the agent has gone quiet: no need to wait the full idle time.
                endAgentLease(device, now: now, effects: &effects)
            }
        }
        queue = queue.filter(running.contains)
        reservations.removeAll { $0.until <= now }
        let expired = waiters.filter { $0.deadline <= now }
        waiters.removeAll { $0.deadline <= now }
        effects.denied += expired.map { Denial(waiter: $0.id, reason: .timedOut) }
        effects.merge(admitWaiters(now: now))
        return effects
    }

    // MARK: Internals

    private mutating func apply(_ waiter: Waiter, now: Date) {
        reservations += waiter.pools.map { Reservation(pool: $0, until: now.addingTimeInterval(60)) }
        for device in waiter.releases {
            leases[device] = nil
            queue.remove(device)
        }
        for device in waiter.devices {
            if var lease = leases[device], lease.holder.session?.id == waiter.session.id {
                lease.lastAction = now
                lease.lastActionName = waiter.action
                lease.turnEnded = false
                leases[device] = lease
            } else {
                leases[device] = Lease(
                    deviceID: device, holder: .agent(waiter.session), since: now, lastAction: now,
                    lastActionName: waiter.action)
            }
        }
    }

    private mutating func endAgentLease(_ device: String, now: Date, effects: inout Effects) {
        leases[device] = nil
        if queue.remove(device) != nil {
            hold(device, now: now)
            effects.handedToUser.append(device)
        }
    }

    /// Lets waiting calls through in order. A call that gets through leases its devices,
    /// so the next one waiting for the same device keeps waiting.
    private mutating func admitWaiters(now: Date) -> Effects {
        var effects = Effects()
        for waiter in waiters
        where !waiter.touched.contains(where: { isBlocked($0, for: waiter.session, now: now) })
            && !needsRoom(waiter, now: now) {
            waiters.removeAll { $0.id == waiter.id }
            apply(waiter, now: now)
            effects.allowed.append(waiter.id)
        }
        return effects
    }
}
