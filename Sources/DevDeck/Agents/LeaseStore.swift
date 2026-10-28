import CoreGraphics
import Foundation
import os

/// The broker: receives agent hook calls from `devdeck-hook`, decides with `LeaseBook`
/// whether each may run now or has to wait for the user, and answers the hook.
/// If DevDeck isn't running, hooks don't wait at all.
@MainActor
final class LeaseStore: ObservableObject {
    typealias Lease = LeaseBook.Lease
    private static let log = Logger(subsystem: "dev.devdeck.app", category: "broker")

    /// How long a call may wait when the hook doesn't say (it asks for less than its timeout).
    static let defaultMaxWait: TimeInterval = 9 * 60

    @Published private(set) var book = LeaseBook()
    @Published private(set) var listening = false

    private let devices: DeviceStore
    private let settings: AppSettings
    private let servers: ServerStore
    let monitor: ResourceMonitor
    private var server: BrokerServer?
    private var timer: Timer?
    /// Hook connections of waiting calls, and the calls themselves (for the reason when
    /// one is turned away; the book forgets them by then).
    private var connections: [UUID: BrokerConnection] = [:]
    private var pending: [UUID: LeaseBook.Waiter] = [:]
    /// Waiting calls the user has been told about.
    private var notified: Set<UUID> = []
    let notifier = Notifier()
    /// Opens a dashboard page (a click on a notification).
    var openPage: ((DashboardPage) -> Void)?

    init(devices: DeviceStore, settings: AppSettings, servers: ServerStore, monitor: ResourceMonitor) {
        self.devices = devices
        self.settings = settings
        self.servers = servers
        self.monitor = monitor
        if Demo.isOn {
            book = Demo.book()
            return
        }
        notifier.setUp()
        notifier.onOpen = { [weak self] page in self?.openPage?(page) }
        notifier.onAction = { [weak self] action, id in
            guard let self, let waiter = book.waiters.first(where: { $0.id == id }) else { return }
            switch action {
            case .letThrough: runNow(waiter)
            case .turnAway: dismiss(waiter)
            }
        }
        openSocket()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: Reading

    /// An emulator is listed by its adb serial until its AVD name is known, so a lease
    /// taken in that window is under the serial.
    func lease(for device: DeviceItem) -> Lease? {
        book.leases[device.id] ?? device.serial.flatMap { book.leases[$0] }
    }

    func isQueued(for device: DeviceItem) -> Bool {
        book.queue.contains(device.id) || device.serial.map(book.queue.contains) == true
    }

    func waiters(for device: DeviceItem) -> [LeaseBook.Waiter] {
        book.waiters(for: device.id) + (device.serial.map(book.waiters(for:)) ?? [])
    }

    var heldByUser: Int { book.leases.values.filter(\.isUser).count }
    var waiting: Int { book.waiters.count }

    // MARK: The user

    /// Takes the device now; agent calls on it wait until it's released.
    func hold(_ device: DeviceItem) {
        book.hold(key(for: device), now: .now)
    }

    func joinQueue(_ device: DeviceItem) {
        book.joinQueue(key(for: device), now: .now)
    }

    func leaveQueue(_ device: DeviceItem) {
        book.leaveQueue(key(for: device))
    }

    func release(_ device: DeviceItem) {
        var effects = book.release(device.id, now: .now)
        if let serial = device.serial { effects.merge(book.release(serial, now: .now)) }
        carryOut(effects)
    }

    /// Clears an agent's lease that's clearly over.
    func forget(_ device: DeviceItem) {
        var effects = book.forget(device.id, now: .now)
        if let serial = device.serial { effects.merge(book.forget(serial, now: .now)) }
        carryOut(effects)
    }

    /// Lets a waiting agent call go next.
    func moveToFront(_ waiter: LeaseBook.Waiter) {
        book.moveToFront(waiter.id)
    }

    /// Lets a waiting agent call through now, whatever it's waiting for.
    func runNow(_ waiter: LeaseBook.Waiter) {
        carryOut(book.forceAllow(waiter.id, now: .now))
    }

    /// Waiting calls that are waiting for room on the Mac rather than for a device.
    var waitingForRoom: [LeaseBook.Waiter] {
        book.waiters.filter { waiter in
            !waiter.pools.isEmpty && !waiter.touched.contains { book.isBlocked($0, for: waiter.session, now: .now) }
        }
    }

    /// Turns a waiting agent call away now; the agent is told the device is in use.
    func dismiss(_ waiter: LeaseBook.Waiter) {
        carryOut(book.dismiss(waiter.id))
    }

    /// The key the device's lease is under (an emulator's may still be its serial).
    private func key(for device: DeviceItem) -> String {
        if book.leases[device.id] == nil, let serial = device.serial, book.leases[serial] != nil { return serial }
        return device.id
    }

    // MARK: Hook calls

    private func receive(_ data: Data, _ connection: BrokerConnection) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return connection.respond(["decision": "allow"])
        }
        if let command = json["command"] as? String {
            return connection.respond(run(command, device: json["device"] as? String, waiter: json["waiter"] as? String))
        }
        guard let event = HookEvent(json: json) else { return connection.respond(["decision": "allow"]) }

        let session = AgentSession(
            agent: event.agent, sessionID: event.sessionID, host: event.host,
            project: ServerScanner.project(for: event.cwd, fallback: event.agent.title))
        let now = Date.now

        switch event.kind {
        case .sessionEnd:
            carryOut(book.endSession(session.id, now: now))
            connection.close()
        case .turnEnd:
            carryOut(book.agentStopped(session.id, now: now))
            connection.close()
        case .toolUse:
            let maxWait = (json["max_wait"] as? Double).map { min($0, Self.defaultMaxWait) } ?? Self.defaultMaxWait
            let targets = event.targets.flatMap(resolve)
            // Booting a device that's already running takes no room.
            let booting = Set<Pool>([.iosSimulator, .androidEmulator])
            let alreadyRunning = !targets.isEmpty && targets.allSatisfy { id in
                devices.running.contains { $0.id == id || $0.serial == id }
            }
            let waiter = LeaseBook.Waiter(
                id: UUID(), session: session, action: event.action,
                devices: targets, releases: event.releases.flatMap(resolve),
                since: now, deadline: now.addingTimeInterval(maxWait),
                pools: event.pools.filter { !(booting.contains($0) && alreadyRunning) })
            updateResources()
            let decision = book.request(
                waiter, alternatives: alternatives(for: waiter.touched), running: runningOfSameKind(booting: waiter), now: now)
            Self.log.info("\(session.label, privacy: .public) \(waiter.action, privacy: .public) \(waiter.devices, privacy: .public) \(waiter.pools.map(\.rawValue), privacy: .public) → \(String(describing: decision), privacy: .public)")
            switch decision {
            case .allow:
                connection.respond(["decision": "allow"])
            case .redirect(let free):
                connection.respond(["decision": "deny", "reason": redirectReason(waiter, free: free)])
            case .useRunning(let free):
                connection.respond(["decision": "deny", "reason": useRunningReason(waiter, free: free)])
            case .wait:
                connections[waiter.id] = connection
                pending[waiter.id] = waiter
                connection.onHangup { [weak self] in
                    Task { @MainActor in self?.hungUp(waiter.id) }
                }
            }
        }
    }

    /// Commands for scripts, e.g. `{"command": "hold", "device": "<udid or serial>"}`:
    /// hold, release, queue, leave; `front` / `dismiss` with `"waiter": "<id>"`; or status.
    private func run(_ command: String, device id: String?, waiter: String?) -> [String: Any] {
        if command == "status" { return status() }
        if let waiter = waiter.flatMap(UUID.init(uuidString:)).flatMap({ id in book.waiters.first { $0.id == id } }) {
            switch command {
            case "front": moveToFront(waiter)
            case "run": runNow(waiter)
            case "dismiss": dismiss(waiter)
            default: return ["ok": false, "error": "unknown command"]
            }
            return status()
        }
        guard let id, let device = devices.devices.first(where: { $0.id == id || $0.serial == id }) else {
            return ["ok": false, "error": "unknown device"]
        }
        switch command {
        case "hold": hold(device)
        case "release": release(device)
        case "queue": joinQueue(device)
        case "leave": leaveQueue(device)
        default: return ["ok": false, "error": "unknown command"]
        }
        return status()
    }

    private func status() -> [String: Any] {
        let leases = book.leases.values.map { lease -> [String: Any] in
            var entry: [String: Any] = ["device": lease.deviceID, "since": lease.since.timeIntervalSince1970]
            switch lease.holder {
            case .agent(let session):
                entry["holder"] = session.label
                entry["turnEnded"] = lease.turnEnded
            case .user: entry["holder"] = "user"
            }
            return entry
        }
        let waiters = book.waiters.map {
            ["id": $0.id.uuidString, "devices": $0.touched, "agent": $0.session.label, "action": $0.action,
             "pools": $0.pools.map(\.rawValue)] as [String: Any]
        }
        updateResources()
        let pools = Pool.allCases.map {
            ["pool": $0.rawValue, "used": book.used($0, now: .now), "limit": book.resources.limits[$0] ?? 0] as [String: Any]
        }
        return [
            "ok": true, "leases": leases, "queue": Array(book.queue), "waiting": waiters, "pools": pools,
            "memoryFree": monitor.snapshot.memoryFree, "memoryLow": monitor.memoryLow,
        ]
    }

    private func hungUp(_ waiter: UUID) {
        connections[waiter] = nil
        pending[waiter] = nil
        notified.remove(waiter)
        notifier.clear(waiter)
        book.cancel(waiter)
    }

    /// For a call that boots a simulator or emulator: the ones of that kind already running.
    private func runningOfSameKind(booting waiter: LeaseBook.Waiter) -> [String] {
        let kind: DeviceItem.Kind
        if waiter.pools.contains(.iosSimulator) {
            kind = .simulator
        } else if waiter.pools.contains(.androidEmulator) {
            kind = .emulator
        } else {
            return []
        }
        return devices.running.filter { $0.kind == kind && !waiter.devices.contains($0.id) }.map(\.id)
    }

    /// Other running simulators or emulators of the same kind and platform, per device.
    private func alternatives(for ids: [String]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for id in ids {
            guard let device = devices.devices.first(where: { $0.id == id || $0.serial == id }),
                  device.kind != .physical
            else { continue }
            result[id] = devices.running
                .filter { $0.kind == device.kind && $0.platform == device.platform && $0.id != device.id }
                .map(\.id)
        }
        return result
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
            return devices.running.filter { $0.kind == .simulator }.map(\.id)
        }
    }

    // MARK: Time

    private func openSocket() {
        server = BrokerServer { [weak self] data, connection in
            Task { @MainActor in self?.receive(data, connection) }
        }
        listening = server != nil
    }

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
        // Something replaced or removed the socket file: open a fresh one.
        if server?.isStale ?? true { openSocket() }
        guard devices.loaded else { return }
        updateResources()
        let running = Set(devices.running.flatMap { [$0.id] + ($0.serial.map { [$0] } ?? []) })
        let minutes = settings.holdReleaseMinutes
        carryOut(book.tick(
            now: .now, running: running, userAway: Self.secondsSinceUserInput(),
            userHoldTimeout: minutes > 0 ? TimeInterval(minutes * 60) : nil))
        notifyWaiting()
    }

    /// Tells the user about calls that have waited a few seconds (quick hand-offs aren't news).
    private func notifyWaiting() {
        guard settings.notifyWaits else { return }
        for waiter in book.waiters where !notified.contains(waiter.id) && Date.now.timeIntervalSince(waiter.since) >= 3 {
            notified.insert(waiter.id)
            notifier.waiting(
                waiter.id, title: "\(waiter.session.label) is waiting",
                body: "\(describe(waiter)): \(waitReason(waiter)).", page: page(for: waiter))
        }
    }

    /// "boot-device on iPhone 18 Pro" or "npx expo run:ios"
    private func describe(_ waiter: LeaseBook.Waiter) -> String {
        waiter.devices.isEmpty ? waiter.action : "\(waiter.action) on \(devicesNamed(waiter))"
    }

    /// Why a call waits: "you're holding iPhone 17", "Codex · web is using Pixel 9", or room.
    private func waitReason(_ waiter: LeaseBook.Waiter) -> String {
        let blocked = waiter.touched.filter { book.isBlocked($0, for: waiter.session, now: .now) }
        guard !blocked.isEmpty else { return roomProblem(waiter) }
        let names = blocked.map(name(of:)).joined(separator: ", ")
        if blocked.contains(where: book.isHeldByUser) { return "you're holding \(names)" }
        if blocked.contains(where: book.queue.contains) { return "you're next in line for \(names)" }
        let agents = blocked.compactMap { book.leases[$0]?.holder.session?.label }
        return "\(agents.first ?? "another agent") is using \(names)"
    }

    private func page(for waiter: LeaseBook.Waiter) -> DashboardPage {
        waiter.touched.contains { book.isBlocked($0, for: waiter.session, now: .now) } ? .leases : .resources
    }

    /// Time since the last keyboard, mouse or trackpad input anywhere on the Mac.
    /// Needs no permission.
    static func secondsSinceUserInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    // MARK: Effects

    private func carryOut(_ effects: LeaseBook.Effects) {
        for id in effects.allowed {
            pending[id] = nil
            if notified.remove(id) != nil { notifier.clear(id) }
            connections.removeValue(forKey: id)?.respond(["decision": "allow"])
        }
        for denial in effects.denied {
            let waiter = pending.removeValue(forKey: denial.waiter)
            if notified.remove(denial.waiter) != nil {
                if denial.reason == .timedOut, let waiter {
                    notifier.gaveUp(
                        denial.waiter, title: "\(waiter.session.label) stopped waiting",
                        body: "\(describe(waiter)) wasn't run: \(waitReason(waiter)). The agent was told why.",
                        page: page(for: waiter))
                } else {
                    notifier.clear(denial.waiter)
                }
            }
            connections.removeValue(forKey: denial.waiter)?.respond([
                "decision": "deny", "reason": denyReason(waiter, denial.reason),
            ])
        }
        for device in effects.handedToUser {
            notifyHandedOver(device)
        }
    }

    private func name(of id: String) -> String {
        devices.devices.first { $0.id == id || $0.serial == id }?.name ?? id
    }

    /// Who's in the way on the devices a call wanted: "the user" or "another agent (Codex · web)".
    private func blockers(of waiter: LeaseBook.Waiter?) -> String {
        guard let waiter else { return "someone else" }
        let holders = waiter.touched.compactMap { book.leases[$0]?.holder }.filter { $0.session?.id != waiter.session.id }
        if holders.contains(.user) { return "the user" }
        let agents = holders.compactMap(\.session?.label)
        return agents.isEmpty ? "someone else" : "another agent (\(agents.joined(separator: ", ")))"
    }

    private func devicesNamed(_ waiter: LeaseBook.Waiter?) -> String {
        guard let waiter, !waiter.touched.isEmpty else { return "this device" }
        return waiter.touched.map(name(of:)).joined(separator: ", ")
    }

    /// "1 native build is running (limit 1)" or "memory is low (12% free)".
    private func roomProblem(_ waiter: LeaseBook.Waiter) -> String {
        var problems: [String] = []
        if book.resources.memoryLow { problems.append("memory is low (\(monitor.snapshot.memoryFree)% free)") }
        for pool in waiter.pools where book.isFull(pool, now: .now) {
            let used = book.used(pool, now: .now)
            problems.append("\(pool.count(used)) \(used == 1 ? "is" : "are") running (limit \(book.resources.limits[pool] ?? 0))")
        }
        return problems.isEmpty ? "it was busy" : problems.joined(separator: " and ")
    }

    /// What the agent reads when its call is turned away after waiting.
    private func denyReason(_ waiter: LeaseBook.Waiter?, _ reason: LeaseBook.DenyReason) -> String {
        if let waiter, !waiter.touched.contains(where: { book.isBlocked($0, for: waiter.session, now: .now) }),
           !waiter.pools.isEmpty {
            return "DevDeck: the Mac is busy, so \"\(waiter.action)\" was not run: \(roomProblem(waiter))."
                + (reason == .dismissed ? " The user turned it away." : " It waited too long.")
                + " The user set these limits to keep the Mac responsive. Wait for the running work to finish"
                + " (or stop work of yours you no longer need), then try again."
        }
        // Free devices of the same kind as the ones it wanted.
        let candidates = Set(alternatives(for: waiter?.touched ?? []).values.joined())
        let free = devices.running
            .filter { candidates.contains($0.id) && lease(for: $0) == nil && !isQueued(for: $0) }
            .map(\.name)
        var text = "DevDeck: \(devicesNamed(waiter)) is in use by \(blockers(of: waiter)), so this call was not run"
        text += reason == .dismissed ? " (the user turned it away)." : " (it waited too long)."
        text += " Don't use that device until it's free."
        if !free.isEmpty { text += " Devices nobody is using: \(free.joined(separator: ", "))." }
        text += " Work on something else or ask the user, then try again."
        return text
    }

    /// What the agent reads when it's sent to a free device instead of waiting.
    private func redirectReason(_ waiter: LeaseBook.Waiter, free: [String]) -> String {
        let names = free.map(name(of:))
        return "DevDeck: \(devicesNamed(waiter)) is in use by \(blockers(of: waiter)), so this call was not run."
            + " Use \(names.count == 1 ? names[0] : "one of: " + names.joined(separator: ", ")) instead"
            + " (\(free.count == 1 ? "it's" : "they're") the same kind and nobody is using \(free.count == 1 ? "it" : "them")),"
            + " or wait and try this device again later. IDs: \(free.joined(separator: ", "))."
    }

    /// What the agent reads when it would boot a device while one of the same kind is free.
    private func useRunningReason(_ waiter: LeaseBook.Waiter, free: [String]) -> String {
        let names = free.map(name(of:))
        let first = names[0]
        return "DevDeck: \(names.count == 1 ? "\(first) is" : names.joined(separator: ", ") + " are") already running"
            + " and nobody is using \(names.count == 1 ? "it" : "them"), so booting \(devicesNamed(waiter)) was not run"
            + " (each simulator or emulator takes a few GB of memory). Use \(first) instead (ID \(free[0]))."
            + " If you need \(devicesNamed(waiter)) specifically, run the same command again within 5 minutes"
            + " and DevDeck will let it through."
    }

    private func notifyHandedOver(_ deviceID: String) {
        notifier.plain(
            "handover-\(deviceID)", title: "\(name(of: deviceID)) is yours",
            body: "The agent is done with it. Agents wait until you release it in DevDeck.", page: .leases)
    }
}
