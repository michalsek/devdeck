import XCTest
@testable import DevDeck

final class CallPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let sim = "6F1B2D9C-3A4E-4F5B-8C7D-1E2F3A4B5C6D"
    private let weather = AgentSession(agent: .claude, sessionID: "a", host: nil, project: .init(name: "weather-app", subtitle: ""))
    private let maps = AgentSession(agent: .codex, sessionID: "b", host: nil, project: .init(name: "maps-app", subtitle: ""))

    private func device(_ id: String, _ kind: DeviceItem.Kind, _ platform: DeviceItem.Platform,
                        problem: DeviceProblem? = nil) -> DeviceItem {
        var item = DeviceItem(id: id, name: id, detail: "", kind: kind, platform: platform, isRunning: true)
        item.problem = problem
        return item
    }

    private func metro(_ pid: Int32, port: Int, project: String) -> DevServer {
        DevServer(
            pid: pid, ports: [port], kind: "Metro", group: .devServer, isWeb: false, command: "", cwd: nil,
            project: .init(name: project, subtitle: ""), started: nil,
            metro: .init(running: true, port: port, simulators: [sim: "Maps"]))
    }

    private func policy(_ devices: [DeviceItem], servers: [DevServer] = [], owners: [Int32: AgentSession] = [:],
                        android: AppSettings.AndroidTesting = .anyDevice, warned: Set<String> = []) -> CallPolicy {
        CallPolicy(
            devices: DeviceIndex(devices: devices), servers: servers, builds: [], leases: [:], owners: owners,
            androidTesting: android, metroWarned: warned)
    }

    private func call(_ action: String, _ devices: [String], pools: [Pool] = []) -> LeaseBook.Waiter {
        LeaseBook.Waiter(
            id: UUID(), session: weather, action: action, devices: devices, releases: [], since: now,
            deadline: now + 540, pools: pools)
    }

    func testAndroidOnPhonesOnly() {
        let emulator = device("avd:Pixel_9", .emulator, .android)
        let phone = device("R5CT123", .physical, .android)
        let boot = call("boot-device", ["avd:Pixel_9"], pools: [.androidEmulator])

        XCTAssertNil(policy([emulator]).refusal(boot))
        guard case .phonesOnly(let reason, let noPhone)? = policy([emulator, phone], android: .phonesOnly).refusal(boot)
        else { return XCTFail("emulator allowed") }
        XCTAssertFalse(noPhone)
        XCTAssertTrue(reason.contains("adb -s R5CT123"))
        guard case .phonesOnly(_, true)? = policy([emulator], android: .phonesOnly).refusal(boot) else {
            return XCTFail("no phone not flagged")
        }
        XCTAssertNil(policy([phone], android: .phonesOnly).refusal(call("adb install", ["R5CT123"])))
    }

    func testWarnsOnceAboutAnotherCheckoutsMetro() {
        let simulator = device(sim, .simulator, .ios)
        let servers = [metro(7, port: 8081, project: "maps-app")]
        let tap = call("gesture-tap", [sim])
        guard case .wrongMetro(_, let key)? = policy([simulator], servers: servers).refusal(tap) else {
            return XCTFail("no warning")
        }
        XCTAssertNil(policy([simulator], servers: servers, warned: [key]).refusal(tap))
        // Pointing the app at another Metro is how it gets fixed.
        XCTAssertNil(policy([simulator], servers: servers).refusal(call("simctl launch", [sim])))
    }

    func testPhonesThatNeedTheUser() {
        let cases: [(DeviceProblem?, String, [Pool], String?)] = [
            (.locked, "devicectl device process", [], "R5 is locked: unlock it"),
            (.locked, "devicectl device install", [], nil),
            (.locked, "xcodebuild", [.build], nil),
            (.untrusted, "devicectl device install", [], "R5 doesn't trust this Mac yet: unlock it and tap Trust"),
            (nil, "devicectl device process", [], nil),
        ]
        for (problem, action, pools, expected) in cases {
            let devices = DeviceIndex(devices: [device("R5", .physical, .ios, problem: problem)])
            XCTAssertEqual(CallPolicy.needsUser(call(action, ["R5"], pools: pools), devices: devices), expected, action)
        }
    }

    func testStoppingSomeoneElsesServerNeedsTheUsersOK() {
        let servers = [metro(7, port: 8081, project: "maps-app")]
        func event(_ command: String) -> HookEvent {
            HookEvent(json: [
                "agent": "claude", "session_id": "a", "hook_event_name": "PreToolUse", "tool_name": "Bash",
                "tool_input": ["command": command],
            ])!
        }
        let kill = event("kill $(lsof -ti:8081)")
        XCTAssertEqual(
            policy([], servers: servers, owners: [7: maps]).approval(kill, by: weather),
            "stops maps-app's Metro on :8081 (Codex · maps-app started it)")
        XCTAssertNil(policy([], servers: servers, owners: [7: weather]).approval(kill, by: weather))
        XCTAssertNotNil(policy([], servers: servers).approval(event("kill 7"), by: weather))
        XCTAssertEqual(policy([]).approval(event("killall Simulator"), by: weather), CommandGuard.everyoneEffect("killall Simulator"))
    }
}
