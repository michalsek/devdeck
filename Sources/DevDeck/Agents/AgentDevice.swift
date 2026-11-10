import DevDeckProtocol
import Foundation

/// agent-device, the CLI behind T3 Code's device tools, and the device claims it keeps.
///
/// An agent-device session that opens a device writes a claim for it to
/// `~/.agent-device/device-claims`, and other sessions get `DEVICE_IN_USE` until it closes.
/// Nothing else ends a session by default: the daemon judges a claim only by whether its
/// owning process is alive, and T3 Code's daemon runs as long as T3 Code does. So a session
/// left open by an agent that has finished blocks the device until someone closes it.
/// DevDeck shows the claims, flags the ones nobody uses, and can close their session.
enum AgentDevice {
    /// Where agent-device keeps claims, for every daemon on the Mac.
    static func claimsDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["AGENT_DEVICE_CLAIMS_DIR"]?.trimmingCharacters(in: .whitespaces),
           dir.hasPrefix("/") {
            return URL(fileURLWithPath: dir)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-device/device-claims")
    }

    /// The session named in a `DEVICE_IN_USE` error, e.g. from
    /// `Error (DEVICE_IN_USE): Device is already in use by session "t3-8df3…".` or its JSON form.
    static func holder(inError text: String) -> String? {
        guard text.contains("DEVICE_IN_USE") else { return nil }
        // Plain text, text inside JSON (escaped quotes), then the JSON error's details.
        let patterns: [Regex<(Substring, Substring)>] = [
            #/in use by (?:workspace )?session \\?"([A-Za-z0-9._:-]+)/#,
            #/owned by session \\?"?([A-Za-z0-9._:-]+)/#,
            #/"session"\s*:\s*"([A-Za-z0-9._:-]+)"/#,
        ]
        for pattern in patterns {
            if let match = text.firstMatch(of: pattern) { return String(match.1) }
        }
        return nil
    }

    /// "t3-8df3016c…" for a long session name.
    static func shortName(_ session: String) -> String {
        session.count > 14 ? session.prefix(11) + "…" : session
    }
}

/// One `agent-device` command an agent runs, e.g. T3 Code's
/// `~/.t3/userdata/device/targets/t3-…/agent-device open com.example.app`.
struct AgentDeviceCall: Equatable {
    /// The program as typed, so the agent can be given a command it can run.
    let program: String
    /// "open", "press", "close"…
    let subcommand: String
    /// The agent-device session: `--session`, or the one T3 Code's launcher is made for.
    let session: String?
    /// Devices named with `--udid` or `--serial`.
    let devices: [String]

    var closes: Bool { subcommand == "close" }

    /// Finds the first `agent-device` invocation in a shell command: `agent-device …`,
    /// `npx agent-device …`, `pnpm exec agent-device …`, `node …/agent-device.mjs …`.
    static func parse(_ command: String) -> AgentDeviceCall? {
        guard let invocation = ShellCommand.invocations(command).first(where: {
            $0.program == "agent-device" || $0.program == "agent-device.mjs"
        }) else { return nil }
        let args = invocation.args
        var subcommand: String?
        var session: String?
        var devices: [String] = []
        var position = 0
        while position < args.count {
            let arg = args[position]
            if arg.hasPrefix("-") {
                let (flag, inline) = arg.split(separator: "=", maxSplits: 1).map(String.init).splitFirst
                var value = inline
                if value == nil, valuedFlags.contains(flag), position + 1 < args.count {
                    position += 1
                    value = args[position]
                }
                if let value {
                    switch flag {
                    case "--session": session = value
                    case "--udid", "--serial": devices.append(value)
                    default: break
                    }
                }
            } else if subcommand == nil {
                subcommand = arg
            }
            position += 1
        }
        return AgentDeviceCall(
            program: invocation.path, subcommand: subcommand ?? "",
            session: session ?? launcherSession(invocation.path), devices: devices)
    }

    /// T3 Code gives each thread a launcher at `…/device/targets/<session>/agent-device`.
    static func launcherSession(_ program: String) -> String? {
        let parts = program.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[parts.count - 1] == "agent-device", parts[parts.count - 3] == "targets" else { return nil }
        return parts[parts.count - 2]
    }

    /// Flags that take a value, so the value isn't read as the subcommand.
    private static let valuedFlags: Set<String> = [
        "--session", "--platform", "--udid", "--serial", "--device", "--config", "--state-dir",
        "--daemon-base-url", "--wait", "--timeout", "--target", "--out", "--app", "--format",
    ]
}

private extension Array where Element == String {
    /// ["--flag", "value"] → ("--flag", "value"); ["--flag"] → ("--flag", nil)
    var splitFirst: (String, String?) { (self[0], count > 1 ? self[1] : nil) }
}

/// A device claim agent-device keeps for an open session (one JSON file per device).
struct AgentDeviceClaim: Hashable {
    let fileName: String
    let deviceID: String
    let deviceName: String
    let session: String
    let workspace: String
    /// The state folder of the daemon that holds the session (its `daemon.json`, `sessions/`).
    let stateDir: String
    let ownerPID: Int32
    let created: Date
    let updated: Date

    /// "weather-app"
    var project: String { URL(fileURLWithPath: workspace).lastPathComponent }

    /// Reads a claim file. Claims a single command holds while it runs are skipped: they end
    /// with the command.
    init?(data: Data, fileName: String) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let session = json["session"] as? String, !session.hasPrefix("transient:"),
              json["claimOwnerKind"] as? String != "transient-command",
              let device = json["device"] as? [String: Any],
              let deviceID = device["id"] as? String,
              let stateDir = json["stateDir"] as? String,
              let pid = json["ownerPid"] as? Int, pid > 0
        else { return nil }
        self.fileName = fileName
        self.deviceID = deviceID
        deviceName = device["name"] as? String ?? deviceID
        self.session = session
        workspace = json["workspace"] as? String ?? ""
        self.stateDir = stateDir
        ownerPID = Int32(pid)
        let created = (json["createdAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
        self.created = created
        updated = (json["updatedAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? created
    }

    /// The session's event log, written on every command it runs.
    var eventLog: URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent("sessions").appendingPathComponent(session)
            .appendingPathComponent("events.ndjson")
    }
}

/// A claim as DevDeck shows it.
struct ClaimStatus: Identifiable, Hashable {
    let claim: AgentDeviceClaim
    /// When the session last ran a command. The claim's own `updatedAtMs` only moves on
    /// `open`, so the session's event log is the better clock.
    let lastActivity: Date

    var id: String { claim.fileName }
}

/// The agent that drives an agent-device session, from DevDeck's hooks.
struct ClaimOwner: Hashable {
    var session: AgentSession
    var lastCall: Date
    /// Its turn ended and it hasn't run an agent-device command since.
    var turnEnded: Date?
    /// Its session ended.
    var ended: Date?
}

enum ClaimState: Equatable {
    case active
    case stale(Reason)

    enum Reason: Equatable {
        /// The agent that opened it ended its session.
        case sessionEnded
        /// The agent's turn ended and the session has been quiet since.
        case turnEnded
        /// Nobody has used it for a long time.
        case idle
    }

    var isStale: Bool { self != .active }

    struct Timing {
        /// Stale this long after the owner's turn ended with no command since.
        var afterTurn: TimeInterval = 10 * 60
        /// Stale after this long without a command, whoever owns it.
        var idle: TimeInterval = 30 * 60
    }

    static func of(_ status: ClaimStatus, owner: ClaimOwner?, now: Date, timing: Timing = Timing()) -> ClaimState {
        let quiet = now.timeIntervalSince(status.lastActivity)
        if owner?.ended != nil { return .stale(.sessionEnded) }
        if owner?.turnEnded != nil, quiet >= timing.afterTurn { return .stale(.turnEnded) }
        if quiet >= timing.idle { return .stale(.idle) }
        return .active
    }
}

/// Text for the user and the agents about a claim.
enum ClaimText {
    /// "weather-app · last command 58 min ago · its agent's turn ended"
    static func detail(_ status: ClaimStatus, owner: ClaimOwner?, state: ClaimState, now: Date) -> String {
        var parts = [status.claim.project, "last command \(Format.age(since: status.lastActivity, now: now)) ago"]
        if let owner, owner.ended == nil, owner.turnEnded == nil {
            parts.append(owner.session.agent.title)
        }
        if case .stale(let reason) = state { parts.append(staleness(reason)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// One short line, the staleness first: "Stale agent-device claim · maps-app · last command 58 min ago"
    static func summary(_ status: ClaimStatus, state: ClaimState, now: Date) -> String {
        [state.isStale ? "Stale agent-device claim" : "agent-device claim", status.claim.project,
         "last command \(Format.age(since: status.lastActivity, now: now)) ago"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func staleness(_ reason: ClaimState.Reason) -> String {
        switch reason {
        case .sessionEnded: "stale: its agent's session ended"
        case .turnEnded: "stale: its agent's turn ended"
        case .idle: "stale: unused"
        }
    }

    /// What an agent reads after agent-device turned it away with `DEVICE_IN_USE`.
    static func advice(
        deviceName: String, status: ClaimStatus, owner: ClaimOwner?, state: ClaimState, program: String?,
        freeDevices: [DeviceItem], now: Date
    ) -> String {
        let claim = status.claim
        let quiet = Format.age(since: status.lastActivity, now: now)
        let project = claim.project.isEmpty ? "" : " (\(claim.project))"
        var text = "DevDeck: \(deviceName) is claimed by agent-device session \"\(claim.session)\"\(project)."
        switch state {
        case .stale(let reason):
            text += " That session has run no command for \(quiet)"
            switch reason {
            case .sessionEnded: text += " and the agent that opened it has ended its session"
            case .turnEnded: text += " and the agent that opened it has finished its turn"
            case .idle: break
            }
            text += ", so the claim is stale. It won't free itself: waiting or --wait won't help."
            text += " Don't close another agent's session on your own. Ask the user to release it"
            text += " (DevDeck → Leases → Release Claim). If the user agrees, you can release it with:"
            text += " \(program ?? "agent-device") close --session \(claim.session)"
            if program == nil { text += " (with AGENT_DEVICE_STATE_DIR=\(claim.stateDir))" }
            text += "."
        case .active:
            let who = owner.map { " by \($0.session.agentDescription) in \($0.session.project.name)" } ?? ""
            text += " It's in use\(who): its last command was \(quiet) ago. Leave it alone and don't close that session."
        }
        if !freeDevices.isEmpty {
            text += " Running devices of the same kind that nobody is using: "
                + freeDevices.map { "\($0.name) (\($0.serial ?? $0.id))" }.joined(separator: ", ") + "."
        } else if !state.isStale {
            text += " Work on something else and try again later, or ask the user."
        }
        return text
    }
}
