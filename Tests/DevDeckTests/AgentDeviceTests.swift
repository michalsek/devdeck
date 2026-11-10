import Darwin
import XCTest
@testable import DevDeck

final class AgentDeviceTests: XCTestCase {
    private let udid = "1A2C1BF2-2426-4CFC-9B68-C950566526A5"
    private let launcher = "/Users/me/.t3/userdata/device/targets/t3-669e258bfb303ed88328cc17/agent-device"
    private let now = Date(timeIntervalSince1970: 1_793_973_000)
    private let claude = AgentSession(
        agent: .claude, sessionID: "a", host: "T3 Code", project: .init(name: "weather-app", subtitle: ""))

    /// The claim that blocked a simulator for an hour on 2026-11-06.
    private func incidentClaim(pid: Int = 82362) -> Data {
        Data("""
        {"schemaVersion":3,"deviceKey":"local:apple:ios:\(udid)","session":"t3-8df3016cf2a2eca76eb84e7a","workspace":"/Users/me/work/weather-app","stateDir":"/Users/me/.t3/userdata/device/agent-device","device":{"id":"\(udid)","family":"apple","appleOs":"ios","kind":"simulator","target":"mobile","name":"iPhone 17 Pro"},"ownerPid":\(pid),"ownerStartTime":"Fri Nov  6 12:28:12 2026","ownerToken":"127ec85f-9b17-4e6a-a3b2-e4a074b343dc","createdAtMs":1793964501745,"updatedAtMs":1793969188652,"claimOwnerKind":"open-session"}
        """.utf8)
    }

    private func status(quiet: TimeInterval) -> ClaimStatus {
        ClaimStatus(claim: AgentDeviceClaim(data: incidentClaim(), fileName: "a.json")!, lastActivity: now - quiet)
    }

    // MARK: Commands

    func testT3CodeLauncherNamesItsSession() {
        let call = AgentDeviceCall.parse("\(launcher) open com.example.weather --relaunch")
        XCTAssertEqual(call?.subcommand, "open")
        XCTAssertEqual(call?.session, "t3-669e258bfb303ed88328cc17")
        XCTAssertEqual(call?.devices, [])
        XCTAssertEqual(call?.program, launcher)
        // Quoted, after a cd.
        XCTAssertEqual(AgentDeviceCall.parse("cd app && '\(launcher)' snapshot -i")?.subcommand, "snapshot")
    }

    func testFlagsNameSessionAndDevice() {
        let call = AgentDeviceCall.parse("agent-device --session sim --platform ios --udid \(udid) press @e6")
        XCTAssertEqual(call?.subcommand, "press")
        XCTAssertEqual(call?.session, "sim")
        XCTAssertEqual(call?.devices, [udid])
        XCTAssertEqual(AgentDeviceCall.parse("npx agent-device --serial=emulator-5554 open app")?.devices, ["emulator-5554"])
        XCTAssertEqual(AgentDeviceCall.parse("pnpm exec agent-device devices")?.subcommand, "devices")
    }

    func testCloseWithAnotherSession() {
        let call = AgentDeviceCall.parse("\(launcher) close --session t3-8df3016cf2a2eca76eb84e7a")
        XCTAssertEqual(call?.closes, true)
        XCTAssertEqual(call?.session, "t3-8df3016cf2a2eca76eb84e7a")
    }

    func testOtherCommandsAreNotAgentDevice() {
        XCTAssertNil(AgentDeviceCall.parse("grep -r agent-device Sources"))
        XCTAssertNil(AgentDeviceCall.parse("cat ~/.agent-device/device-claims/a.json"))
        XCTAssertNil(AgentDeviceCall.parse("xcrun simctl list"))
    }

    // MARK: Errors

    func testHolderFromDeviceInUseErrors() {
        XCTAssertEqual(AgentDevice.holder(inError: """
            Error (DEVICE_IN_USE): Device is already in use by session "t3-8df3016cf2a2eca76eb84e7a".
            Hint: Run agent-device session list to inspect active sessions.
            """), "t3-8df3016cf2a2eca76eb84e7a")
        XCTAssertEqual(AgentDevice.holder(inError: #"{"ok":false,"error":{"code":"DEVICE_IN_USE","message":"Device is already in use by workspace session \"cwd_9a_default\".","details":{"session":"cwd_9a_default"}}}"#),
                       "cwd_9a_default")
        XCTAssertEqual(AgentDevice.holder(inError: "DEVICE_IN_USE: device is owned by session t3-abc in workspace /x"), "t3-abc")
        XCTAssertNil(AgentDevice.holder(inError: #"Device is already in use by session "x"."#))
    }

    // MARK: Claims

    func testReadsAClaim() throws {
        let claim = try XCTUnwrap(AgentDeviceClaim(data: incidentClaim(), fileName: "a.json"))
        XCTAssertEqual(claim.deviceID, udid)
        XCTAssertEqual(claim.deviceName, "iPhone 17 Pro")
        XCTAssertEqual(claim.session, "t3-8df3016cf2a2eca76eb84e7a")
        XCTAssertEqual(claim.project, "weather-app")
        XCTAssertEqual(claim.ownerPID, 82362)
        XCTAssertEqual(claim.updated, Date(timeIntervalSince1970: 1_793_969_188.652))
        XCTAssertEqual(claim.eventLog.path,
                       "/Users/me/.t3/userdata/device/agent-device/sessions/t3-8df3016cf2a2eca76eb84e7a/events.ndjson")

        let transient = #"{"session":"transient:screenshot","device":{"id":"x"},"stateDir":"/s","ownerPid":1,"claimOwnerKind":"transient-command"}"#
        XCTAssertNil(AgentDeviceClaim(data: Data(transient.utf8), fileName: "t.json"))
        XCTAssertNil(AgentDeviceClaim(data: Data("{}".utf8), fileName: "e.json"))
    }

    func testWhenAClaimIsStale() {
        var owner = ClaimOwner(session: claude, lastCall: now - 3600)
        XCTAssertEqual(ClaimState.of(status(quiet: 20 * 60), owner: owner, now: now), .active)
        XCTAssertEqual(ClaimState.of(status(quiet: 31 * 60), owner: owner, now: now), .stale(.idle))
        XCTAssertEqual(ClaimState.of(status(quiet: 31 * 60), owner: nil, now: now), .stale(.idle))

        owner.turnEnded = now - 300
        XCTAssertEqual(ClaimState.of(status(quiet: 5 * 60), owner: owner, now: now), .active)
        XCTAssertEqual(ClaimState.of(status(quiet: 11 * 60), owner: owner, now: now), .stale(.turnEnded))

        owner.ended = now - 10
        XCTAssertEqual(ClaimState.of(status(quiet: 15), owner: owner, now: now), .stale(.sessionEnded))
    }

    func testAdviceForAStaleClaim() {
        var owner = ClaimOwner(session: claude, lastCall: now - 3480)
        owner.turnEnded = now - 3300
        let free = DeviceItem(id: "B2", name: "iPhone 17", detail: "", kind: .simulator, platform: .ios, isRunning: true)
        let text = ClaimText.advice(
            deviceName: "iPhone 17 Pro", status: status(quiet: 3480), owner: owner, state: .stale(.turnEnded),
            program: launcher, freeDevices: [free], now: now)
        XCTAssertTrue(text.contains("claimed by agent-device session \"t3-8df3016cf2a2eca76eb84e7a\" (weather-app)"))
        XCTAssertTrue(text.contains("no command for 58 min"))
        XCTAssertTrue(text.contains("waiting or --wait won't help"))
        XCTAssertTrue(text.contains("Ask the user"))
        XCTAssertTrue(text.contains("\(launcher) close --session t3-8df3016cf2a2eca76eb84e7a"))
        XCTAssertTrue(text.contains("iPhone 17 (B2)"))
    }

    func testAdviceForAClaimInUse() {
        let owner = ClaimOwner(session: claude, lastCall: now - 40)
        let text = ClaimText.advice(
            deviceName: "iPhone 17 Pro", status: status(quiet: 40), owner: owner, state: .active,
            program: nil, freeDevices: [], now: now)
        XCTAssertTrue(text.contains("It's in use by Claude Code in T3 Code in weather-app"))
        XCTAssertTrue(text.contains("don't close that session"))
        XCTAssertFalse(text.contains("close --session"))
    }

    func testLauncherNamesItsDevice() {
        let source = """
        const entry = "/x/agent-device.mjs";
        const bound = ["--platform","ios","--udid","\(udid)","--config","/x/hosts/1.json","--session","t3-669e"];
        const refused = new Map();
        """
        XCTAssertEqual(ClaimStore.boundDevice(inLauncher: source), udid)
        XCTAssertNil(ClaimStore.boundDevice(inLauncher: "const bound = [];"))
    }

    func testScanSkipsClaimsOfDaemonsThatAreGone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A live owner (this test) whose session logged a command a minute ago.
        let state = dir.appendingPathComponent("state")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: incidentClaim(pid: Int(getpid()))) as? [String: Any])
        json["stateDir"] = state.path
        try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("live.json"))
        let log = state.appendingPathComponent("sessions/t3-8df3016cf2a2eca76eb84e7a/events.ndjson")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: log)
        let logged = Date.now - 60
        try FileManager.default.setAttributes([.modificationDate: logged], ofItemAtPath: log.path)

        // An owner that's gone: agent-device takes that device back by itself.
        json["ownerPid"] = 999_999
        json["session"] = "t3-gone"
        try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("gone.json"))

        let found = ClaimStore.scan(dir)
        XCTAssertEqual(found.map(\.claim.session), ["t3-8df3016cf2a2eca76eb84e7a"])
        XCTAssertEqual(found.first?.lastActivity.timeIntervalSince1970 ?? 0, logged.timeIntervalSince1970, accuracy: 1)
    }

    func testCodexGetsNoFailureHook() {
        XCTAssertTrue(HookInstaller.hooks(for: .claude).contains { $0.event == "PostToolUseFailure" })
        XCTAssertFalse(HookInstaller.hooks(for: .codex).contains { $0.event == "PostToolUseFailure" })
        XCTAssertTrue(HookInstaller.hooks(for: .codex).contains { $0.event == "PostToolUse" && $0.matcher == "Bash" })
    }
}
