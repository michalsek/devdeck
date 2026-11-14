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
        // Its own Metro, say a subagent's in a worktree.
        XCTAssertNil(policy([simulator], servers: servers, owners: [7: weather]).refusal(tap))
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

    func testKillsAreJudgedByWhoStartedTheProcessesTheyHit() {
        func row(_ pid: Int32, _ name: String, _ command: String, ppid: Int32 = 1) -> (Int32, ServerScanner.ProcessRow) {
            (pid, .init(pid: pid, ppid: ppid, started: nil, command: command, name: name))
        }
        let processes = Dictionary(uniqueKeysWithValues: [
            row(100, "claude", "claude"),
            row(101, "zsh", "/bin/zsh -c nice yarn expo start --port 8082", ppid: 100),
            row(102, "node", "node /weather/node_modules/.bin/expo start --port 8082", ppid: 101),
            row(7, "node", "node /maps/node_modules/.bin/expo start --port 8081"),
            row(300, "node", "node /home/scripts/jest --watch"),
            // argent's tool server starts emulators for the agents that boot them.
            row(500, "node", "node /lib/argent/dist/tool-server.cjs start"),
            row(501, "qemu-system-aarc", "qemu-system-aarch64 -avd Pixel_9", ppid: 500),
            row(502, "qemu-system-aarc", "qemu-system-aarch64 -avd Pixel_8", ppid: 500),
            row(13, "Simulator", "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator"),
        ])
        let policy = CallPolicy(
            devices: DeviceIndex(devices: []),
            servers: [metro(7, port: 8081, project: "maps-app"), metro(102, port: 8082, project: "weather-app")],
            builds: [], leases: [:], owners: [7: maps], androidTesting: .anyDevice, metroWarned: [],
            processes: processes, agents: [100: weather], booted: ["avd:Pixel_9": weather, "avd:Pixel_8": maps])
        let maps8081 = "maps-app's Metro on :8081 (Codex · maps-app started it)"
        let cases: [(String, CallPolicy.Reach?)] = [
            // As logged: only the session's own Metro matches.
            (#"pkill -f "expo start --port 8082"; kill 44981 2>/dev/null; xcrun simctl shutdown \#(sim) 2>&1 | tail -1"#, nil),
            ("kill 102", nil),
            ("pkill -f nothing-runs-like-this", nil),
            ("pkill -f 'avd Pixel_9'", nil),
            ("pkill -f 'avd Pixel_8'", .needsOK(
                .init(segment: "pkill -f 'avd Pixel_8'", effect: "stops the Pixel_8 emulator (pid 502, Codex · maps-app started it)"),
                wait: CallPolicy.killWait)),
            (#"xcrun simctl shutdown \#(sim); pkill -f "expo start --port 8081""#,
             .needsOK(.init(segment: #"pkill -f "expo start --port 8081""#, effect: "stops " + maps8081), wait: CallPolicy.killWait)),
            ("kill $(lsof -ti:8081)", .needsOK(.init(segment: "kill $(lsof -ti:8081)", effect: "stops " + maps8081), wait: CallPolicy.killWait)),
            ("pkill -f jest", .refused(.notOnlyYours(
                reason: "DevDeck: `pkill -f jest` would stop node (pid 300, you or another app started it), which DevDeck"
                    + " can't tie to you, so nothing in this command was run. If they are yours, stop them by pid: kill 300."
                    + " Otherwise leave them alone.",
                segment: "pkill -f jest"))),
            ("killall Simulator", .needsOK(
                .init(segment: "killall Simulator", effect: "quits Simulator, which closes every simulator window"), wait: nil)),
            ("xcrun simctl shutdown all", .needsOK(.init(segment: "xcrun simctl shutdown all", effect: "shuts down every simulator"), wait: nil)),
            (#"pkill -f "expo start""#, .refused(.notOnlyYours(
                reason: #"DevDeck: `pkill -f "expo start"` would also stop "# + maps8081
                    + ", so nothing in this command was run. To stop only your own processes, run: kill 101 102.",
                segment: #"pkill -f "expo start""#))),
        ]
        for (command, expected) in cases {
            let event = HookEvent(json: [
                "agent": "claude", "session_id": "a", "hook_event_name": "PreToolUse", "tool_name": "Bash",
                "tool_input": ["command": command], "agent_pid": 100,
            ])!
            XCTAssertEqual(policy.reach(event, by: weather), expected, command)
        }
    }
}
