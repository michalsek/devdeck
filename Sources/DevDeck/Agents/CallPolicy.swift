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

    /// A call turned away before it reaches the book.
    enum Refusal: Equatable {
        /// The user wants Android tested on a phone; `noPhone` when none is connected.
        case phonesOnly(reason: String, noPhone: Bool)
        /// The app on the device loads another checkout's Metro; asking again goes through.
        case wrongMetro(reason: String, key: String)

        var reason: String {
            switch self {
            case .phonesOnly(let reason, _), .wrongMetro(let reason, _): reason
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

    struct Approval: Equatable {
        /// "shuts down every simulator"
        let reason: String
        /// How long it waits for the user, when shorter than any call's.
        var wait: TimeInterval?
    }

    /// A kill of something DevDeck can't tie to any agent waits this long for the user's OK.
    /// It's most likely the user's own (or, rarely, an agent's DevDeck couldn't place), and
    /// either way an agent shouldn't sit on it for minutes.
    static let unknownOwnerWait: TimeInterval = 60

    /// What the call does beyond the agent's own work, so it waits for the user's OK:
    /// "shuts down every simulator", or a kill aimed at a dev server or build that
    /// another agent or the user started.
    func approval(_ event: HookEvent, by session: AgentSession) -> Approval? {
        if let effect = event.everyoneEffect { return Approval(reason: effect) }
        let byPort = event.kills.ports.compactMap { port in servers.first { $0.ports.contains(port) } }
        let byPID = event.kills.pids.compactMap { pid in servers.first { $0.pid == pid } }
        let targets = (byPort + byPID).map { ($0.pid, "\($0.project.name)'s \($0.kind) on :\($0.portList)") }
            + event.kills.pids.compactMap { pid in
                builds.first { $0.pid == pid }.map { (pid, "\($0.project ?? "another project")'s \($0.kind)") }
            }
        for (pid, name) in targets where owners[pid]?.id != session.id {
            let owner = owners[pid]
            return Approval(
                reason: "stops \(name) (\(owner.map { "\($0.label) started it" } ?? "you or another app started it"))",
                wait: owner == nil ? Self.unknownOwnerWait : nil)
        }
        return nil
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
