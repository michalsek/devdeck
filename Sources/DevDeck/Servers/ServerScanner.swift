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
    }

    struct Metro: Hashable {
        let running: Bool
        let apps: [String]
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
        let listening = listeningPorts()
        let table = processTable()
        let candidates = listening.keys.compactMap { pid -> ProcessRow? in
            guard let row = table[pid],
                  isRuntime(row.executable),
                  !isBundledInApp(row.command)
            else { return nil }
            return row
        }
        let candidatePIDs = Set(candidates.map(\.pid))
        let cwds = workingDirectories(Array(candidatePIDs))

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
                return .init(name: name, subtitle: subtitle)
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
            var apps: [String] = []
            if let list = await get("http://127.0.0.1:\(port)/json/list"),
               let targets = try? JSONSerialization.jsonObject(with: list) as? [[String: Any]] {
                for target in targets {
                    let name = target["deviceName"] as? String ?? target["title"] as? String ?? "App"
                    if !apps.contains(name) { apps.append(name) }
                }
            }
            return .init(running: true, apps: apps)
        }
        return nil
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

    // MARK: - Process data

    /// pid → listening ports, from `lsof`.
    static func listeningPorts() -> [Int32: Set<Int>] {
        let result = Shell.runSync("lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"])
        var ports: [Int32: Set<Int>] = [:]
        var pid: Int32 = 0
        for line in result.output.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst()) ?? 0
            } else if line.hasPrefix("n"), let port = line.split(separator: ":").last.flatMap({ Int($0) }) {
                ports[pid, default: []].insert(port)
            }
        }
        return ports
    }

    /// Every process with its parent, start time and full command line.
    static func processTable() -> [Int32: ProcessRow] {
        let result = Shell.runSync("ps", ["-A", "-ww", "-o", "pid=,ppid=,lstart=,command="])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        var table: [Int32: ProcessRow] = [:]
        for line in result.output.split(separator: "\n") {
            // pid ppid Www Mmm d hh:mm:ss yyyy command...
            let fields = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
            guard fields.count == 8, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { continue }
            let started = formatter.date(from: fields[2...6].joined(separator: " "))
            table[pid] = ProcessRow(
                pid: pid, ppid: ppid, started: started,
                command: fields[7].trimmingCharacters(in: .whitespaces))
        }
        return table
    }

    static func workingDirectories(_ pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        let result = Shell.runSync("lsof", ["-a", "-d", "cwd", "-Fn", "-p", list])
        var cwds: [Int32: String] = [:]
        var pid: Int32 = 0
        for line in result.output.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) ?? 0 }
            else if line.hasPrefix("n") { cwds[pid] = String(line.dropFirst()) }
        }
        return cwds
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
        let targets = processesToStop(pid, table: processTable())
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
