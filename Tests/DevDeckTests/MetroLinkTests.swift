import XCTest
@testable import DevDeck

final class MetroLinkTests: XCTestCase {
    private let sim = "6F1B2D9C-3A4E-4F5B-8C7D-1E2F3A4B5C6D"

    private func metro(_ pid: Int32, port: Int, project: String, worktree: String? = nil,
                       targets: [(String, String?)] = [], simulators: [String: String] = [:]) -> DevServer {
        DevServer(
            pid: pid, ports: [port], kind: "Metro", group: .devServer, isWeb: false, command: "node metro",
            cwd: nil, project: .init(name: project, subtitle: "", worktree: worktree), started: nil,
            metro: .init(running: true, port: port, targets: targets.map { .init(deviceName: $0.0, app: $0.1) },
                         simulators: simulators))
    }

    private func android(_ name: String, model: String, reverse: [Int]) -> DeviceItem {
        var device = DeviceItem(id: "avd:" + name, name: name, detail: "", kind: .emulator, platform: .android, isRunning: true)
        device.model = model
        device.reversePorts = reverse
        return device
    }

    func testFindsTheMetroADevicesAppLoads() {
        let simulator = DeviceItem(id: sim, name: "iPhone 17 Pro", detail: "", kind: .simulator, platform: .ios, isRunning: true)
        let phone = DeviceItem(id: "0000-1", name: "Test iPhone", detail: "", kind: .physical, platform: .ios, isRunning: true)
        let servers = [
            metro(1, port: 8081, project: "maps-app", targets: [("iPhone 17 Pro", nil), ("sdk_gphone64_arm64", "a")]),
            metro(2, port: 8083, project: "weather-app", targets: [("Test iPhone", "com.example.weather"), ("sdk_gphone64_arm64", "b")],
                  simulators: [sim: "Weather"]),
        ]
        // A simulator by its app's connection, not by the name another app reported.
        XCTAssertEqual(servers.metro(for: simulator), MetroLink(server: servers[1], app: "Weather"))
        XCTAssertEqual(servers.metro(for: phone)?.server.pid, 2)
        // Two Metros know an app on this model: adb reverse picks one, or neither.
        XCTAssertEqual(servers.metro(for: android("Pixel", model: "sdk_gphone64_arm64", reverse: [8081]))?.server.pid, 1)
        XCTAssertNil(servers.metro(for: android("Pixel", model: "sdk_gphone64_arm64", reverse: [])))
        // One Metro knows the model, but this emulator's app isn't reversed to it.
        XCTAssertNil([servers[0]].metro(for: android("Pixel", model: "sdk_gphone64_arm64", reverse: [])))

        let link = MetroLink(server: metro(3, port: 8081, project: "app", worktree: "fix"), app: nil)
        XCTAssertTrue(link.isWrong(for: .init(name: "other", subtitle: "")))
        XCTAssertTrue(link.isWrong(for: .init(name: "app", subtitle: "")))
        XCTAssertFalse(link.isWrong(for: .init(name: "app", subtitle: "apps/mobile", worktree: "fix")))
    }

    func testSimulatorAppFromItsProcess() {
        let command = "/Users/me/Library/Developer/CoreSimulator/Devices/\(sim)/data/Containers/Bundle/Application/"
            + "0A1B2C3D-0000-0000-0000-000000000000/Weather.app/Weather"
        XCTAssertEqual(ServerScanner.simulatorApp(command)?.0, sim)
        XCTAssertEqual(ServerScanner.simulatorApp(command)?.1, "Weather")
        XCTAssertNil(ServerScanner.simulatorApp("/usr/bin/node metro"))
    }

    func testRecognizesCommandsThatStartMetro() {
        let packages = [
            "/r/app/package.json": #"{"scripts": {"start": "expo start --port 8090", "dev": "vite"}}"#,
            "/r/web/package.json": #"{"scripts": {"start": "next dev"}}"#,
        ]
        func find(_ command: String, cwd: String = "/r/app") -> MetroStart? {
            MetroStart.find(in: command, cwd: cwd) { packages[$0] }
        }
        XCTAssertEqual(find("npx expo start --clear")?.port, 8081)
        XCTAssertEqual(find("npx expo start --clear")?.command(), "npx expo start --clear")
        XCTAssertEqual(find("RCT_METRO_PORT=8085 npx react-native start")?.port, 8085)
        XCTAssertEqual(find("cd app && npm start", cwd: "/r")?.directory, "/r/app")
        XCTAssertEqual(find("cd app && npm start", cwd: "/r")?.port, 8090)
        XCTAssertNil(find("npm run dev"))
        XCTAssertNil(find("npm start", cwd: "/r/web"))
        XCTAssertNil(find("npx expo run:ios"))
        // Setup before the start would be lost, so the agent runs it itself.
        XCTAssertNil(find("export EXPO_PUBLIC_API=x && npx expo start"))
        XCTAssertNil(find("nvm use 20 && npx expo start"))
        // DevDeck keeps the log; the command's own redirections go.
        XCTAssertEqual(
            find("nohup npx expo start --port 8082 > /tmp/metro.log 2>&1 &")?.command(), "nohup npx expo start --port 8082")
        XCTAssertEqual(find("cd /r/app; npm start")?.command(port: 8091), "npm start -- --port 8091")
        XCTAssertEqual(find("yarn start")?.command(port: 8091), "yarn start --port 8091")
        XCTAssertEqual(find("EXPO_PUBLIC_NAME='my app' npx expo start")?.command(), "'EXPO_PUBLIC_NAME=my app' npx expo start")
    }

    func testSpawnRunsTheCommandInItsFolderWithItsLog() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-spawn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("out.log").path
        let pid = try XCTUnwrap(MetroKeeper.spawn(
            ["/bin/sh", "-c", "pwd; echo $GREETING >&2"], directory: folder.path, log: log, environment: ["GREETING": "hi"]))
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let output = try String(contentsOfFile: log, encoding: .utf8)
        XCTAssertTrue(output.hasSuffix("devdeck-spawn-\(folder.lastPathComponent.dropFirst(14))\nhi\n"), output)
    }
}
