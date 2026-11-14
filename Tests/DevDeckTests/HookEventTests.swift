import DevDeckProtocol
import XCTest
@testable import DevDeck

final class HookEventTests: XCTestCase {
    private let udid = "6F1B2D9C-3A4E-4F5B-8C7D-1E2F3A4B5C6D"

    private func event(_ tool: String, _ input: [String: Any], agent: String = "claude") -> HookEvent? {
        HookEvent(json: [
            "agent": agent, "session_id": "s1", "cwd": "/tmp/app", "hook_event_name": "PreToolUse",
            "tool_name": tool, "tool_input": input,
        ])
    }

    private func shell(_ command: String) -> HookEvent? { event("Bash", ["command": command]) }

    func testArgentToolsNameTheirDevice() {
        let tap = event("mcp__argent__gesture-tap", ["udid": udid, "x": 0.5, "y": 0.5])
        XCTAssertEqual(tap?.targets, [.id(udid)])
        XCTAssertEqual(tap?.action, "gesture-tap")

        let boot = event("mcp__argent__boot-device", ["avdName": "Pixel_9"], agent: "codex")
        XCTAssertEqual(boot?.targets, [.id("avd:Pixel_9")])
        XCTAssertEqual(boot?.agent, .codex)

        let stop = event("mcp__argent__stop-all-simulator-servers", ["devices": [udid, "emulator-5554"]])
        XCTAssertEqual(stop?.releases, [.id(udid), .id("emulator-5554")])
        XCTAssertEqual(stop?.targets, [])

        // No device: nothing to show.
        XCTAssertNil(event("mcp__argent__list-devices", [:]))
        // It compares two files; the device it names isn't touched.
        XCTAssertNil(event("mcp__argent__screenshot-diff", ["udid": udid, "baselinePath": "/a.png", "currentPath": "/b.png"]))
    }

    func testSimctlCommands() {
        XCTAssertEqual(shell("xcrun simctl launch \(udid) com.example.app")?.targets, [.id(udid)])
        XCTAssertEqual(shell("xcrun simctl io booted screenshot /tmp/a.png")?.targets, [.bootedSimulator])
        XCTAssertEqual(shell("cd ios && xcrun simctl shutdown \(udid)")?.stops, [.id(udid)])
        XCTAssertEqual(shell("xcrun simctl shutdown all")?.releases, [.allSimulators])
        XCTAssertNil(shell("xcrun simctl list devices booted -j"))
    }

    func testAdbAndEmulatorCommands() {
        XCTAssertEqual(shell("adb -s emulator-5554 shell input tap 10 10")?.targets, [.id("emulator-5554")])
        XCTAssertEqual(shell("ANDROID_SERIAL=R5CT123 adb install app.apk")?.targets, [.id("R5CT123")])
        XCTAssertEqual(shell("$ANDROID_HOME/platform-tools/adb reverse tcp:8081 tcp:8081")?.targets, [.defaultAndroid])
        XCTAssertEqual(shell("adb -s emulator-5554 emu kill")?.releases, [.id("emulator-5554")])
        XCTAssertEqual(shell("emulator -avd Medium_Phone -no-window &")?.targets, [.id("avd:Medium_Phone")])
        XCTAssertNil(shell("adb devices -l"))
        XCTAssertNil(shell("grep -r adb README.md"))
        XCTAssertNil(shell("npm test"))
    }

    func testAgentDeviceCommands() {
        let launcher = "/Users/me/.t3/userdata/device/targets/t3-669e258bfb303ed88328cc17/agent-device"
        // T3 Code's launcher: no device on the command line, LeaseStore finds it.
        let open = shell("\(launcher) open com.example.app --relaunch")
        XCTAssertEqual(open?.kind, .toolUse)
        XCTAssertEqual(open?.action, "agent-device open")
        XCTAssertEqual(open?.targets, [])
        XCTAssertEqual(open?.agentDevice?.session, "t3-669e258bfb303ed88328cc17")

        XCTAssertEqual(shell("agent-device --udid \(udid) press @e6")?.targets, [.id(udid)])
        XCTAssertEqual(shell("agent-device --udid \(udid) close")?.releases, [.id(udid)])
    }

    func testDeviceInUseAfterACommand() {
        let error = #"Error (DEVICE_IN_USE): Device is already in use by session "t3-8df3016cf2a2eca76eb84e7a"."#
        let event = HookEvent(json: [
            "agent": "claude", "session_id": "s1", "hook_event_name": "PostToolUseFailure", "tool_name": "Bash",
            "tool_input": ["command": "agent-device open app"], "tool_output": error,
        ])
        XCTAssertEqual(event?.kind, .deviceInUse)
        XCTAssertEqual(event?.holder, "t3-8df3016cf2a2eca76eb84e7a")
        XCTAssertEqual(event?.agentDevice?.subcommand, "open")

        XCTAssertNil(HookEvent(json: [
            "agent": "codex", "session_id": "s1", "hook_event_name": "PostToolUse", "tool_name": "Bash",
            "tool_input": ["command": "ls"], "tool_output": "fine",
        ]))
    }

    func testSessionEnd() {
        let end = HookEvent(json: ["agent": "claude", "session_id": "s1", "hook_event_name": "SessionEnd"])
        XCTAssertEqual(end?.kind, .sessionEnd)
        XCTAssertNil(HookEvent(json: ["agent": "other", "session_id": "s1", "hook_event_name": "SessionEnd"]))
    }

    func testWaiterNamesDevicesByTheirIDsAndNeedsNoRoomToBootARunningDevice() {
        var pixel = DeviceItem(id: "avd:Pixel_9", name: "Pixel 9", detail: "", kind: .emulator, platform: .android, isRunning: true)
        pixel.serial = "emulator-5554"
        let devices = DeviceIndex(devices: [pixel])
        let session = AgentSession(agent: .claude, sessionID: "s1", host: nil, project: .init(name: "app", subtitle: ""))
        let now = Date(timeIntervalSince1970: 1_000_000)

        let install = shell("adb -s emulator-5554 install app.apk")!
        let waiter = LeaseBook.Waiter(install, session: session, claimDevices: [], devices: devices, now: now)
        XCTAssertEqual(waiter.devices, ["avd:Pixel_9"])
        XCTAssertEqual(waiter.deadline, now + 540)

        let boot = event("mcp__argent__boot-device", ["avdName": "Pixel_9"])!
        XCTAssertEqual(boot.pools, [.androidEmulator])
        XCTAssertEqual(LeaseBook.Waiter(boot, session: session, claimDevices: [], devices: devices, now: now).pools, [])

        // T3 Code's launcher names no device; its session's claim does.
        let open = shell("/u/.t3/userdata/device/targets/t3-1/agent-device open app")!
        let claimed = LeaseBook.Waiter(open, session: session, claimDevices: ["emulator-5554"], devices: devices, now: now)
        XCTAssertEqual(claimed.devices, ["avd:Pixel_9"])
    }

    func testCommandsThatReachPastTheAgentsOwnWork() {
        let effects: [(String, String?)] = [
            ("cd ios && xcrun simctl shutdown all", "xcrun simctl shutdown all"),
            ("xcrun simctl shutdown \(udid)", nil),
            ("adb kill-server; adb devices", "adb kill-server"),
            ("sudo launchctl kickstart -k system/com.apple.CoreSimulator.CoreSimulatorService",
             "sudo launchctl kickstart -k system/com.apple.CoreSimulator.CoreSimulatorService"),
            // Judged by the processes they hit, not by their text.
            ("killall Simulator", nil),
        ]
        for (command, segment) in effects {
            XCTAssertEqual(CommandGuard.everyoneEffect(command)?.segment, segment, command)
        }
        XCTAssertNotNil(CommandGuard.everyoneEffect(argent: "stop-all-simulator-servers", [:]))
        XCTAssertNil(CommandGuard.everyoneEffect(argent: "stop-all-simulator-servers", ["devices": [udid]]))

        let kills: [(String, [CommandGuard.Kill.Target])] = [
            ("kill -9 4122 4123", [.pid(4122), .pid(4123)]),
            ("kill $(lsof -ti:8081)", [.port(8081)]),
            ("lsof -t -i tcp:8082 | xargs kill", [.port(8082)]),
            ("npx kill-port 8083", [.port(8083)]),
            ("lsof -i :8081", []),
            ("killall -s node", []),
        ]
        for (command, targets) in kills {
            XCTAssertEqual(CommandGuard.kills(command).map(\.target), targets, command)
        }
        // Each names the part of the command it came from.
        XCTAssertEqual(
            shell(#"xcrun simctl shutdown \#(udid); pkill -f "expo start --port 8082""#)?.kills.map(\.segment),
            [#"pkill -f "expo start --port 8082""#])
    }

    func testPkillAndKillallMatchProcessesTheWayTheToolsDo() {
        func row(_ pid: Int32, _ name: String, _ command: String, ppid: Int32 = 1) -> ServerScanner.ProcessRow {
            .init(pid: pid, ppid: ppid, started: Date(timeIntervalSince1970: TimeInterval(pid)), command: command, name: name)
        }
        let table = Dictionary(uniqueKeysWithValues: [
            row(10, "node", "node /app/node_modules/.bin/expo start --port 8082 --dev-client"),
            row(11, "node", "node /web/node_modules/.bin/expo start --port 8081"),
            row(12, "node", "node /app/node_modules/.bin/jest --watch", ppid: 10),
            row(13, "Simulator", "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator"),
            row(14, "qemu-system-aarc", "qemu-system-aarch64 -avd Pixel_9"),
        ].map { ($0.pid, $0) })
        let cases: [(String, [Int32])] = [
            (#"pkill -f "expo start --port 8082""#, [10]),
            (#"pkill -9 -f 'expo start'"#, [10, 11]),
            ("pkill node", [10, 11, 12]),
            ("pkill -x nod", []),
            ("pkill -fi SIMULATOR.APP", [13]),
            ("pkill -n node", [12]),
            ("pkill -P 10", [12]),
            ("pkill -f qemu-system", [14]),
            ("pkill -f 'unclosed(", []),
            ("killall Simulator", [13]),
            ("killall -KILL qemu-system-aarch64", [14]),
            ("killall -m 'qemu.*'", [14]),
            ("killall nod", []),
        ]
        for (command, pids) in cases {
            guard case .processes(let pattern)? = CommandGuard.kills(command).first?.target else {
                XCTFail("no pattern: \(command)")
                continue
            }
            XCTAssertEqual(pattern.matches(in: table, excluding: []).map(\.pid), pids, command)
        }
        // pkill skips the shell that runs it and that shell's ancestors.
        guard case .processes(let node)? = CommandGuard.kills("pkill node").first?.target else { return XCTFail() }
        XCTAssertEqual(node.matches(in: table, excluding: [10]).map(\.pid), [11, 12])
    }

    func testPhysicalDeviceCommandsNameTheirDevice() {
        let phone = "00008150-0011223344556677"
        XCTAssertEqual(shell("xcrun devicectl device install app --device \(phone) App.app")?.targets, [.id(phone)])
        XCTAssertEqual(shell("xcrun devicectl device process launch -d \(phone) com.example")?.action, "devicectl device process")
        XCTAssertEqual(
            shell("xcodebuild -workspace A.xcworkspace -scheme A -destination 'platform=iOS,id=\(phone)' build")?.targets,
            [.id(phone)])
        XCTAssertEqual(shell("npx expo run:ios --device \(phone)")?.targets, [.id(phone)])
        XCTAssertEqual(shell("npx react-native run-android --deviceId R5CT123")?.targets, [.id("R5CT123")])
        XCTAssertEqual(shell("xcrun devicectl list devices")?.targets ?? [], [])
    }

    func testDeviceCommandResults() {
        let phone = "00008150-0011223344556677"
        let failed: [String: Any] = [
            "hook_event_name": "PostToolUseFailure", "tool_name": "Bash",
            "tool_input": ["command": "xcrun devicectl device process launch --device \(phone) com.example"],
            "error": "ERROR: The device is locked.",
        ]
        XCTAssertTrue(HookProtocol.isRelevant(failed))
        XCTAssertEqual(HookProtocol.resultOutput(failed), "ERROR: The device is locked.")
        var forwarded = failed
        forwarded["agent"] = "claude"
        forwarded["session_id"] = "s1"
        forwarded["tool_output"] = HookProtocol.resultOutput(failed)
        let event = HookEvent(json: forwarded)
        XCTAssertEqual(event?.kind, .result(failed: true))
        XCTAssertEqual(event?.targets, [.id(phone)])

        XCTAssertNil(HookProtocol.resultOutput([
            "hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_input": ["command": "adb devices"],
            "tool_response": ["stdout": "List of devices attached"],
        ]))
    }
}
