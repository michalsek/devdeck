import CoreGraphics
import Foundation
import UserNotifications

/// The broker: receives agent hook calls from `devdeck-hook`, decides with `LeaseBook`
/// whether each may run now or has to wait for the user, and answers the hook.
/// If DevDeck isn't running, hooks don't wait at all.
@MainActor
final class LeaseStore: ObservableObject {
    typealias Lease = LeaseBook.Lease

    /// How long a call may wait when the hook doesn't say (it asks for less than its timeout).
    static let defaultMaxWait: TimeInterval = 9 * 60

    @Published private(set) var book = LeaseBook()
    @Published private(set) var listening = false

    private let devices: DeviceStore
    private let settings: AppSettings
    private var server: BrokerServer?
    private var timer: Timer?
    /// Hook connections of waiting calls, and the calls themselves (for the reason when
    /// one is turned away; the book forgets them by then).
    private var connections: [UUID: BrokerConnection] = [:]
    private var pending: [UUID: LeaseBook.Waiter] = [:]

    init(devices: DeviceStore, settings: AppSettings) {
        self.devices = devices
        self.settings = settings
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
        Self.requestNotificationPermission()
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
            let waiter = LeaseBook.Waiter(
                id: UUID(), session: session, action: event.action,
                devices: event.targets.flatMap(resolve), releases: event.releases.flatMap(resolve),
                since: now, deadline: now.addingTimeInterval(maxWait))
            switch book.request(waiter, alternatives: alternatives(for: waiter.touched), now: now) {
            case .allow:
                connection.respond(["decision": "allow"])
            case .redirect(let free):
                connection.respond(["decision": "deny", "reason": redirectReason(waiter, free: free)])
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
            ["id": $0.id.uuidString, "devices": $0.touched, "agent": $0.session.label, "action": $0.action] as [String: Any]
        }
        return ["ok": true, "leases": leases, "queue": Array(book.queue), "waiting": waiters]
    }

    private func hungUp(_ waiter: UUID) {
        connections[waiter] = nil
        pending[waiter] = nil
        book.cancel(waiter)
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

    private func tick() {
        // Something replaced or removed the socket file: open a fresh one.
        if server?.isStale ?? true { openSocket() }
        guard devices.loaded else { return }
        let running = Set(devices.running.flatMap { [$0.id] + ($0.serial.map { [$0] } ?? []) })
        let minutes = settings.holdReleaseMinutes
        carryOut(book.tick(
            now: .now, running: running, userAway: Self.secondsSinceUserInput(),
            userHoldTimeout: minutes > 0 ? TimeInterval(minutes * 60) : nil))
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
            connections.removeValue(forKey: id)?.respond(["decision": "allow"])
        }
        for denial in effects.denied {
            let waiter = pending.removeValue(forKey: denial.waiter)
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

    /// What the agent reads when its call is turned away after waiting.
    private func denyReason(_ waiter: LeaseBook.Waiter?, _ reason: LeaseBook.DenyReason) -> String {
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

    private func notifyHandedOver(_ deviceID: String) {
        let name = devices.devices.first { $0.id == deviceID || $0.serial == deviceID }?.name ?? "The device"
        let content = UNMutableNotificationContent()
        content.title = "\(name) is yours"
        content.body = "The agent is done with it. Agents wait until you release it in DevDeck."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "handover-\(deviceID)", content: content, trigger: nil))
    }

    private static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
