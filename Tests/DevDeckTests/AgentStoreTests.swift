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
        ].map { ($0.pid, $0) })
        let metro = DevServer(
            pid: 102, ports: [8082], kind: "Metro · Expo", group: .devServer, isWeb: false, command: "", cwd: nil,
            project: .init(name: "app", subtitle: ""), started: nil)

        let owned = AgentStore.owned(roots: ["a": 100, "b": 200], table: table, servers: [102: metro], builds: [201])
        // The Metro counts once (its worker is part of it); the emulator is a device to shut
        // down; build daemons serve every build, so they're nobody's leftovers.
        XCTAssertEqual(owned["a"]?.processes.map(\.label), ["Metro · Expo :8082"])
        XCTAssertEqual(owned["a"]?.emulators, ["avd:Pixel_9"])
        XCTAssertEqual(owned["b"]?.processes.map(\.label), ["Xcode build"])

        let left = Leftovers(processes: owned["a"]!.processes + owned["b"]!.processes + owned["b"]!.processes, devices: [
            DeviceItem(id: "avd:Pixel_9", name: "Pixel 9", detail: "", kind: .emulator, platform: .android, isRunning: true),
        ])
        XCTAssertEqual(left.summary, "Pixel 9, Metro · Expo :8082 and 2 Xcode builds")
    }
}
