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
/// - An agent that acts on a device leases it; the lease ends when the agent has been idle
///   on it for a while, its session ends, or the device stops. Agents don't wait for each
///   other (yet): the most recent one takes the lease.
/// - The user can hold a device. Agent calls on a held device wait until the hold ends.
/// - The user can queue for a device an agent leases; it becomes theirs when that lease
///   ends or the agent's turn ends.
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

        var id: String { deviceID }
        var isUser: Bool { holder == .user }
    }

    /// An agent call waiting for the user to let go of a device.
    struct Waiter: Identifiable, Hashable {
        let id: UUID
        let session: AgentSession
        let action: String
        let devices: [String]
        let releases: [String]
        let since: Date
        let deadline: Date

        var touched: [String] { devices + releases }
    }

    enum Decision: Equatable { case allow, wait }

    /// What `LeaseStore` has to do after a change.
    struct Effects: Equatable {
        /// Waiting calls that may run now.
        var allowed: [UUID] = []
        /// Waiting calls that gave up.
        var denied: [UUID] = []
        /// Devices that just became the user's because they queued for them.
        var handedToUser: [String] = []

        var isEmpty: Bool { allowed.isEmpty && denied.isEmpty && handedToUser.isEmpty }
    }

    private(set) var leases: [String: Lease] = [:]
    /// Devices the user is queued for.
    private(set) var queue: Set<String> = []
    /// Waiting agent calls, oldest first.
    private(set) var waiters: [Waiter] = []

    func isHeldByUser(_ device: String) -> Bool { leases[device]?.isUser == true }

    func waiters(for device: String) -> [Waiter] { waiters.filter { $0.touched.contains(device) } }

    // MARK: Agents

    /// An agent call on `waiter.devices` (and done with `waiter.releases`). Runs now unless
    /// one of them is held by the user.
    mutating func request(_ waiter: Waiter, now: Date) -> (Decision, Effects) {
        if waiter.touched.contains(where: { isHeldByUser($0) }) {
            waiters.append(waiter)
            return (.wait, Effects())
        }
        apply(waiter, now: now)
        return (.allow, Effects())
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
        return effects
    }

    /// The agent finished its turn: devices the user queued for are handed over now
    /// rather than after the idle timeout.
    mutating func agentStopped(_ sessionID: String, now: Date) -> Effects {
        var effects = Effects()
        for (device, lease) in leases where lease.holder.session?.id == sessionID && queue.contains(device) {
            endAgentLease(device, now: now, effects: &effects)
        }
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
        if leases[device]?.holder.session != nil {
            queue.insert(device)
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

    // MARK: Time

    /// - `running`: devices that are still running (leases on others end).
    /// - `agentIdle`: how long an agent lease lasts without a call.
    /// - `userAway`: how long the user hasn't touched the Mac; with `userHoldTimeout`
    ///   set, longer than that ends their holds.
    mutating func tick(
        now: Date, running: Set<String>, agentIdle: TimeInterval,
        userAway: TimeInterval, userHoldTimeout: TimeInterval?
    ) -> Effects {
        var effects = Effects()
        for (device, lease) in leases {
            if !running.contains(device) {
                leases[device] = nil
                queue.remove(device)
            } else if lease.isUser {
                if let userHoldTimeout, userAway >= userHoldTimeout { leases[device] = nil }
            } else if now.timeIntervalSince(lease.lastAction) >= agentIdle {
                endAgentLease(device, now: now, effects: &effects)
            }
        }
        queue = queue.filter(running.contains)
        let expired = waiters.filter { $0.deadline <= now }
        waiters.removeAll { $0.deadline <= now }
        effects.denied += expired.map(\.id)
        let admitted = admitWaiters(now: now)
        effects.allowed += admitted.allowed
        return effects
    }

    // MARK: Internals

    private mutating func apply(_ waiter: Waiter, now: Date) {
        for device in waiter.releases {
            leases[device] = nil
            queue.remove(device)
        }
        for device in waiter.devices {
            if var lease = leases[device], lease.holder.session?.id == waiter.session.id {
                lease.lastAction = now
                lease.lastActionName = waiter.action
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

    /// Lets through, oldest first, the waiting calls whose devices are no longer held.
    private mutating func admitWaiters(now: Date) -> Effects {
        var effects = Effects()
        for waiter in waiters where !waiter.touched.contains(where: { isHeldByUser($0) }) {
            waiters.removeAll { $0.id == waiter.id }
            apply(waiter, now: now)
            effects.allowed.append(waiter.id)
        }
        return effects
    }
}
