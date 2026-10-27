import Darwin
import XCTest
@testable import DevDeck

final class ServerScannerTests: XCTestCase {
    private func row(_ pid: Int32, _ ppid: Int32, _ command: String) -> ServerScanner.ProcessRow {
        .init(pid: pid, ppid: ppid, started: nil, command: command)
    }

    func testClassify() {
        XCTAssertEqual(ServerScanner.classify("node /p/node_modules/.bin/expo run:ios --port 8082").0, "Metro · Expo")
        XCTAssertEqual(ServerScanner.classify("node /p/node_modules/.bin/react-native start").0, "Metro · React Native")
        XCTAssertEqual(ServerScanner.classify("node /p/node_modules/.bin/vite --port 5173").0, "Vite")
        XCTAssertEqual(ServerScanner.classify("node /p/node_modules/next/dist/server/lib/start-server.js").0, "Next.js")
        XCTAssertEqual(ServerScanner.classify("python3 manage.py runserver").0, "Django")
        let argent = ServerScanner.classify("node /lib/node_modules/@swmansion/argent/dist/tool-server.cjs start")
        XCTAssertEqual(argent.0, "Tool server")
        XCTAssertEqual(argent.1, .agentTool)
        XCTAssertEqual(ServerScanner.classify("node server.js").0, "Node server")
    }

    /// Server, its children and its npm/sh wrappers are stopped; the terminal shell above them isn't.
    func testProcessesToStopIncludesTreeAndWrappersOnly() {
        let table: [Int32: ServerScanner.ProcessRow] = [
            100: row(100, 1, "/bin/zsh -il"),
            200: row(200, 100, "node /usr/local/lib/node_modules/npm/bin/npm-cli.js run dev"),
            300: row(300, 200, "sh -c vite --port 5173"),
            400: row(400, 300, "node /p/node_modules/.bin/vite --port 5173"),
            500: row(500, 400, "/p/node_modules/esbuild/bin/esbuild --service"),
            600: row(600, 100, "node unrelated.js"),
        ]
        let targets = ServerScanner.processesToStop(400, table: table)
        XCTAssertEqual(targets, [500, 400, 300, 200], "children first, then the server, then wrappers")
        XCTAssertFalse(targets.contains(100))
        XCTAssertFalse(targets.contains(600))
    }

    /// An agent's `bash -c` wrapper goes; the agent process itself stays.
    func testProcessesToStopStopsAtAgent() {
        let table: [Int32: ServerScanner.ProcessRow] = [
            10: row(10, 1, "/Applications/T3 Code.app/Contents/MacOS/T3 Code"),
            20: row(20, 10, "/Users/me/.local/bin/claude --output-format stream-json"),
            30: row(30, 20, "/bin/zsh -c npx expo start"),
            40: row(40, 30, "node /p/node_modules/.bin/expo start"),
        ]
        XCTAssertEqual(ServerScanner.processesToStop(40, table: table), [40, 30])
    }

    func testProcessesToStopNeverIncludesThisProcess() {
        let me = getpid()
        let table: [Int32: ServerScanner.ProcessRow] = [
            me: row(me, 1, "node /p/node_modules/.bin/vite"),
        ]
        XCTAssertEqual(ServerScanner.processesToStop(me, table: table), [])
    }

    func testProjectNameForWorktree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("myrepo")
        let worktree = root.appendingPathComponent("wt/feature-x")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("apps/web"), withIntermediateDirectories: true)
        try "gitdir: \(repo.path)/.git/worktrees/feature-x\n"
            .write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let project = ServerScanner.project(for: worktree.appendingPathComponent("apps/web").path, fallback: "node")
        XCTAssertEqual(project.name, "myrepo")
        XCTAssertEqual(project.subtitle, "apps/web · worktree feature-x")
        XCTAssertEqual(ServerScanner.project(for: repo.path, fallback: "node").name, "myrepo")
    }

    /// End to end: a real server behind an `sh -c` wrapper is found by the scan and stopped with its wrapper.
    func testScanFindsAndStopsARealServer() async throws {
        let port = 48_000 + Int.random(in: 0..<1000)
        let wrapper = Process()
        wrapper.executableURL = URL(fileURLWithPath: "/bin/sh")
        wrapper.arguments = ["-c", "python3 -m http.server \(port) --bind 127.0.0.1; true"]
        wrapper.standardOutput = FileHandle.nullDevice
        wrapper.standardError = FileHandle.nullDevice
        try wrapper.run()
        defer { if wrapper.isRunning { wrapper.terminate() } }

        var server: DevServer?
        for _ in 0..<50 where server == nil {
            try await Task.sleep(for: .milliseconds(200))
            server = await ServerScanner.scan().first { $0.ports.contains(port) }
        }
        let found = try XCTUnwrap(server, "scan should list the python server")
        XCTAssertEqual(found.kind, "Static server")
        XCTAssertTrue(found.isWeb)

        let stopped = await ServerScanner.stop(found.pid)
        XCTAssertTrue(stopped)
        for _ in 0..<20 where wrapper.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(wrapper.isRunning, "the sh -c wrapper should be stopped too")
    }
}
