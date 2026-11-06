import Darwin
import Foundation
import os

/// agent-device's device claims (see `AgentDevice`): which session holds which device, how
/// long it's been quiet, which agent drives it (from DevDeck's hooks), and Release, which
/// closes the session through its daemon. Refreshed every 5 seconds.
@MainActor
final class ClaimStore: ObservableObject {
    private static let log = Logger(subsystem: "dev.devdeck.app", category: "claims")

    @Published private(set) var claims: [ClaimStatus] = []
    /// The agent behind each agent-device session DevDeck has seen a command from.
    @Published private(set) var owners: [String: ClaimOwner] = [:]
    /// Sessions being closed.
    @Published private(set) var releasing: Set<String> = []
    @Published private(set) var lastError: String?

    var timing = ClaimState.Timing()
    private let directory: URL
    private var timer: Timer?
    private var scanning = false
    /// T3 Code launcher → the device it's bound to.
    private var launcherDevices: [String: String?] = [:]

    init(directory: URL = AgentDevice.claimsDirectory()) {
        self.directory = directory
        if Demo.isOn {
            (claims, owners) = Demo.claims()
            return
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: Reading

    func claims(for device: DeviceItem) -> [ClaimStatus] {
        claims.filter { $0.claim.deviceID == device.id || $0.claim.deviceID == device.serial }
    }

    func owner(of status: ClaimStatus) -> ClaimOwner? { owners[status.claim.session] }

    func state(of status: ClaimStatus, now: Date = .now) -> ClaimState {
        ClaimState.of(status, owner: owner(of: status), now: now, timing: timing)
    }

    func isReleasing(_ status: ClaimStatus) -> Bool { releasing.contains(status.claim.session) }

    /// The claim held by an agent-device session, read fresh from disk.
    func claim(heldBy session: String) -> ClaimStatus? {
        claims = Self.scan(directory)
        return claims.first { $0.claim.session == session }
    }

    // MARK: Agents (from the hooks)

    /// Devices an agent-device command works on: the ones it names, else the one its T3 Code
    /// launcher is bound to, else the one its session has claimed.
    func devices(for call: AgentDeviceCall) -> [String] {
        if !call.devices.isEmpty { return call.devices }
        if let device = boundDevice(of: call.program) { return [device] }
        if let session = call.session, let status = claims.first(where: { $0.claim.session == session }) {
            return [status.claim.deviceID]
        }
        return []
    }

    func noteCall(_ call: AgentDeviceCall, by session: AgentSession, now: Date) {
        guard let name = call.session else { return }
        if call.closes {
            owners[name] = nil
        } else {
            owners[name] = ClaimOwner(session: session, lastCall: now)
        }
    }

    func turnEnded(_ sessionID: String, now: Date) {
        for (name, owner) in owners where owner.session.id == sessionID && owner.turnEnded == nil {
            owners[name]?.turnEnded = now
        }
    }

    func sessionEnded(_ sessionID: String, now: Date) {
        for (name, owner) in owners where owner.session.id == sessionID {
            owners[name]?.ended = now
        }
    }

    // MARK: Release

    /// Closes the claim's agent-device session, which frees the device. The agent that had
    /// it gets `SESSION_NOT_FOUND` next time and has to open the device again.
    func release(_ status: ClaimStatus) {
        let claim = status.claim
        guard !releasing.contains(claim.session) else { return }
        releasing.insert(claim.session)
        Task {
            let error = await Self.closeSession(claim)
            releasing.remove(claim.session)
            lastError = error.map { "\(claim.deviceName): \($0)" }
            Self.log.info("release \(claim.session, privacy: .public): \(error ?? "ok", privacy: .public)")
            if error == nil { owners[claim.session] = nil }
            refresh()
        }
    }

    /// Asks the daemon that holds the session to close it, as T3 Code does: JSON-RPC
    /// `close` on its HTTP port, with the token from its `daemon.json`. Returns an error.
    nonisolated static func closeSession(_ claim: AgentDeviceClaim) async -> String? {
        let record = URL(fileURLWithPath: claim.stateDir).appendingPathComponent("daemon.json")
        guard let data = try? Data(contentsOf: record),
              let daemon = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return "Can't read agent-device's \(record.path)." }
        guard (daemon["pid"] as? Int).map(Int32.init) == claim.ownerPID else {
            return "The agent-device daemon that made this claim isn't running any more; agent-device takes the device back the next time a session opens it."
        }
        guard let port = daemon["httpPort"] as? Int, let token = daemon["token"] as? String,
              let url = URL(string: "http://127.0.0.1:\(port)/rpc")
        else { return "This agent-device daemon doesn't take HTTP requests. Run: agent-device close --session \(claim.session)" }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": claim.session, "method": "agent_device.command",
            "params": ["command": "close", "session": claim.session, "positionals": [], "flags": [:]] as [String: Any],
        ] as [String: Any])
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 404: the session is already gone, which is what we wanted.
            if status == 404 { return nil }
            let reply = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            if let error = reply?["error"] as? [String: Any] {
                let code = (error["data"] as? [String: Any])?["code"] as? String
                if code == "SESSION_NOT_FOUND" { return nil }
                return (error["message"] as? String) ?? "agent-device refused (\(code ?? "error"))."
            }
            return status == 200 ? nil : "agent-device answered HTTP \(status)."
        } catch {
            return "Can't reach the agent-device daemon: \(error.localizedDescription)"
        }
    }

    // MARK: Scanning

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let directory = directory
        Task.detached(priority: .utility) {
            let found = Self.scan(directory)
            await MainActor.run {
                self.scanning = false
                if found != self.claims { self.claims = found }
                // Forget agents of sessions that hold nothing and haven't been seen for a day.
                let held = Set(found.map(\.claim.session))
                self.owners = self.owners.filter { held.contains($0.key) || Date.now.timeIntervalSince($0.value.lastCall) < 86400 }
            }
        }
    }

    /// Claims whose daemon is still running (agent-device reclaims the others itself).
    nonisolated static func scan(_ directory: URL) -> [ClaimStatus] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file -> ClaimStatus? in
            guard let data = try? Data(contentsOf: file),
                  let claim = AgentDeviceClaim(data: data, fileName: file.lastPathComponent),
                  isAlive(claim.ownerPID)
            else { return nil }
            let logged = (try? FileManager.default.attributesOfItem(atPath: claim.eventLog.path))?[.modificationDate] as? Date
            return ClaimStatus(claim: claim, lastActivity: max(claim.updated, logged ?? .distantPast))
        }
        .sorted { $0.claim.created < $1.claim.created }
    }

    nonisolated private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// T3 Code's launcher for a session lists the device it's bound to (`--udid <id>`) in
    /// the `agent-device-launcher.mjs` next to it.
    private func boundDevice(of program: String) -> String? {
        guard AgentDeviceCall.launcherSession(program) != nil else { return nil }
        if let known = launcherDevices[program] { return known }
        let script = URL(fileURLWithPath: program).deletingLastPathComponent()
            .appendingPathComponent("agent-device-launcher.mjs")
        let device = (try? String(contentsOf: script, encoding: .utf8)).flatMap(Self.boundDevice(inLauncher:))
        launcherDevices[program] = device
        return device
    }

    /// `const bound = ["--platform","ios","--udid","1A2C…",…];` → "1A2C…"
    nonisolated static func boundDevice(inLauncher source: String) -> String? {
        guard let match = source.firstMatch(of: #/const bound = (\[[^\n]*?\]);/#),
              let list = (try? JSONSerialization.jsonObject(with: Data(match.1.utf8))) as? [String]
        else { return nil }
        for (index, flag) in list.enumerated() where ["--udid", "--serial"].contains(flag) && index + 1 < list.count {
            return list[index + 1]
        }
        return nil
    }
}
