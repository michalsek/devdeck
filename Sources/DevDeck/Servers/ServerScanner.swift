import Darwin
import Foundation

struct DevServer: Identifiable, Hashable {
    enum Group: Hashable { case devServer, agentTool }

    let pid: Int32
    var ports: [Int]
    var kind: String
    let group: Group
    var isWeb: Bool
    let command: String
    let cwd: String?
    let project: Project
    let started: Date?
    /// Set for Metro: whether the packager answered, and the apps attached to it.
    var metro: Metro?

    var id: Int32 { pid }
    var url: URL? { isWeb ? ports.first.flatMap { URL(string: "http://localhost:\($0)") } : nil }
    var portList: String { ports.map(String.init).joined(separator: ", ") }

    struct Project: Hashable {
        let name: String
        let subtitle: String
        /// The git worktree it's in, when it isn't the main checkout.
        var worktree: String? = nil

        /// The same checkout: the same repo and worktree (any folder inside it).
        func isSameCheckout(as other: Project) -> Bool { name == other.name && worktree == other.worktree }
    }

    struct Metro: Hashable {
        let running: Bool
        /// The port that answered as Metro, used to talk to its `/message` socket.
        let port: Int
        /// The apps attached to it, as they introduce themselves at `/json/list`.
        var targets: [Target] = []
        /// Simulator UDID → app, for simulator apps connected to it (they run on this Mac).
        var simulators: [String: String] = [:]

        /// Device names of the attached apps, e.g. "iPhone 17 Pro".
        var apps: [String] {
            var names: [String] = []
            for target in targets where !names.contains(target.deviceName) { names.append(target.deviceName) }
            return names
        }

        struct Target: Hashable {
            /// "iPhone 17 Pro", a phone's name, or an Android model ("sdk_gphone64_arm64").
            let deviceName: String
            /// The app's title or bundle id.
            let app: String?
        }
    }
}

/// Finds dev servers by listing listening TCP sockets owned by script runtimes
/// (node, bun, deno, python, ruby, php) and classifying their command lines.
enum ServerScanner {
    struct ProcessRow: Sendable {
        let pid: Int32
        let ppid: Int32
        let started: Date?
        let command: String

        var executable: String {
            (command.split(separator: " ").first.map(String.init) ?? command)
                .split(separator: "/").last.map(String.init) ?? command
        }
    }

    static let runtimes: Set<String> = ["node", "bun", "deno", "ruby", "php"]

    static func isRuntime(_ name: String) -> Bool {
        runtimes.contains(name) || name.lowercased().hasPrefix("python")
    }

    static func scan() async -> [DevServer] {
        let table = recentProcessTable()
        let listening = LibProc.listeningPorts(table.keys)
        let candidates = listening.keys.compactMap { pid -> ProcessRow? in
            guard let row = table[pid],
                  isRuntime(row.executable),
                  !isBundledInApp(row.command)
            else { return nil }
            return row
        }
        let candidatePIDs = Set(candidates.map(\.pid))
        let cwds = LibProc.workingDirectories(Array(candidatePIDs))

        // A dev server often forks a listening child (Next, Vite plugins); show it as one row.
        var ports: [Int32: Set<Int>] = [:]
        for row in candidates {
            var owner = row.pid
            var parent = table[row.pid]?.ppid ?? 0
            while parent > 1 {
                if candidatePIDs.contains(parent) { owner = parent }
                parent = table[parent]?.ppid ?? 0
            }
            ports[owner, default: []].formUnion(listening[row.pid] ?? [])
        }

        let argentVersions = argentServerVersions()
        var servers: [DevServer] = []
        for (pid, portSet) in ports {
            guard let row = table[pid] else { continue }
            let (kind, group, isWeb) = classify(row.command)
            let cwd = cwds[pid]
            // argent's working folder is wherever its first client ran, so name it after the tool.
            let project = argentVersions[pid] != nil || kind == "Tool server"
                ? DevServer.Project(name: "argent", subtitle: argentVersions[pid].map { "version \($0)" } ?? "")
                : project(for: cwd, fallback: row.executable)
            var server = DevServer(
                pid: pid, ports: portSet.sorted(), kind: kind, group: group, isWeb: isWeb,
                command: row.command, cwd: cwd, project: project, started: row.started)
            if group == .devServer, let metro = await probeMetro(server.ports) {
                server.metro = metro
                server.isWeb = false
                if !kind.hasPrefix("Metro") { server.kind = "Metro" }
            }
            servers.append(server)
        }
        let metroPorts = Set(servers.compactMap(\.metro?.port))
        if !metroPorts.isEmpty {
            let simulators = simulatorClients(of: metroPorts, table: table)
            for index in servers.indices {
                guard let port = servers[index].metro?.port else { continue }
                servers[index].metro?.simulators = simulators[port] ?? [:]
            }
        }
        return servers.sorted { ($0.started ?? .distantPast) < ($1.started ?? .distantPast) }
    }

    /// Runtimes shipped inside apps (editor helpers, Electron backends) aren't dev servers.
    /// Toolchain bundles are the exception: Xcode's and Homebrew's python live in `.app`s too.
    static func isBundledInApp(_ command: String) -> Bool {
        let executable = command.split(separator: " ").first.map(String.init) ?? command
        guard executable.contains(".app/Contents/") else { return false }
        return !executable.contains("Python.app/") && !executable.contains(".app/Contents/Developer/")
    }

    // MARK: - Classification

    /// Returns a display kind, its group, and whether it serves a web page worth opening.
    static func classify(_ command: String) -> (String, DevServer.Group, Bool) {
        let c = command.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { c.contains($0) } }

        if has("argent") && has("tool-server") { return ("Tool server", .agentTool, false) }
        if has("mcp-server", "mcp_server", "/mcp/", " mcp ") { return ("MCP server", .agentTool, false) }
        if has("expo start", "expo run:", "expo/bin/cli start", "expo/bin/cli run", "@expo/cli") {
            return ("Metro · Expo", .devServer, false)
        }
        if has("react-native start", "react-native run-", "@react-native/community-cli-plugin", "metro serve") {
            return ("Metro · React Native", .devServer, false)
        }
        let web: [(String, [String])] = [
            ("Vite", ["vite"]), ("Next.js", ["next dev", "next-server", "next/dist", "next start"]),
            ("Storybook", ["storybook"]), ("Astro", ["astro dev", "astro/"]), ("Nuxt", ["nuxt"]),
            ("Remix", ["remix"]), ("Wrangler", ["wrangler"]), ("webpack", ["webpack"]),
            ("Parcel", ["parcel"]), ("Docusaurus", ["docusaurus"]), ("Angular", ["ng serve", "@angular/cli"]),
            ("SvelteKit", ["svelte-kit"]), ("Django", ["manage.py runserver"]), ("Flask", ["flask run"]),
            ("Uvicorn", ["uvicorn"]), ("Rails", ["rails server", "puma"]), ("Static server", ["http.server", "http-server", "serve "]),
        ]
        for (name, needles) in web where needles.contains(where: { c.contains($0) }) {
            return (name, .devServer, true)
        }
        let runtime = ProcessRow(pid: 0, ppid: 0, started: nil, command: command).executable
        let label = runtime.lowercased().hasPrefix("python") ? "Python" : runtime.capitalized
        return ("\(label) server", .devServer, true)
    }

    /// Names a server after its git repo (and worktree), or its package/folder otherwise.
    static func project(for cwd: String?, fallback: String) -> DevServer.Project {
        guard let cwd else { return .init(name: fallback, subtitle: "") }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var dir = URL(fileURLWithPath: cwd)
        while dir.path != "/" && dir.path != home {
            let git = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git.path, isDirectory: &isDir) {
                let sub = cwd == dir.path ? "" : String(cwd.dropFirst(dir.path.count + 1))
                var name = dir.lastPathComponent
                var worktree: String?
                // A worktree's .git is a file: "gitdir: /repo/.git/worktrees/<name>".
                if !isDir.boolValue,
                   let pointer = try? String(contentsOf: git, encoding: .utf8)
                       .replacingOccurrences(of: "gitdir: ", with: ""),
                   let range = pointer.range(of: "/.git/") {
                    name = URL(fileURLWithPath: String(pointer[..<range.lowerBound])).lastPathComponent
                    worktree = dir.lastPathComponent
                }
                let subtitle = [sub.isEmpty ? nil : sub, worktree.map { "worktree \($0)" }]
                    .compactMap { $0 }.joined(separator: " · ")
                return .init(name: name, subtitle: subtitle, worktree: worktree)
            }
            dir.deleteLastPathComponent()
        }
        let path = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
        return .init(name: URL(fileURLWithPath: cwd).lastPathComponent, subtitle: path)
    }

    /// Metro answers `/status` with "packager-status:running" and lists attached apps at `/json/list`.
    static func probeMetro(_ ports: [Int]) async -> DevServer.Metro? {
        for port in ports {
            guard let status = await get("http://127.0.0.1:\(port)/status"),
                  String(decoding: status, as: UTF8.self).contains("packager-status")
            else { continue }
            var targets: [DevServer.Metro.Target] = []
            if let list = await get("http://127.0.0.1:\(port)/json/list"),
               let entries = try? JSONSerialization.jsonObject(with: list) as? [[String: Any]] {
                for entry in entries {
                    let target = DevServer.Metro.Target(
                        deviceName: entry["deviceName"] as? String ?? entry["title"] as? String ?? "App",
                        app: entry["appId"] as? String ?? entry["description"] as? String ?? entry["title"] as? String)
                    if !targets.contains(target) { targets.append(target) }
                }
            }
            return .init(running: true, port: port, targets: targets)
        }
        return nil
    }

    /// Same as pressing `r` in Metro's terminal: a `reload` broadcast on Metro's `/message`
    /// socket reaches every attached app. Expo only accepts broadcasts from local clients
    /// that send no foreign Origin header, which this is.
    static func reloadApps(port: Int) async -> Bool {
        guard let url = URL(string: "ws://127.0.0.1:\(port)/message") else { return false }
        let socket = session.webSocketTask(with: url)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        do {
            try await socket.send(.string(#"{"version":2,"method":"reload"}"#))
            // Let Metro fan the message out before the socket closes.
            try await Task.sleep(for: .milliseconds(300))
            return true
        } catch {
            return false
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.8
        config.timeoutIntervalForResource = 1.5
        return URLSession(configuration: config)
    }()

    private static func get(_ url: String) async -> Data? {
        guard let url = URL(string: url) else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    /// pid → version, from the state files argent writes for each running tool-server.
    static func argentServerVersions() -> [Int32: String] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".argent")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var versions: [Int32: String] = [:]
        for file in files where file.lastPathComponent.hasPrefix("tool-server") && file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (json["pid"] as? NSNumber)?.int32Value,
                  let version = json["version"] as? String
            else { continue }
            versions[pid] = version
        }
        return versions
    }

    /// Metro port → the simulators whose apps are connected to it, with the app's name.
    /// A simulator app is a process on this Mac whose executable lives in its device's folder.
    static func simulatorClients(of ports: Set<Int>, table: [Int32: ProcessRow]) -> [Int: [String: String]] {
        var result: [Int: [String: String]] = [:]
        for (pid, connected) in LibProc.connections(table.keys, to: ports) {
            guard let command = table[pid]?.command, let (udid, app) = simulatorApp(command) else { continue }
            for port in connected { result[port, default: [:]][udid] = app }
        }
        return result
    }

    /// ".../CoreSimulator/Devices/<UDID>/data/Containers/Bundle/Application/<id>/Maps.app/Maps"
    /// → (UDID, "Maps")
    static func simulatorApp(_ command: String) -> (String, String)? {
        guard let match = command.firstMatch(of: #/CoreSimulator/Devices/([0-9A-Fa-f-]{36})/.*?/([^/]+)\.app//#)
        else { return nil }
        return (String(match.1), String(match.2))
    }

    // MARK: - Process data

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: (taken: Date, table: [Int32: ProcessRow])?

    /// The process list for scans that run every few seconds (dev servers, builds), read
    /// once for all of them: a table taken in the last `maxAge` seconds is reused.
    static func recentProcessTable(maxAge: TimeInterval = 4) -> [Int32: ProcessRow] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached, Date.now.timeIntervalSince(cached.taken) < maxAge { return cached.table }
        let table = LibProc.processTable()
        cached = (.now, table)
        return table
    }

    // MARK: - Stopping

    /// The server, its children, and the package-manager wrappers that launched it
    /// (`npm run`, `npx`, `yarn`, `sh -c`), so the terminal or agent that started it gets its prompt back.
    static func processesToStop(_ pid: Int32, table: [Int32: ProcessRow]) -> [Int32] {
        var protected: Set<Int32> = [0, 1]
        var walker = getpid()
        while walker > 1 {
            protected.insert(walker)
            walker = table[walker]?.ppid ?? 0
        }

        var children: [Int32: [Int32]] = [:]
        for row in table.values { children[row.ppid, default: []].append(row.pid) }
        var tree: [Int32] = []
        var queue = [pid]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            tree.append(next)
            queue.append(contentsOf: children[next] ?? [])
        }

        var wrappers: [Int32] = []
        var parent = table[pid]?.ppid ?? 0
        while parent > 1, let row = table[parent], isWrapper(row) {
            wrappers.append(parent)
            parent = row.ppid
        }
        // Deepest children first, then the server, then its wrappers, so nothing
        // respawns it or reports a crash before it exits.
        return (tree.reversed() + wrappers).filter { !protected.contains($0) }
    }

    static func isWrapper(_ row: ProcessRow) -> Bool {
        let wrappers: Set<String> = ["npm", "npx", "yarn", "pnpm", "bun", "bunx"]
        if wrappers.contains(row.executable) { return true }
        let c = row.command
        if ["npm-cli.js", "npx-cli.js", "/yarn.js", "/yarn.cjs", "pnpm.cjs", "pnpm.mjs", "/.bin/"].contains(where: c.contains) {
            return true
        }
        return ["sh", "bash", "zsh"].contains(row.executable) && c.contains(" -c ")
    }

    /// SIGTERM, then SIGKILL whatever is still alive after a few seconds.
    static func stop(_ pid: Int32) async -> Bool {
        let targets = processesToStop(pid, table: LibProc.processTable())
        guard !targets.isEmpty else { return false }
        for target in targets { kill(target, SIGTERM) }
        for _ in 0..<30 {
            if targets.allSatisfy({ kill($0, 0) != 0 }) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        for target in targets where kill(target, 0) == 0 { kill(target, SIGKILL) }
        try? await Task.sleep(for: .milliseconds(200))
        return kill(pid, 0) != 0
    }
}
