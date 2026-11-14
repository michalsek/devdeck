import DevDeckProtocol
import Foundation

/// The coding agents DevDeck installs hooks into.
enum AgentKind: String, CaseIterable, Identifiable, Hashable {
    case claude, codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// A device named by an agent call, before it's matched to a `DeviceItem`.
enum DeviceTarget: Hashable {
    /// A simulator UDID, adb serial, physical device UDID, or "avd:<name>".
    case id(String)
    /// `simctl … booted`: whichever simulator is booted.
    case bootedSimulator
    /// `adb` without `-s`: the only connected Android device.
    case defaultAndroid
    /// `simctl shutdown all`.
    case allSimulators
}

/// One agent hook call forwarded by `devdeck-hook`, reduced to what DevDeck shows:
/// which session touched which device, with what.
struct HookEvent: Equatable {
    enum Kind: Equatable {
        case toolUse, turnEnd, sessionEnd
        /// A shell command that ran, and agent-device turned it away with `DEVICE_IN_USE`.
        case deviceInUse
        /// A command that builds, installs or launches an app on a device finished.
        case result(failed: Bool)
    }

    let kind: Kind
    let agent: AgentKind
    let sessionID: String
    let cwd: String?
    /// The app the agent runs in, e.g. "T3 Code".
    let host: String?
    /// Short name of the action, e.g. "gesture-tap" or "simctl boot".
    let action: String
    /// Devices the call works on.
    let targets: [DeviceTarget]
    /// Devices the call is done with (shut down, simulator server stopped).
    let releases: [DeviceTarget]
    /// Released devices the call shuts down.
    let stops: [DeviceTarget]
    /// Heavy work the call starts (a build, a dev server, a device boot).
    let pools: [Pool]
    /// The `agent-device` command in the call, if any (T3 Code's device tools).
    let agentDevice: AgentDeviceCall?
    /// For `deviceInUse`: the agent-device session the error names as the device's holder.
    let holder: String?
    /// After a command: the end of its output.
    private(set) var output: String?
    /// The shell command, for a Bash call.
    let command: String?
    /// The agent's PATH.
    let path: String?
    /// How long the hook will wait for an answer.
    let maxWait: TimeInterval
    /// The agent's process: the hook's parent.
    let agentPID: Int32?
    /// What the call does to every agent (see `CommandGuard`), so it needs the user's OK.
    let everyoneEffect: LeaseBook.Approval?
    /// Processes the command stops: by pid, by the port they listen on, or by pattern.
    let kills: [CommandGuard.Kill]

    /// The part of the wait the hook allows that DevDeck uses.
    var waitLimit: TimeInterval { min(maxWait, HookProtocol.maxWait) }

    init?(json: [String: Any]) {
        guard let agent = (json[HookProtocol.Field.agent] as? String).flatMap(AgentKind.init),
              let sessionID = json["session_id"] as? String
        else { return nil }
        self.agent = agent
        self.sessionID = sessionID
        cwd = json["cwd"] as? String
        host = json[HookProtocol.Field.host] as? String
        maxWait = json[HookProtocol.Field.maxWait] as? Double ?? HookProtocol.maxWait
        agentPID = (json[HookProtocol.Field.agentPID] as? Int).map(Int32.init)

        let input = json["tool_input"] as? [String: Any] ?? [:]
        let command = json["tool_name"] as? String == "Bash" ? input["command"] as? String : nil
        self.command = command
        path = json[HookProtocol.Field.path] as? String
        agentDevice = command.flatMap(AgentDeviceCall.parse)
        kills = command.map(CommandGuard.kills) ?? []

        switch json["hook_event_name"] as? String {
        case "SessionEnd", "Stop":
            kind = json["hook_event_name"] as? String == "Stop" ? .turnEnd : .sessionEnd
            action = kind == .turnEnd ? "turn ended" : "session ended"
            everyoneEffect = nil
            targets = []
            releases = []
            stops = []
            pools = []
            holder = nil
        case "PostToolUse", "PostToolUseFailure":
            // `devdeck-hook` forwards these with the text of a DEVICE_IN_USE error, or the end
            // of a device command's output.
            guard let output = json[HookProtocol.Field.toolOutput] as? String else { return nil }
            everyoneEffect = nil
            self.output = output
            if output.contains("DEVICE_IN_USE") {
                kind = .deviceInUse
                action = "DEVICE_IN_USE"
                holder = AgentDevice.holder(inError: output)
                targets = (agentDevice?.devices ?? []).map(DeviceTarget.id)
            } else {
                guard let command, let parsed = Self.shellCommand(command) else { return nil }
                kind = .result(failed: json["hook_event_name"] as? String == "PostToolUseFailure")
                action = parsed.action
                holder = nil
                targets = parsed.targets
            }
            releases = []
            stops = []
            pools = []
        case "PreToolUse":
            let tool = json["tool_name"] as? String ?? ""
            var parsed: (action: String, targets: [DeviceTarget], releases: [DeviceTarget])?
            var pools: [Pool] = []
            var effect: LeaseBook.Approval?
            var stops: [DeviceTarget] = []
            if tool.hasPrefix(Self.argentPrefix) {
                let name = String(tool.dropFirst(Self.argentPrefix.count))
                parsed = Self.argentCall(name, input)
                pools = Pool.forArgent(name, input)
                effect = CommandGuard.everyoneEffect(argent: name, input)
            } else if let command {
                effect = CommandGuard.everyoneEffect(command)
                parsed = Self.shellCommand(command)
                // Shell commands release a device by shutting it down (simctl shutdown, adb emu kill).
                stops = parsed?.releases ?? []
                pools = Pool.forShell(command)
                if let call = agentDevice {
                    // The device may come from the launcher or the session's claim; LeaseStore finds it.
                    let devices = call.devices.map(DeviceTarget.id)
                    let previous = parsed ?? ("agent-device " + call.subcommand, [], [])
                    parsed = call.closes
                        ? (previous.action, previous.targets, previous.releases + devices)
                        : (previous.action, previous.targets + devices, previous.releases)
                }
                if parsed == nil, !pools.isEmpty { parsed = (Self.shortName(command), [], []) }
                if parsed == nil, let segment = effect?.segment ?? kills.first?.segment { parsed = (segment, [], []) }
            }
            everyoneEffect = effect
            self.stops = stops
            guard let parsed,
                  agentDevice != nil || effect != nil || !kills.isEmpty
                    || !(parsed.targets.isEmpty && parsed.releases.isEmpty && pools.isEmpty)
            else { return nil }
            kind = .toolUse
            (action, targets, releases) = parsed
            self.pools = pools
            holder = nil
        default:
            return nil
        }
    }

    private static let argentPrefix = "mcp__argent__"

    /// argent tools name their device with `udid` (iOS UDID, adb serial or Chromium id),
    /// a few with `device_id`; `boot-device` can take an AVD name instead.
    static func argentCall(_ tool: String, _ input: [String: Any])
        -> (action: String, targets: [DeviceTarget], releases: [DeviceTarget]) {
        // It compares two image files on disk; nothing runs on the device it names.
        if tool == "screenshot-diff" { return (tool, [], []) }
        var ids = ["udid", "device_id", "deviceId", "serial"].compactMap { input[$0] as? String }
        if let avd = input["avdName"] as? String { ids.append(DeviceItem.avdID(avd)) }
        if tool == "stop-simulator-server" || tool == "stop-all-simulator-servers" {
            let devices = input["devices"] as? [String] ?? ids
            return (tool, [], devices.map(DeviceTarget.id))
        }
        return (tool, ids.map(DeviceTarget.id), [])
    }

    /// Finds `xcrun simctl`, `adb` and `emulator` invocations in a shell command.
    static func shellCommand(_ command: String)
        -> (action: String, targets: [DeviceTarget], releases: [DeviceTarget])? {
        var actions: [String] = []
        var targets: [DeviceTarget] = []
        var releases: [DeviceTarget] = []

        for invocation in ShellCommand.invocations(command) {
            var args = invocation.args
            switch invocation.program {
            case "simctl":
                guard let verb = args.first, !simctlHostCommands.contains(verb) else { continue }
                let rest = args.dropFirst()
                let ids = rest.filter(isUUID).map(DeviceTarget.id)
                let devices = !ids.isEmpty ? ids : rest.contains("booted") ? [.bootedSimulator] : []
                if ["shutdown", "erase", "delete"].contains(verb) {
                    releases += rest.contains("all") ? [.allSimulators] : devices
                } else {
                    targets += devices
                }
                if !devices.isEmpty || rest.contains("all") { actions.append("simctl " + verb) }

            case "adb":
                var serial = invocation.environment["ANDROID_SERIAL"]
                while let flag = args.first, flag.hasPrefix("-") {
                    args.removeFirst()
                    if flag == "-s", let value = args.first {
                        serial = value
                        args.removeFirst()
                    }
                }
                guard let verb = args.first, !adbHostCommands.contains(verb) else { continue }
                let device: DeviceTarget = serial.map(DeviceTarget.id) ?? .defaultAndroid
                if verb == "emu", args.dropFirst().first == "kill" {
                    releases.append(device)
                } else {
                    targets.append(device)
                }
                actions.append("adb " + verb)

            case "devicectl":
                // xcrun devicectl device install app --device <id> App.app
                guard let device = value(of: ["--device", "-d"], in: args) else { continue }
                targets.append(.id(device))
                actions.append((["devicectl"] + args.prefix(2)).joined(separator: " "))

            case "xcodebuild":
                // -destination 'platform=iOS,id=00008150-…'
                guard let destination = value(of: ["-destination"], in: args),
                      let id = destination.split(separator: ",").first(where: { $0.hasPrefix("id=") })?.dropFirst(3)
                else { continue }
                targets.append(.id(String(id)))
                actions.append("xcodebuild")

            case "expo", "react-native":
                // expo run:ios --device <udid or name>, react-native run-ios --udid <udid>, run-android --deviceId <serial>
                guard let device = value(of: ["--udid", "--deviceId", "--device", "-d"], in: args) else { continue }
                targets.append(.id(device))
                actions.append(([invocation.program] + args.prefix(1)).joined(separator: " "))

            case "emulator":
                let avd = args.firstIndex(of: "-avd").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
                    ?? args.first { $0.hasPrefix("@") }.map { String($0.dropFirst()) }
                guard let avd else { continue }
                targets.append(.id(DeviceItem.avdID(avd)))
                actions.append("emulator")

            default:
                continue
            }
        }
        guard !targets.isEmpty || !releases.isEmpty else { return nil }
        return (actions.first ?? "shell", targets, releases)
    }

    /// The value after the first of `flags` (`--device X` or `--device=X`).
    private static func value(of flags: [String], in args: [String]) -> String? {
        for (index, arg) in args.enumerated() {
            for flag in flags {
                if arg == flag, index + 1 < args.count { return args[index + 1] }
                if arg.hasPrefix(flag + "=") { return String(arg.dropFirst(flag.count + 1)) }
            }
        }
        return nil
    }

    /// The part of a command that starts heavy work, shortened for display:
    /// "npx expo run:ios" out of "cd app && npx expo run:ios --device X".
    static func shortName(_ command: String) -> String {
        let part = ShellCommand.invocations(command).first { !Pool.forShell($0.text).isEmpty }?.text ?? command
        return part.split(separator: " ").prefix(3).joined(separator: " ")
    }

    /// simctl commands that don't act on a particular device.
    private static let simctlHostCommands: Set<String> = ["list", "help", "runtime", "create"]

    /// adb commands that talk to the adb server, not to a device.
    private static let adbHostCommands: Set<String> = [
        "devices", "start-server", "kill-server", "version", "help", "connect", "disconnect",
        "pair", "mdns", "keygen", "reconnect",
    ]

    private static func isUUID(_ word: String) -> Bool {
        UUID(uuidString: word) != nil
    }
}

extension LeaseBook.Waiter {
    /// The call behind an agent's tool use: the devices it works on and is done with, by
    /// DevDeck's ids, and the room it needs (none to boot a device that's already running).
    /// `claimDevices` are the devices an agent-device call's launcher or session is bound to.
    init(_ event: HookEvent, session: AgentSession, claimDevices: [String], devices: DeviceIndex, now: Date) {
        var targets = event.targets.flatMap(devices.resolve)
        var releases = event.releases.flatMap(devices.resolve)
        let stops = event.stops.flatMap(devices.resolve)
        if let call = event.agentDevice, call.devices.isEmpty {
            let found = claimDevices.flatMap { devices.resolve(.id($0)) }
            if call.closes { releases += found } else { targets += found }
        }
        let booting: Set<Pool> = [.iosSimulator, .androidEmulator]
        let alreadyRunning = !targets.isEmpty && targets.allSatisfy(devices.isRunning)
        self.init(
            id: UUID(), session: session, action: event.action, devices: targets, releases: releases, stops: stops,
            since: now, deadline: now.addingTimeInterval(event.waitLimit),
            pools: event.pools.filter { !(booting.contains($0) && alreadyRunning) })
    }
}
