import XCTest
@testable import DevDeck

final class AgentStoreTests: XCTestCase {
    private func row(_ pid: Int32, _ ppid: Int32, _ command: String) -> ServerScanner.ProcessRow {
        ServerScanner.ProcessRow(pid: pid, ppid: ppid, started: Date(timeIntervalSince1970: TimeInterval(pid)), command: command)
    }

    func testFindsWhatASessionStartedUnderItsProcess() {
        let table = Dictionary(uniqueKeysWithValues: [
            row(100, 1, "claude --session-id a"),
            row(101, 100, "/bin/zsh -c npx expo start"),
            row(102, 101, "node node_modules/.bin/expo start"),
            row(103, 102, "node metro-worker.js"),
            row(104, 100, "/bin/zsh -c emulator -avd Pixel_9"),
            row(105, 104, "/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -netdelay none -avd Pixel_9 -no-window"),
            row(106, 1, "java org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.14"),
            row(200, 1, "codex"),
            row(201, 200, "/usr/bin/xcodebuild -scheme App build"),
            row(202, 200, "java org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.14"),
            row(203, 200, "/usr/bin/xcodebuild test-without-building -xctestrun Runner.xctestrun"),
            // `nohup npx expo start &`: its shell exited, so launchd is its parent.
            row(300, 1, "npm exec expo start --port 8093"),
            row(301, 300, "node node_modules/.bin/expo start --port 8093"),
        ].map { ($0.pid, $0) })
        func server(_ pid: Int32, _ port: Int) -> DevServer {
            DevServer(
                pid: pid, ports: [port], kind: "Metro · Expo", group: .devServer, isWeb: false, command: "", cwd: nil,
                project: .init(name: "app", subtitle: ""), started: nil)
        }
        // A UI-test runner (argent's, agent-device's) isn't a build.
        XCTAssertEqual(ResourceMonitor.buildJobs(in: table).map(\.pid), [201])

        let owned = AgentStore.owned(
            roots: ["a": 100, "b": 200], table: table, servers: [102: server(102, 8082), 301: server(301, 8093)],
            builds: [201]
        ) { $0 == 301 ? "a" : nil }
        // The Metro counts once (its worker is part of it); the orphaned one is found by where
        // it was started; the emulator is a device to shut down; build daemons serve every
        // build, so they're nobody's leftovers.
        XCTAssertEqual(owned["a"]?.processes.map(\.label), ["Metro · Expo :8082", "Metro · Expo :8093"])
        XCTAssertEqual(owned["a"]?.emulators, ["avd:Pixel_9"])
        XCTAssertEqual(owned["b"]?.processes.map(\.label), ["Xcode build"])

        let left = Leftovers(processes: owned["a"]!.processes + owned["b"]!.processes + owned["b"]!.processes, devices: [
            DeviceItem(id: "avd:Pixel_9", name: "Pixel 9", detail: "", kind: .emulator, platform: .android, isRunning: true),
        ])
        XCTAssertEqual(left.summary, "Pixel 9, Metro · Expo :8082, Metro · Expo :8093 and 2 Xcode builds")
    }

    func testSessionAProcessWasStartedIn() {
        let agents: [Int32: String] = [100: "claude:new"]
        let cases: [([String: String], String?)] = [
            (["CLAUDE_CODE_SESSION_ID": "old"], "claude:old"),
            // The agent process carries on in a new session after /clear.
            (["CLAUDE_CODE_SESSION_ID": "old", "CLAUDE_PID": "100"], "claude:new"),
            (["CLAUDE_CODE_SESSION_ID": "old", "CLAUDE_PID": "999"], "claude:old"),
            ([MetroKeeper.sessionVariable: "codex:x"], "codex:x"),
            ([:], nil),
        ]
        for (environment, expected) in cases {
            XCTAssertEqual(AgentStore.starter(environment: environment, agents: agents), expected, "\(environment)")
        }
    }
}
