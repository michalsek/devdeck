import Combine
import DevDeckProtocol
import Foundation
import os

/// Who holds which device and who waits: runs the `LeaseBook` for agent calls the
/// `Broker` hands it and for what the user does, answers waiting calls when their turn
/// comes, and tells the user (notifications, the activity log) what happened.
@MainActor
final class LeaseStore: ObservableObject {
    typealias Lease = LeaseBook.Lease
    private static let log = Logger(subsystem: "dev.devdeck.app", category: "broker")

    @Published private(set) var book = LeaseBook()
    /// Agent calls as they run, at once or after waiting.
    let ran = PassthroughSubject<LeaseBook.Waiter, Never>()

    private let devices: DeviceStore
    private let settings: AppSettings
    private let servers: ServerStore
    private let monitor: ResourceMonitor
    private let claims: ClaimStore
    private let notifier: Notifier
    private let activity: ActivityLog
    private var timer: Timer?
    private var subscription: AnyCancellable?
    /// Hook connections of waiting calls, and the calls themselves (for the reason when
    /// one is turned away; the book forgets them by then).
    private var connections: [UUID: BrokerConnection] = [:]
    private var pending: [UUID: LeaseBook.Waiter] = [:]
    /// Waiting calls the user has been told about.
    private var notified: Set<UUID> = []
    /// Why each waiting call started waiting, for the log once it's over.
    private var waitReasons: [UUID: String] = [:]

    init(
        devices: DeviceStore, settings: AppSettings, servers: ServerStore, monitor: ResourceMonitor,
        claims: ClaimStore, notifier: Notifier, activity: ActivityLog
    ) {
        self.devices = devices
        self.settings = settings
        self.servers = servers
        self.monitor = monitor
        self.claims = claims
        self.notifier = notifier
        self.activity = activity
        if Demo.isOn {
            book = Demo.book()
            return
        }
        notifier.onAction = { [weak self] action, id in
            guard let self, let waiter = book.waiters.first(where: { $0.id == id }) else { return }
            switch action {
            case .letThrough: runNow(waiter)
            case .turnAway: dismiss(waiter)
            }
        }
        notifier.onReleaseClaim = { [weak self] session in
            guard let self, let status = claims.claims.first(where: { $0.claim.session == session }) else { return }
            releaseClaim(status)
        }
        // An emulator is listed by its adb serial until its AVD name is known; what was
        // taken under the serial moves to the new id.
        subscription = devices.$devices.sink { [weak self] list in
            guard let self else { return }
            for device in list {
                guard let serial = device.serial, serial != device.id,
                      book.leases[serial] != nil || book.queue.contains(serial) || !book.waiters(for: serial).isEmpty
                else { continue }
                book.rekey(serial, to: device.id)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: Reading

    func lease(for device: DeviceItem) -> Lease? { book.leases[device.id] }

    func isQueued(for device: DeviceItem) -> Bool { book.queue.contains(device.id) }

    func waiters(for device: DeviceItem) -> [LeaseBook.Waiter] { book.waiters(for: device.id) }

    var waiting: Int { book.waiters.count }

    /// Waiting calls that are waiting for room on the Mac rather than for a device.
    var waitingForRoom: [LeaseBook.Waiter] { book.waiters.filter(text(now: .now).waitsForRoom) }

    // MARK: The user

    /// Takes the device now; agent calls on it wait until it's released.
    func hold(_ device: DeviceItem) {
        let agent = lease(for: device)?.holder.session
        book.hold(device.id, now: .now)
        activity.add(.user, subject: device.name, agent.map { "You took it over from \($0.label)." } ?? "You held it.")
    }

    func joinQueue(_ device: DeviceItem) {
        book.joinQueue(device.id, now: .now)
        activity.add(.user, subject: device.name, isQueued(for: device) ? "You joined the queue." : "You held it.")
    }

    func leaveQueue(_ device: DeviceItem) {
        book.leaveQueue(device.id)
        activity.add(.user, subject: device.name, "You left the queue.")
    }

    func release(_ device: DeviceItem) {
        activity.add(.user, subject: device.name, "You released it.")
        carryOut(book.release(device.id, now: .now))
    }

    /// Clears an agent's lease that's clearly over.
    func forget(_ device: DeviceItem) {
        let agent = lease(for: device)?.holder.session?.label
        activity.add(.user, agent: agent, subject: device.name, "You told DevDeck the agent is done with it.")
        carryOut(book.forget(device.id, now: .now))
    }

    /// Closes the agent-device session that holds a claim, which frees the device.
    func releaseClaim(_ status: ClaimStatus) {
        notifier.clearClaim(session: status.claim.session)
        activity.add(
            .claimReleased, agent: claims.owner(of: status)?.session.label, subject: status.claim.deviceName,
            "You released agent-device session \(status.claim.session) (\(status.claim.project)).")
        claims.release(status)
    }

    /// Lets a waiting agent call go next.
    func moveToFront(_ waiter: LeaseBook.Waiter) {
        book.moveToFront(waiter.id)
    }

    /// Lets a waiting agent call through now, whatever it's waiting for.
    func runNow(_ waiter: LeaseBook.Waiter) {
        let text = text(now: .now)
        activity.add(
            .letThrough, agent: waiter.session.label, subject: text.describe(waiter),
            "You let it through after \(Format.age(since: waiter.since)): \(text.waitReason(waiter)).",
            session: waiter.session.id)
        waitReasons[waiter.id] = nil
        carryOut(book.forceAllow(waiter.id, now: .now))
    }

    /// Turns a waiting agent call away now; the agent is told the device is in use.
    func dismiss(_ waiter: LeaseBook.Waiter) {
        carryOut(book.dismiss(waiter.id))
    }

    // MARK: Agent calls

    /// Whether heavy work the call starts fits now.
    func hasRoom(for waiter: LeaseBook.Waiter) -> Bool {
        updateResources()
        return !book.needsRoom(waiter, now: .now)
    }

    /// An agent's call: lets it run, turns it away, or keeps the connection until its turn.
    func submit(_ waiter: LeaseBook.Waiter, connection: BrokerConnection, now: Date) {
        updateResources()
        let index = devices.index
        let decision = book.request(
            waiter, alternatives: index.alternatives(for: waiter.touched),
            running: index.runningOfKind(booting: waiter.pools, except: waiter.devices), now: now)
        let session = waiter.session
        Self.log.info("\(session.label, privacy: .public) \(waiter.action, privacy: .public) \(waiter.devices, privacy: .public) \(waiter.pools.map(\.rawValue), privacy: .public) → \(String(describing: decision), privacy: .public)")
        let text = text(now: now)
        switch decision {
        case .allow:
            ran.send(waiter)
            connection.respond(.allow)
        case .redirect(let free):
            let reason = text.redirectReason(waiter, free: free)
            activity.add(.redirected, agent: session.label, subject: text.describe(waiter), reason, session: session.id)
            connection.respond(.deny(reason))
        case .useRunning(let free):
            let reason = text.useRunningReason(waiter, free: free)
            activity.add(.redirected, agent: session.label, subject: text.describe(waiter), reason, session: session.id)
            connection.respond(.deny(reason))
        case .wait:
            waitReasons[waiter.id] = text.waitReason(waiter)
            if let needs = waiter.needsUser {
                activity.add(.needsUser, agent: session.label, subject: waiter.action, "Waits for you: \(needs).", session: session.id)
                notifier.waiting(
                    waiter.id, title: "\(session.label) is waiting for you",
                    body: "\(needs). The agent carries on once it's done.", page: .devices)
                notified.insert(waiter.id)
            } else if let approval = waiter.approval {
                activity.add(
                    .guarded, agent: session.label, subject: waiter.action, "Waits for your OK: it \(approval).",
                    session: session.id)
                notifier.waiting(
                    waiter.id, title: "\(session.label) needs your OK", body: "\"\(waiter.action)\" \(approval).",
                    page: .agents)
                notified.insert(waiter.id)
            }
            connections[waiter.id] = connection
            pending[waiter.id] = waiter
            connection.onHangup { [weak self] in
                Task { @MainActor in self?.hungUp(waiter.id) }
            }
        }
    }

    func sessionEnded(_ sessionID: String, now: Date) {
        carryOut(book.endSession(sessionID, now: now))
    }

    func turnEnded(_ sessionID: String, now: Date) {
        carryOut(book.agentStopped(sessionID, now: now))
    }

    private func hungUp(_ waiter: UUID) {
        connections[waiter] = nil
        pending[waiter] = nil
        waitReasons[waiter] = nil
        notified.remove(waiter)
        notifier.clear(waiter)
        book.cancel(waiter)
    }

    private func text(now: Date) -> AgentText {
        AgentText(book: book, devices: devices.index, memoryProblem: monitor.memoryProblem, now: now)
    }

    // MARK: Time

    /// What's running against the limits, for the book's room checks.
    private func updateResources() {
        book.resources = LeaseBook.Resources(
            usage: [
                .iosSimulator: devices.running.filter { $0.kind == .simulator }.count,
                .androidEmulator: devices.running.filter { $0.kind == .emulator }.count,
                .build: monitor.builds.count,
                .devServer: servers.devServers.count,
            ],
            limits: monitor.limits,
            memoryLow: monitor.memoryLow)
    }

    private func tick() {
        guard devices.loaded else { return }
        updateResources()
        let minutes = settings.holdReleaseMinutes
        carryOut(book.tick(
            now: .now, running: Set(devices.running.map(\.id)), userAway: UserActivity.secondsSinceInput(),
            userHoldTimeout: minutes > 0 ? TimeInterval(minutes * 60) : nil))
        let index = devices.index
        let neededUser = Set(book.waiters.filter { $0.needsUser != nil }.map(\.id))
        carryOut(book.recheckNeeds(now: .now) { CallPolicy.needsUser($0, devices: index) })
        // A call that also needs the user's OK says so once the device is sorted.
        for waiter in book.waiters where neededUser.contains(waiter.id) && waiter.needsUser == nil {
            guard let approval = waiter.approval else { continue }
            notifier.waiting(
                waiter.id, title: "\(waiter.session.label) needs your OK", body: "\"\(waiter.action)\" \(approval).",
                page: .agents)
        }
        notifyWaiting()
    }

    /// Tells the user about calls that have waited a few seconds (quick hand-offs aren't news).
    private func notifyWaiting() {
        guard settings.notifyWaits else { return }
        let text = text(now: .now)
        for waiter in book.waiters where !notified.contains(waiter.id) && Date.now.timeIntervalSince(waiter.since) >= 3 {
            notified.insert(waiter.id)
            notifier.waiting(
                waiter.id, title: "\(waiter.session.label) is waiting",
                body: "\(text.describe(waiter)): \(text.waitReason(waiter)).", page: page(for: waiter, text))
        }
    }

    private func page(for waiter: LeaseBook.Waiter, _ text: AgentText) -> DashboardPage {
        text.waitsForRoom(waiter) ? .resources : .leases
    }

    // MARK: Effects

    private func carryOut(_ effects: LeaseBook.Effects) {
        let text = text(now: .now)
        for id in effects.allowed {
            if let waiter = pending.removeValue(forKey: id) {
                ran.send(waiter)
                if let reason = waitReasons[id] {
                    activity.add(
                        .ranAfterWait, agent: waiter.session.label, subject: text.describe(waiter),
                        "Ran after waiting \(Format.age(since: waiter.since)): \(reason).", session: waiter.session.id)
                }
            }
            waitReasons[id] = nil
            if notified.remove(id) != nil { notifier.clear(id) }
            connections.removeValue(forKey: id)?.respond(.allow)
        }
        for denial in effects.denied {
            let waiter = pending.removeValue(forKey: denial.waiter)
            if notified.remove(denial.waiter) != nil {
                if denial.reason == .timedOut, let waiter {
                    notifier.gaveUp(
                        denial.waiter, title: "\(waiter.session.label) stopped waiting",
                        body: "\(text.describe(waiter)) wasn't run: \(text.waitReason(waiter)). The agent was told why.",
                        page: page(for: waiter, text))
                } else {
                    notifier.clear(denial.waiter)
                }
            }
            let reason = text.denyReason(waiter, denial.reason)
            waitReasons[denial.waiter] = nil
            if denial.reason == .sessionEnded {
                connections.removeValue(forKey: denial.waiter)?.respond(.deny(reason))
                continue
            }
            activity.add(
                .turnedAway, agent: waiter?.session.label, subject: waiter.map(text.describe),
                (denial.reason == .dismissed ? "You turned it away. " : "It waited too long. ") + "The agent read: " + reason,
                session: waiter?.session.id)
            connections.removeValue(forKey: denial.waiter)?.respond(.deny(reason))
        }
        for device in effects.handedToUser {
            activity.add(.user, subject: text.devices.name(of: device), "The agent was done with it, so it's yours now.")
            notifier.plain(
                "handover-\(device)", title: "\(text.devices.name(of: device)) is yours",
                body: "The agent is done with it. Agents wait until you release it in DevDeck.", page: .leases)
        }
    }
}
