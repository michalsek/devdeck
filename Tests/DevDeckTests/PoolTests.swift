import XCTest
@testable import DevDeck

final class PoolTests: XCTestCase {
    /// The ceiling holds while memory allows; less fits after the reserve for the user's
    /// apps; a game in front leaves one simulator, emulator or build, not fewer dev servers.
    func testLimitBelowCeiling() {
        let gb: UInt64 = 1 << 30
        let cases: [(Pool, ceiling: Int, used: Int, available: UInt64, apps: UInt64, game: String?, PoolRoom.Limit)] = [
            (.iosSimulator, 2, 0, 12 * gb, 4 * gb, nil, .init(value: 2, reason: nil)),
            // 12 GB free, 2 + 0.25 × 16 = 6 GB kept: room for 2 builds of 4 GB, ceiling 3.
            (.build, 3, 0, 12 * gb, 16 * gb, nil, .init(value: 1, reason: "to leave memory for your apps")),
            // What's running stays inside the limit; only more is held back.
            (.iosSimulator, 4, 2, 3 * gb, 0, nil, .init(value: 2, reason: "to leave memory for your apps")),
            (.iosSimulator, 2, 1, 12 * gb, 0, "Valheim", .init(value: 1, reason: "while Valheim is in front")),
            (.devServer, 3, 0, 12 * gb, 0, "Valheim", .init(value: 3, reason: nil)),
        ]
        for (pool, ceiling, used, available, apps, game, expected) in cases {
            XCTAssertEqual(
                PoolRoom.limit(pool, ceiling: ceiling, used: used, available: available, appsFootprint: apps, game: game),
                expected, "\(pool) ceiling \(ceiling)")
        }
    }

    func testRecognizesBuilds() {
        XCTAssertEqual(Pool.forShell("xcodebuild -workspace App.xcworkspace -scheme App build"), [.build])
        XCTAssertEqual(Pool.forShell("cd android && ./gradlew assembleDebug"), [.build])
        XCTAssertEqual(Pool.forShell("npx expo run:ios --device 'iPhone 17'"), [.build])
        XCTAssertEqual(Pool.forShell("npx react-native run-android"), [.build])
        XCTAssertEqual(Pool.forShell("yarn ios"), [.build])
        XCTAssertEqual(Pool.forShell("eas build -p ios --local"), [.build])
        XCTAssertEqual(Pool.forShell("xcodebuild -list"), [])
        XCTAssertEqual(Pool.forShell("./gradlew --stop"), [])
        XCTAssertEqual(Pool.forShell("./gradlew tasks"), [])
    }

    func testRecognizesDevServers() {
        XCTAssertEqual(Pool.forShell("npx expo start --clear"), [.devServer])
        XCTAssertEqual(Pool.forShell("npm run dev"), [.devServer])
        XCTAssertEqual(Pool.forShell("PORT=3001 pnpm dev"), [.devServer])
        XCTAssertEqual(Pool.forShell("bunx vite --port 5174"), [.devServer])
        XCTAssertEqual(Pool.forShell("next dev"), [.devServer])
        XCTAssertEqual(Pool.forShell("vite build"), [])
        XCTAssertEqual(Pool.forShell("npm test"), [])
        XCTAssertEqual(Pool.forShell("npm install"), [])
    }

    func testRecognizesBoots() {
        XCTAssertEqual(Pool.forShell("xcrun simctl boot 6F1B2D9C-3A4E-4F5B-8C7D-1E2F3A4B5C6D"), [.iosSimulator])
        XCTAssertEqual(Pool.forShell("emulator -avd Pixel_9 -no-window &"), [.androidEmulator])
        XCTAssertEqual(Pool.forArgent("boot-device", ["avdName": "Pixel_9"]), [.androidEmulator])
        XCTAssertEqual(Pool.forArgent("boot-device", ["udid": "6F1B2D9C-3A4E-4F5B-8C7D-1E2F3A4B5C6D"]), [.iosSimulator])
        XCTAssertEqual(Pool.forArgent("gesture-tap", ["udid": "6F1B2D9C-3A4E-4F5B-8C7D-1E2F3A4B5C6D"]), [])
    }

    func testHookEventCarriesPoolsForCommandsWithoutDevices() {
        let event = HookEvent(json: [
            "agent": "claude", "session_id": "s", "hook_event_name": "PreToolUse",
            "tool_name": "Bash", "tool_input": ["command": "cd app && npx expo run:ios"],
        ])
        XCTAssertEqual(event?.pools, [.build])
        XCTAssertEqual(event?.action, "npx expo run:ios")
        XCTAssertNil(HookEvent(json: [
            "agent": "claude", "session_id": "s", "hook_event_name": "PreToolUse",
            "tool_name": "Bash", "tool_input": ["command": "npm test"],
        ]))
    }

    // MARK: Room in the book

    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let claude = AgentSession(agent: .claude, sessionID: "a", host: nil, project: .init(name: "app", subtitle: ""))
    private let codex = AgentSession(agent: .codex, sessionID: "b", host: nil, project: .init(name: "web", subtitle: ""))

    private func build(_ session: AgentSession, at offset: TimeInterval = 0) -> LeaseBook.Waiter {
        LeaseBook.Waiter(
            id: UUID(), session: session, action: "xcodebuild", devices: [], releases: [],
            since: start + offset, deadline: start + offset + 540, pools: [.build])
    }

    func testBuildWaitsForTheRunningOneAndItsReservation() {
        var book = LeaseBook()
        book.resources = .init(usage: [.build: 0], limits: [.build: 1])
        XCTAssertEqual(book.request(build(claude), now: start), .allow)
        // The first build hasn't shown up as a process yet, but its room is reserved.
        let second = build(codex, at: 5)
        XCTAssertEqual(book.request(second, now: start + 5), .wait)
        // Now it's running.
        book.resources.usage[.build] = 1
        XCTAssertTrue(book.tick(now: start + 70, running: [], userAway: 0, userHoldTimeout: nil).allowed.isEmpty)
        // It finished.
        book.resources.usage[.build] = 0
        XCTAssertEqual(book.tick(now: start + 300, running: [], userAway: 0, userHoldTimeout: nil).allowed, [second.id])
    }

    func testLowMemoryHoldsHeavyWorkButNotDeviceCalls() {
        var book = LeaseBook()
        book.resources = .init(usage: [:], limits: [.build: 5], memoryLow: true)
        XCTAssertEqual(book.request(build(claude), now: start), .wait)
        let tap = LeaseBook.Waiter(
            id: UUID(), session: claude, action: "gesture-tap", devices: ["sim"], releases: [],
            since: start, deadline: start + 540)
        XCTAssertEqual(book.request(tap, now: start), .allow)
    }

    func testRunNowIgnoresTheLimits() {
        var book = LeaseBook()
        book.resources = .init(usage: [.build: 1], limits: [.build: 1])
        let waiting = build(claude)
        XCTAssertEqual(book.request(waiting, now: start), .wait)
        XCTAssertEqual(book.forceAllow(waiting.id, now: start + 1).allowed, [waiting.id])
        XCTAssertTrue(book.waiters.isEmpty)
    }
}
