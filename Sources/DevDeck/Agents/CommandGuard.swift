import DevDeckProtocol
import Foundation

/// Commands that reach past the agent's own work: they affect every agent's devices or
/// servers, or stop something another agent or the user started. These wait for the
/// user's OK.
enum CommandGuard {
    /// What a command does to everyone, e.g. "shuts down every simulator", or nil.
    static func everyoneEffect(_ command: String) -> String? {
        for invocation in ShellCommand.invocations(command) {
            let args = invocation.args
            switch invocation.program {
            case "killall", "pkill":
                let targets = args.filter { !$0.hasPrefix("-") }
                if let hit = targets.lazy.compactMap(sharedProcess).first { return hit }
            case "simctl":
                if ["shutdown", "erase"].contains(args.first ?? ""), args.dropFirst().contains("all") {
                    return args.first == "erase" ? "erases every simulator" : "shuts down every simulator"
                }
            case "adb":
                if args.contains("kill-server") { return "restarts adb, which cuts every agent off its Android devices" }
            case "launchctl":
                if args.contains(where: { $0.localizedCaseInsensitiveContains("CoreSimulator") }) {
                    return "restarts CoreSimulator, which takes down every simulator"
                }
            default:
                continue
            }
        }
        return nil
    }

    /// For argent: stopping every simulator server, not just the agent's own.
    static func everyoneEffect(argent tool: String, _ input: [String: Any]) -> String? {
        guard tool == "stop-all-simulator-servers", (input["devices"] as? [String])?.isEmpty ?? true else { return nil }
        return "stops argent's simulator servers for every agent"
    }

    struct Kills: Equatable {
        var pids: [Int32] = []
        var ports: [Int] = []

        var isEmpty: Bool { pids.isEmpty && ports.isEmpty }
    }

    /// Processes a command stops: `kill <pid>`, and servers named by port
    /// (`kill $(lsof -ti:8081)`, `npx kill-port 8081`, `fuser -k 8081/tcp`).
    static func kills(_ command: String) -> Kills {
        let invocations = ShellCommand.invocations(command)
        var pids: [Int32] = []
        var ports: [Int] = []
        let killing = invocations.contains { $0.program == "kill" }
        for invocation in invocations {
            switch invocation.program {
            case "kill":
                pids += invocation.args.compactMap { Int32($0) }.filter { $0 > 1 }
            case "lsof" where killing:
                ports += invocation.args.compactMap(port(inLsof:))
            case "kill-port":
                ports += invocation.args.compactMap { Int($0) }
            case "fuser" where invocation.args.contains("-k"):
                ports += invocation.args.compactMap { $0.hasSuffix("/tcp") ? Int($0.dropLast(4)) : nil }
            default:
                continue
            }
        }
        return Kills(pids: pids, ports: ports)
    }

    /// "-ti:8081", "-i:8081", "-iTCP:8081", "tcp:8081" → 8081
    private static func port(inLsof arg: String) -> Int? {
        guard arg.contains(":"), let last = arg.split(separator: ":").last else { return nil }
        return Int(last)
    }

    /// `killall Simulator`, `pkill -f qemu`, `pkill node`: names that hit what every agent uses.
    private static func sharedProcess(_ name: String) -> String? {
        let lower = name.lowercased()
        let effects: [(needles: [String], effect: String)] = [
            (["simulator", "devicehub", "device hub"], "quits the Simulator app and every simulator window"),
            (["coresimulator"], "restarts CoreSimulator, which takes down every simulator"),
            (["qemu", "emulator"], "stops every Android emulator"),
            (["node", "metro", "expo", "react-native"], "stops every Node process: all dev servers and Metro, including other agents' and yours"),
            (["java", "gradle", "kotlin"], "stops every Gradle and Kotlin process, including other agents' builds"),
            (["xcodebuild"], "stops every Xcode build, including other agents'"),
            (["adb"], "stops adb, which cuts every agent off its Android devices"),
        ]
        return effects.first { $0.needles.contains(where: lower.contains) }?.effect
    }
}
