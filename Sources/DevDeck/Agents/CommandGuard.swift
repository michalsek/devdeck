import Darwin
import DevDeckProtocol
import Foundation

/// Commands that reach past the agent's own work: they affect every agent's devices or
/// servers, or stop processes. `CallPolicy` judges the processes against who started them.
enum CommandGuard {
    /// The part of a command that affects every agent, e.g. `xcrun simctl shutdown all`.
    static func everyoneEffect(_ command: String) -> LeaseBook.Approval? {
        for invocation in ShellCommand.invocations(command) {
            let args = invocation.args
            let effect: String? = switch invocation.program {
            case "simctl" where ["shutdown", "erase"].contains(args.first ?? "") && args.dropFirst().contains("all"):
                args.first == "erase" ? "erases every simulator" : "shuts down every simulator"
            case "adb" where args.contains("kill-server"):
                "restarts adb, which cuts every agent off its Android devices"
            case "launchctl" where args.contains(where: { $0.localizedCaseInsensitiveContains("CoreSimulator") }):
                "restarts CoreSimulator, which takes down every simulator"
            default:
                nil
            }
            if let effect { return LeaseBook.Approval(segment: invocation.text, effect: effect) }
        }
        return nil
    }

    /// For argent: stopping every simulator server, not just the agent's own.
    static func everyoneEffect(argent tool: String, _ input: [String: Any]) -> LeaseBook.Approval? {
        guard tool == "stop-all-simulator-servers", (input["devices"] as? [String])?.isEmpty ?? true else { return nil }
        return LeaseBook.Approval(segment: tool, effect: "stops argent's simulator servers for every agent")
    }

    /// Something one part of a command stops.
    struct Kill: Equatable {
        enum Target: Equatable {
            case pid(Int32)
            /// The server listening on a port.
            case port(Int)
            /// Whatever `pkill` or `killall` matches when it runs.
            case processes(ProcessPattern)
        }

        /// The part of the command, e.g. `pkill -f "expo start"`.
        let segment: String
        let target: Target
    }

    /// What a command stops: `kill <pid>`, servers named by port (`kill $(lsof -ti:8081)`,
    /// `npx kill-port 8081`, `fuser -k 8081/tcp`), and `pkill` / `killall` patterns.
    static func kills(_ command: String) -> [Kill] {
        let invocations = ShellCommand.invocations(command)
        let killing = invocations.contains { $0.program == "kill" }
        return invocations.flatMap { invocation -> [Kill] in
            let args = invocation.args
            let targets: [Kill.Target] = switch invocation.program {
            case "kill": args.compactMap { Int32($0) }.filter { $0 > 1 }.map(Kill.Target.pid)
            case "lsof" where killing: args.compactMap(port(inLsof:)).map(Kill.Target.port)
            case "kill-port": args.compactMap { Int($0) }.map(Kill.Target.port)
            case "fuser" where args.contains("-k"): args.compactMap { $0.hasSuffix("/tcp") ? Int($0.dropLast(4)) : nil }.map(Kill.Target.port)
            case "pkill", "killall": ProcessPattern(invocation).map { [.processes($0)] } ?? []
            default: []
            }
            // `lsof` only finds the pid; the kill is around it (`kill $(lsof …)`, `lsof … | xargs kill`).
            let segment = invocation.program == "lsof" ? "kill $(\(invocation.text))" : invocation.text
            return targets.map { Kill(segment: segment, target: $0) }
        }
    }

    /// "-ti:8081", "-i:8081", "-iTCP:8081", "tcp:8081" → 8081
    private static func port(inLsof arg: String) -> Int? {
        guard arg.contains(":"), let last = arg.split(separator: ":").last else { return nil }
        return Int(last)
    }

    /// Processes every agent relies on, so stopping one is never just the agent's own business:
    /// "stops adb, which cuts every agent off its Android devices".
    static func sharedEffect(_ process: ServerScanner.ProcessRow) -> String? {
        let command = process.command
        if process.name == "Simulator" || process.name == "DeviceHub" {
            return "quits \(process.name), which closes every simulator window"
        }
        if command.contains("CoreSimulatorService") { return "restarts CoreSimulator, which takes down every simulator" }
        if process.name == "adb", command.contains("fork-server") {
            return "stops adb, which cuts every agent off its Android devices"
        }
        if command.contains("GradleDaemon") || command.contains("KotlinCompileDaemon") {
            return "stops a Gradle or Kotlin daemon that every agent's builds use"
        }
        if command.contains("argent"), command.contains("tool-server") {
            return "stops argent's tool server, which every agent's device tools use"
        }
        return nil
    }
}

/// The processes `pkill` or `killall` signals, read the way those tools read their arguments.
struct ProcessPattern: Equatable {
    /// Extended regular expressions (`pkill`, `killall -m`), or names (`killall`).
    var patterns: [String] = []
    var isRegex = true
    /// `pkill -f`: matched against the whole command line, not the process name.
    var fullCommand = false
    /// `pkill -x`: the whole name (or command line) must match.
    var exact = false
    var ignoreCase = false
    /// `pkill -v`: everything that doesn't match.
    var inverted = false
    /// `pkill -P`: only children of these.
    var parents: Set<Int32> = []
    /// `pkill -n` / `-o`: only the newest or the oldest match.
    var newest = false
    var oldest = false

    /// Nil when the command signals nothing (`killall -s` lists, `pkill` without a pattern
    /// errors) or picks processes in a way DevDeck doesn't follow (`pkill -F pidfile`).
    init?(_ invocation: ShellInvocation) {
        var args = invocation.args[...]
        if invocation.program == "killall" {
            isRegex = false
            while let arg = args.first, arg.hasPrefix("-"), arg.count > 1 {
                args.removeFirst()
                switch arg {
                case "-m": isRegex = true
                case "-s", "-d", "-l", "-help": return nil
                case "-u", "-t": args = args.dropFirst()
                case "-c": if let name = args.popFirst() { patterns.append(name) }
                default: continue  // a signal, -v, -q, -z, -e, -I
                }
            }
        } else {
            // A signal (-9, -KILL) can only come first; flags are lowercase or a single capital (-P).
            if let first = args.first, first.hasPrefix("-") {
                let signal = first.dropFirst()
                if !signal.isEmpty, signal.allSatisfy(\.isNumber)
                    || (signal.count > 1 && signal.allSatisfy { $0.isUppercase || $0.isNumber }) {
                    args.removeFirst()
                }
            }
            flags: while let arg = args.first, arg.hasPrefix("-"), arg.count > 1 {
                args.removeFirst()
                if arg == "--" { break }
                for (index, flag) in arg.dropFirst().enumerated() {
                    switch flag {
                    case "f": fullCommand = true
                    case "x": exact = true
                    case "i": ignoreCase = true
                    case "v": inverted = true
                    case "n": newest = true
                    case "o": oldest = true
                    case "F": return nil
                    case "G", "P", "U", "d", "g", "t", "u":
                        let rest = String(arg.dropFirst(index + 2))
                        let value = rest.isEmpty ? args.popFirst() ?? "" : rest
                        if flag == "P" { parents.formUnion(value.split(separator: ",").compactMap { Int32($0) }) }
                        continue flags
                    default: continue  // -a, -l, -I, -L, -q
                    }
                }
            }
        }
        patterns += args
        guard !patterns.isEmpty || !parents.isEmpty else { return nil }
    }

    /// The processes in `table` it would signal, leaving out `excluded` (the shell that runs
    /// it and that shell's ancestors, which `pkill` skips). An invalid pattern signals nothing.
    func matches(in table: [Int32: ServerScanner.ProcessRow], excluding excluded: Set<Int32>) -> [ServerScanner.ProcessRow] {
        var flags = REG_EXTENDED | REG_NOSUB
        if ignoreCase { flags |= REG_ICASE }
        let regexes = isRegex ? patterns.compactMap { POSIXRegex(exact ? "^(\($0))$" : $0, flags: flags) } : []
        guard regexes.count == (isRegex ? patterns.count : 0) else { return [] }
        let names = Set(patterns.map { String($0.prefix(Int(MAXCOMLEN))) })
        var hits = table.values.filter { process in
            guard !excluded.contains(process.pid), parents.isEmpty || parents.contains(process.ppid) else { return false }
            guard !patterns.isEmpty else { return true }
            let subject = fullCommand ? process.command : process.name
            let hit = isRegex ? regexes.contains { $0.matches(subject) } : names.contains(subject)
            return hit != inverted
        }
        if newest || oldest {
            let ordered = hits.sorted { ($0.started ?? .distantPast) < ($1.started ?? .distantPast) }
            hits = (newest ? ordered.last : ordered.first).map { [$0] } ?? []
        }
        return hits.sorted { $0.pid < $1.pid }
    }
}

/// regcomp/regexec: the extended regular expressions `pkill` and `killall -m` use.
private final class POSIXRegex {
    private var regex = regex_t()

    init?(_ pattern: String, flags: Int32) {
        guard regcomp(&regex, pattern, flags) == 0 else { return nil }
    }

    deinit { regfree(&regex) }

    func matches(_ text: String) -> Bool { regexec(&regex, text, 0, nil, 0) == 0 }
}
