import Darwin
import Foundation

/// The contract between `devdeck-hook` and DevDeck's broker socket: where the socket is,
/// how long each side waits, which hook calls are worth a trip, and the reply.
///
/// The hook sends one JSON line: the agent's hook event as it came, minus
/// `transcript_path` and a command's output, plus the `Field`s below. For a call that waits,
/// DevDeck answers with one `HookReply` line.
public enum HookProtocol {
    /// Extra fields the hook adds to the agent's event.
    public enum Field {
        /// "claude" or "codex".
        public static let agent = "agent"
        /// How long the call may wait, in seconds.
        public static let maxWait = "max_wait"
        /// The app the agent runs in, e.g. "T3 Code".
        public static let host = "host"
        /// After a shell command: the text around a DEVICE_IN_USE error.
        public static let toolOutput = "tool_output"
        /// The agent's process id (the hook's parent).
        public static let agentPID = "agent_pid"
        /// Before a tool call: the agent's PATH, so DevDeck can run a command the way the agent would.
        public static let path = "path"
    }

    /// The hook timeout DevDeck installs for `PreToolUse`.
    public static let hookTimeout: TimeInterval = 600
    /// How long a call may wait for DevDeck: under `hookTimeout`, so DevDeck can still
    /// answer in time.
    public static let maxWait: TimeInterval = 540
    /// The hook waits this much longer than DevDeck does before giving up on an answer.
    public static let replyGrace: TimeInterval = 15
    /// Advice after a command comes at once, or not at all.
    public static let adviceTimeout: TimeInterval = 5

    /// `~/Library/Application Support/DevDeck/broker.sock`; `DEVDECK_SOCKET` points
    /// elsewhere, for testing.
    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["DEVDECK_SOCKET"] ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DevDeck/broker.sock").path
    }

    /// Fills in a Unix socket address for `path`, or nil if the path is too long.
    public static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    /// Writes all of `data`; false if the other end went away.
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    // MARK: Which calls reach DevDeck

    /// Programs DevDeck acts on: devices, heavy work it may make wait for room, and
    /// commands that affect every agent's devices or servers.
    public static let programs: Set<String> = [
        "simctl", "devicectl", "adb", "emulator", "agent-device", "agent-device.mjs",
        "xcodebuild", "gradlew", "gradle", "expo", "react-native", "eas", "npm", "yarn", "pnpm", "bun",
        "vite", "next", "nuxt", "astro", "remix", "storybook", "start-storybook", "metro",
        "killall", "pkill", "kill", "kill-port", "fuser", "launchctl",
    ]

    /// Whether DevDeck needs to hear about this hook event. Cheap, so the hook can return
    /// at once for everything else.
    public static func isRelevant(_ event: [String: Any]) -> Bool {
        switch event["hook_event_name"] as? String {
        case "SessionEnd", "Stop":
            return true
        case "PostToolUse", "PostToolUseFailure":
            return deviceInUseOutput(event) != nil || resultOutput(event) != nil
        case "PreToolUse":
            let tool = event["tool_name"] as? String ?? ""
            if tool.hasPrefix("mcp__argent__") { return true }
            guard tool == "Bash", let command = (event["tool_input"] as? [String: Any])?["command"] as? String
            else { return false }
            return ShellCommand.invocations(command).contains { programs.contains($0.program) }
        default:
            return false
        }
    }

    /// For a finished shell command: the part of its output around a DEVICE_IN_USE error.
    public static func deviceInUseOutput(_ event: [String: Any]) -> String? {
        guard event["tool_name"] as? String == "Bash" else { return nil }
        let output = text(of: event["tool_response"]) + "\n" + text(of: event["error"])
        guard let found = output.range(of: "DEVICE_IN_USE") else { return nil }
        let start = output.index(found.lowerBound, offsetBy: -500, limitedBy: output.startIndex) ?? output.startIndex
        let end = output.index(found.upperBound, offsetBy: 2000, limitedBy: output.endIndex) ?? output.endIndex
        return String(output[start..<end])
    }

    /// For a finished command that builds, installs or launches an app on a device: the end
    /// of its output, so DevDeck can show how it went. Nil for any other command.
    public static func resultOutput(_ event: [String: Any]) -> String? {
        guard event["tool_name"] as? String == "Bash",
              let command = (event["tool_input"] as? [String: Any])?["command"] as? String,
              ShellCommand.invocations(command).contains(where: isDeviceWork)
        else { return nil }
        let output = (text(of: event["tool_response"]) + "\n" + text(of: event["error"]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(output.suffix(400))
    }

    /// devicectl, xcodebuild, adb install, expo run:…, react-native run-…
    private static func isDeviceWork(_ invocation: ShellInvocation) -> Bool {
        let verb = invocation.args.first ?? ""
        switch invocation.program {
        case "devicectl", "xcodebuild": return true
        case "adb": return invocation.args.contains("install")
        case "expo": return verb.hasPrefix("run:")
        case "react-native": return verb.hasPrefix("run-")
        default: return false
        }
    }

    /// All the text in a tool's result: Claude Code's `{stdout, stderr}`, Codex's output, or
    /// the error of a failed call.
    private static func text(of value: Any?) -> String {
        switch value {
        case let string as String: string
        case let object as [String: Any]: object.keys.sorted().map { text(of: object[$0]) }.joined(separator: "\n")
        case let list as [Any]: list.map { text(of: $0) }.joined(separator: "\n")
        default: ""
        }
    }
}

/// DevDeck's answer to a hook call.
public struct HookReply: Codable, Equatable, Sendable {
    public enum Decision: String, Codable, Sendable { case allow, deny }

    /// For a tool call: whether it may run. Absent for advice after a command.
    public var decision: Decision?
    /// Why a call was turned away, for the agent.
    public var reason: String?
    /// After a command: what the agent should know (who holds a device it couldn't get).
    public var context: String?

    public init(decision: Decision? = nil, reason: String? = nil, context: String? = nil) {
        self.decision = decision
        self.reason = reason
        self.context = context
    }

    public static let allow = HookReply(decision: .allow)
    public static func deny(_ reason: String) -> HookReply { HookReply(decision: .deny, reason: reason) }
    /// Nothing to say: the call goes ahead.
    public static let none = HookReply()

    /// One JSON line.
    public var line: Data {
        var data = (try? JSONEncoder().encode(self)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }
}
