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
                  link.isWrong(for: waiter.session.project)
            else { continue }
            let key = "\(waiter.session.id)|\(id)|\(link.server.pid)"
            guard !metroWarned.contains(key) else { continue }
            return .wrongMetro(reason: link.warning(device: device.name, project: waiter.session.project), key: key)
        }
        return nil
    }

    /// What the call does beyond the agent's own work, so it waits for the user's OK:
    /// "shuts down every simulator", or a kill aimed at a dev server or build that
    /// another agent or the user started.
    func approval(_ event: HookEvent, by session: AgentSession) -> String? {
        if let effect = event.everyoneEffect { return effect }
        let byPort = event.kills.ports.compactMap { port in servers.first { $0.ports.contains(port) } }
        let byPID = event.kills.pids.compactMap { pid in servers.first { $0.pid == pid } }
        for server in byPort + byPID where owners[server.pid]?.id != session.id {
            return "stops \(server.project.name)'s \(server.kind) on :\(server.portList) (\(Self.starter(owners[server.pid])))"
        }
        for pid in event.kills.pids {
            guard let build = builds.first(where: { $0.pid == pid }), owners[pid]?.id != session.id else { continue }
            return "stops \(build.project ?? "another project")'s \(build.kind) (\(Self.starter(owners[pid])))"
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

    private static func starter(_ owner: AgentSession?) -> String {
        owner.map { "\($0.label) started it" } ?? "you or another app started it"
    }

    /// Calls that change which Metro an app loads, so a warning about it never holds them up.
    private static let rewiresApp: Set<String> = [
        "adb reverse", "adb install", "simctl launch", "simctl terminate", "simctl install", "simctl boot", "emulator",
        "launch-app", "restart-app", "reinstall-app", "boot-device", "open-url",
        "stop-simulator-server", "stop-all-simulator-servers",
    ]
}
