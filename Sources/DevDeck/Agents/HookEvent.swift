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
    enum Kind: Equatable { case toolUse, turnEnd, sessionEnd }

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
    /// Heavy work the call starts (a build, a dev server, a device boot).
    let pools: [Pool]

    init?(json: [String: Any]) {
        guard let agent = (json["agent"] as? String).flatMap(AgentKind.init),
              let sessionID = json["session_id"] as? String
        else { return nil }
        self.agent = agent
        self.sessionID = sessionID
        cwd = json["cwd"] as? String
        host = json["host"] as? String

        switch json["hook_event_name"] as? String {
        case "SessionEnd", "Stop":
            kind = json["hook_event_name"] as? String == "Stop" ? .turnEnd : .sessionEnd
            action = kind == .turnEnd ? "turn ended" : "session ended"
            targets = []
            releases = []
            pools = []
        case "PreToolUse":
            let tool = json["tool_name"] as? String ?? ""
            let input = json["tool_input"] as? [String: Any] ?? [:]
            var parsed: (action: String, targets: [DeviceTarget], releases: [DeviceTarget])?
            var pools: [Pool] = []
            if tool.hasPrefix(Self.argentPrefix) {
                let name = String(tool.dropFirst(Self.argentPrefix.count))
                parsed = Self.argentCall(name, input)
                pools = Pool.forArgent(name, input)
            } else if tool == "Bash", let command = input["command"] as? String {
                parsed = Self.shellCommand(command)
                pools = Pool.forShell(command)
                if parsed == nil, !pools.isEmpty { parsed = (Self.shortName(command), [], []) }
            }
            guard let parsed, !(parsed.targets.isEmpty && parsed.releases.isEmpty && pools.isEmpty) else { return nil }
            kind = .toolUse
            (action, targets, releases) = parsed
            self.pools = pools
        default:
            return nil
        }
    }

    private static let argentPrefix = "mcp__argent__"

    /// argent tools name their device with `udid` (iOS UDID, adb serial or Chromium id),
    /// a few with `device_id`; `boot-device` can take an AVD name instead.
    static func argentCall(_ tool: String, _ input: [String: Any])
        -> (action: String, targets: [DeviceTarget], releases: [DeviceTarget]) {
        var ids = ["udid", "device_id", "deviceId", "serial"].compactMap { input[$0] as? String }
        if let avd = input["avdName"] as? String { ids.append("avd:" + avd) }
        if tool == "stop-simulator-server" || tool == "stop-all-simulator-servers" {
            let devices = input["devices"] as? [String] ?? ids
            return (tool, [], devices.map(DeviceTarget.id))
        }
        return (tool, ids.map(DeviceTarget.id), [])
    }

    /// Finds `xcrun simctl`, `adb` and `emulator` invocations in a shell command.
    /// Best effort: each `;`, `&&`, `|` or newline separated part is read on its own.
    static func shellCommand(_ command: String)
        -> (action: String, targets: [DeviceTarget], releases: [DeviceTarget])? {
        var actions: [String] = []
        var targets: [DeviceTarget] = []
        var releases: [DeviceTarget] = []

        for part in command.components(separatedBy: CharacterSet(charactersIn: ";|&\n")) {
            var words = part.split(whereSeparator: \.isWhitespace)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'()")) }
            // Leading environment assignments, e.g. ANDROID_SERIAL=emulator-5554 adb shell …
            var environment: [String: String] = [:]
            while let first = words.first, let equals = first.firstIndex(of: "="), !first.hasPrefix("-") {
                environment[String(first[..<equals])] = String(first[first.index(after: equals)...])
                words.removeFirst()
            }
            guard let program = words.first.map({ $0.split(separator: "/").last.map(String.init) ?? $0 }) else { continue }
            var args = Array(words.dropFirst())

            switch program {
            case "xcrun" where args.first == "simctl", "simctl":
                if program == "xcrun" { args.removeFirst() }
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
                var serial = environment["ANDROID_SERIAL"]
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

            case "emulator":
                let avd = args.firstIndex(of: "-avd").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
                    ?? args.first { $0.hasPrefix("@") }.map { String($0.dropFirst()) }
                guard let avd else { continue }
                targets.append(.id("avd:" + avd))
                actions.append("emulator")

            default:
                continue
            }
        }
        guard !targets.isEmpty || !releases.isEmpty else { return nil }
        return (actions.first ?? "shell", targets, releases)
    }

    /// "npx expo run:ios" from "cd app && npx expo run:ios --device X", for display.
    static func shortName(_ command: String) -> String {
        let part = command.components(separatedBy: CharacterSet(charactersIn: ";|&\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !Pool.forShell($0).isEmpty } ?? command
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
