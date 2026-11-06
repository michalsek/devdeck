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
    }

    func testSimctlCommands() {
        XCTAssertEqual(shell("xcrun simctl launch \(udid) com.example.app")?.targets, [.id(udid)])
        XCTAssertEqual(shell("xcrun simctl io booted screenshot /tmp/a.png")?.targets, [.bootedSimulator])
        XCTAssertEqual(shell("cd ios && xcrun simctl shutdown \(udid)")?.releases, [.id(udid)])
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
}
