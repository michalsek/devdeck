import Darwin
import DevDeckProtocol
import Foundation
import os

/// A Metro server DevDeck runs for an agent.
struct KeptMetro: Codable, Identifiable, Hashable {
    let pid: Int32
    let port: Int
    let directory: String
    /// The command DevDeck runs: the agent's, without its redirections, with the port DevDeck chose.
    let command: String
    let log: String
    let project: String
    /// The agent session it was started for (`AgentSession.id`) and its label.
    let session: String?
    let agent: String?
    var started = Date.now
    /// The agent's PATH, so a restart finds the same node.
    var path: String?

    var id: Int32 { pid }
}

/// Runs the Metro servers agents start, as DevDeck's own processes. An agent's shell or
/// background task gets killed when its harness's time limit runs out, and Metro with it;
/// DevDeck's copy keeps running (in its own session, so not even quitting DevDeck stops
/// it) until the user stops it or cleans up after the agent. The agent is told the port
/// and where the log is.
@MainActor
final class MetroKeeper: ObservableObject {
    private static let log = Logger(subsystem: "dev.devdeck.app", category: "metro")

    /// Run agents' Metro servers in DevDeck.
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "keepAgentMetros") }
    }
    @Published private(set) var kept: [KeptMetro] = []

    private let servers: ServerStore
    private let activity: ActivityLog
    private let registry: URL
    /// Watches each started server so it's reaped when it exits.
    private var exits: [Int32: DispatchSourceProcess] = [:]

    static let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DevDeck")

    init(servers: ServerStore, activity: ActivityLog) {
        self.servers = servers
        self.activity = activity
        enabled = UserDefaults.standard.object(forKey: "keepAgentMetros") as? Bool ?? true
        registry = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DevDeck/metros.json")
        guard !Demo.isOn else { return }
        // Servers kept before DevDeck last quit are still DevDeck's while they run.
        if let data = try? Data(contentsOf: registry),
           let saved = try? JSONDecoder().decode([KeptMetro].self, from: data) {
            kept = saved.filter { Self.isAlive($0.pid) }
        }
    }

    /// The kept server listening on one of these ports.
    func kept(for server: DevServer) -> KeptMetro? {
        kept.first { server.ports.contains($0.port) && Self.isAlive($0.pid) }
    }

    // MARK: Agents

    /// The Metro start in an agent's command, if DevDeck should run it.
    func recognize(_ command: String, cwd: String?) -> MetroStart? {
        guard enabled, let cwd else { return nil }
        return MetroStart.find(in: command, cwd: cwd)
    }

    enum Outcome {
        /// The agent reads `reply` instead of running its command; `started` is the server
        /// DevDeck started, if it started one.
        case taken(reply: String, started: KeptMetro?)
        /// DevDeck couldn't run it: the agent's own command goes ahead.
        case failed
    }

    /// Starts the Metro an agent asked for, or points the agent at the one already running
    /// in that folder.
    func start(_ start: MetroStart, path: String?, session: AgentSession) async -> Outcome {
        prune()
        let project = ServerScanner.project(for: start.directory, fallback: "app")
        if let reply = alreadyRunning(start, project: project, session: session) { return .taken(reply: reply, started: nil) }

        // Ports in use, including ones DevDeck handed out that haven't opened yet.
        let taken = Set(servers.servers.flatMap(\.ports) + kept.map(\.port))
        var port = start.port
        while taken.contains(port) || !Self.isFree(port) { port += 1 }
        let command = start.command(port: port == start.port ? nil : port)
        guard let metro = launch(command, directory: start.directory, port: port, project: project.name, path: path,
                                 session: session.id, agent: session.label)
        else { return .failed }
        kept.append(metro)
        save()

        // A command that fails at once (a typo, a missing dependency) is the agent's to see.
        try? await Task.sleep(for: .seconds(1))
        guard Self.isAlive(metro.pid) else {
            kept.removeAll { $0.pid == metro.pid }
            save()
            let tail = (try? String(contentsOfFile: metro.log, encoding: .utf8)).map { String($0.suffix(300)) } ?? ""
            activity.add(
                .metro, agent: session.label, subject: "Metro · \(project.name)",
                "Metro exited at once, so the agent runs its own command. \(tail)", session: session.id)
            return .failed
        }
        activity.add(
            .metro, agent: session.label, subject: "Metro · \(project.name) :\(port)",
            "Started Metro for the agent; it keeps running when the agent's shell ends. Log: \(metro.log)",
            session: session.id)
        Task { await servers.refresh() }
        var reply = "DevDeck: DevDeck started Metro for \(project.name) on port \(port) and keeps it running for you,"
            + " so it won't stop when your shell or background task ends. Don't start it yourself."
            + " Its log is \(metro.log): tail -n 80 it to see the bundler's output and errors,"
            + " and curl -s localhost:\(port)/status answers packager-status:running once it's ready."
        if port != start.port {
            let other = servers.servers.first { $0.ports.contains(start.port) }?.project.name ?? "another app"
            reply += " Port \(start.port) belongs to \(other), so yours is on \(port): point the app at it"
                + " (iOS simulator: launch with -RCT_jsLocation 127.0.0.1:\(port); Android: adb reverse tcp:8081 tcp:\(port))."
        }
        return .taken(reply: reply + " To stop or restart it, ask the user (DevDeck → Dev Servers).", started: metro)
    }

    /// "Metro is already running in this folder" for the agent, if it is.
    private func alreadyRunning(_ start: MetroStart, project: DevServer.Project, session: AgentSession) -> String? {
        let folder = URL(fileURLWithPath: start.directory).standardizedFileURL.path
        let server = servers.servers.first {
            $0.metro != nil && $0.cwd.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == folder
        }
        let pending = kept.first { URL(fileURLWithPath: $0.directory).standardizedFileURL.path == folder }
        guard server != nil || pending != nil else { return nil }
        let port = server?.metro?.port ?? pending?.port ?? start.port
        let pid = server?.pid ?? pending?.pid ?? 0
        let log = (server.flatMap(kept(for:)) ?? pending).map { " Its log is \($0.log) (tail -n 80 it)." } ?? ""
        activity.add(
            .metro, agent: session.label, subject: "Metro · \(project.name)",
            "Pointed the agent at the Metro already running on :\(port).", session: session.id)
        return "DevDeck: Metro for \(project.name) is already running in \(start.directory) on port \(port)"
            + " (pid \(pid)), so this command was not run.\(log) Use that one."
            + " To restart it (say, with --clear), stop it first (kill \(pid)), then run your command again."
    }

    /// Runs the same command again in the same folder.
    func restart(_ metro: KeptMetro) {
        Task {
            _ = await Task.detached { await ServerScanner.stop(metro.pid) }.value
            kept.removeAll { $0.pid == metro.pid }
            if let fresh = launch(
                metro.command, directory: metro.directory, port: metro.port, project: metro.project, path: metro.path,
                session: metro.session, agent: metro.agent) {
                kept.append(fresh)
            }
            save()
            await servers.refresh()
        }
    }

    /// Forgets servers that have stopped.
    func prune() {
        let alive = kept.filter { Self.isAlive($0.pid) }
        if alive != kept {
            kept = alive
            save()
        }
    }

    // MARK: Running

    /// Starts `command` with `/bin/sh` in its own session, output to a log file.
    private func launch(
        _ command: String, directory: String, port: Int, project: String, path: String?, session: String?, agent: String?
    ) -> KeptMetro? {
        try? FileManager.default.createDirectory(at: Self.logs, withIntermediateDirectories: true)
        let log = Self.logs.appendingPathComponent("metro-\(project)-\(port).log").path
        var environment = Shell.environment
        if let path { environment["PATH"] = path + ":" + Shell.path }
        guard let pid = Self.spawn(["/bin/sh", "-c", "exec " + command], directory: directory, log: log, environment: environment)
        else {
            Self.log.error("couldn't start \(command, privacy: .public) in \(directory, privacy: .public)")
            return nil
        }
        Self.log.info("started \(command, privacy: .public) in \(directory, privacy: .public), pid \(pid)")
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            Task { @MainActor in
                self?.exits[pid]?.cancel()
                self?.exits[pid] = nil
                self?.prune()
            }
        }
        source.resume()
        exits[pid] = source
        return KeptMetro(
            pid: pid, port: port, directory: directory, command: command, log: log, project: project,
            session: session, agent: agent, path: path)
    }

    /// `posix_spawn` with `POSIX_SPAWN_SETSID`: the server gets its own session and process
    /// group, so nothing aimed at DevDeck's reaches it.
    nonisolated static func spawn(_ argv: [String], directory: String, log: String, environment: [String: String]) -> Int32? {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let args = argv.map { strdup($0) } + [nil]
        let env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            args.forEach { free($0) }
            env.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, argv[0], &actions, &attributes, args, env)
        return result == 0 ? pid : nil
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? FileManager.default.createDirectory(at: registry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: registry, options: .atomic)
    }

    nonisolated static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// Nothing listens on the port (on any address).
    nonisolated static func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }
}

/// A command that starts Metro: `npx expo start`, `react-native start`, or a package
/// script that runs one (`npm start`, `yarn dev`), with the folder it runs in. Only a plain
/// start, maybe after `cd`: a command that sets things up first (`export`, `nvm use`,
/// `source .env`) is left to the agent, so its setup isn't lost.
struct MetroStart: Equatable {
    /// The words that start it, assignments and runners included ("npx", "expo", "start").
    let words: [String]
    let program: String
    let directory: String
    let port: Int

    static func find(in command: String, cwd: String, readFile: (String) -> String? = Self.read) -> MetroStart? {
        var directory = cwd
        for invocation in ShellCommand.invocations(command) {
            if invocation.program == "cd", let target = invocation.args.first {
                directory = target.hasPrefix("/") ? target
                    : URL(fileURLWithPath: directory).appendingPathComponent(target).standardizedFileURL.path
                continue
            }
            var script: String?
            if ["npm", "yarn", "pnpm", "bun"].contains(invocation.program) {
                var words = invocation.args.filter { !$0.hasPrefix("-") }
                if words.first == "run" { words.removeFirst() }
                guard let name = words.first, ["start", "dev"].contains(name),
                      let json = readFile(directory + "/package.json").flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) }),
                      let body = ((json as? [String: Any])?["scripts"] as? [String: Any])?[name] as? String,
                      isMetro(ShellCommand.invocations(body).first)
                else { return nil }
                script = body
            } else if !isMetro(invocation) {
                return nil
            }
            let port = port(in: invocation) ?? script.flatMap { ShellCommand.invocations($0).first.flatMap(port(in:)) }
                ?? invocation.environment["RCT_METRO_PORT"].flatMap(Int.init) ?? 8081
            return MetroStart(words: invocation.words, program: invocation.program, directory: directory, port: port)
        }
        return nil
    }

    /// The command DevDeck runs: its words without redirections (DevDeck keeps the log),
    /// quoted for `sh`, with `--port` set when `port` is given (npm passes it on after `--`).
    func command(port: Int? = nil) -> String {
        var kept: [String] = []
        var skipTarget = false
        for word in words {
            if skipTarget {
                skipTarget = false
                continue
            }
            if let redirection = word.firstMatch(of: #/^[0-9]*(&>>?|>>?|<|>&|<&)(.*)$/#) {
                // "> file" takes the next word; "2>&1" and ">file" don't.
                skipTarget = redirection.2.isEmpty && !redirection.1.hasSuffix("&")
                continue
            }
            kept.append(word)
        }
        if let port { kept += program == "npm" ? ["--", "--port", String(port)] : ["--port", String(port)] }
        return kept.map(Self.quoted).joined(separator: " ")
    }

    /// `it's` → `'it'\''s'`; plain words and `NAME=value` stay as they are.
    private static func quoted(_ word: String) -> String {
        let plain = word.allSatisfy { $0.isLetter || $0.isNumber || "-_./:=@%+,".contains($0) }
        return plain && !word.isEmpty ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isMetro(_ invocation: ShellInvocation?) -> Bool {
        guard let invocation else { return false }
        let verb = invocation.args.first { !$0.hasPrefix("-") }
        switch invocation.program {
        case "expo": return verb == nil || verb == "start"
        case "react-native": return verb == "start"
        default: return false
        }
    }

    private static func port(in invocation: ShellInvocation) -> Int? {
        for (index, arg) in invocation.args.enumerated() {
            if arg.hasPrefix("--port=") { return Int(arg.dropFirst(7)) }
            if ["--port", "-p"].contains(arg), index + 1 < invocation.args.count { return Int(invocation.args[index + 1]) }
        }
        return nil
    }

    static func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
}
