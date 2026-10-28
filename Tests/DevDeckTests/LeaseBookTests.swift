import XCTest
@testable import DevDeck

final class LeaseBookTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let claude = AgentSession(agent: .claude, sessionID: "a", host: nil, project: .init(name: "app", subtitle: ""))
    private let codex = AgentSession(agent: .codex, sessionID: "b", host: nil, project: .init(name: "web", subtitle: ""))

    private func call(_ session: AgentSession, _ device: String, at offset: TimeInterval = 0,
                      wait: TimeInterval = 540) -> LeaseBook.Waiter {
        LeaseBook.Waiter(
            id: UUID(), session: session, action: "gesture-tap", devices: [device], releases: [],
            since: start + offset, deadline: start + offset + wait)
    }

    private func tick(_ book: inout LeaseBook, at offset: TimeInterval, running: Set<String> = ["sim"],
                      userAway: TimeInterval = 0, holdTimeout: TimeInterval? = 600) -> LeaseBook.Effects {
        book.tick(now: start + offset, running: running, agentIdle: 600, userAway: userAway, userHoldTimeout: holdTimeout)
    }

    func testAgentsRunFreelyAndTheLatestHoldsTheDevice() {
        var book = LeaseBook()
        XCTAssertEqual(book.request(call(claude, "sim"), now: start).0, .allow)
        XCTAssertEqual(book.leases["sim"]?.holder, .agent(claude))
        // No agent-vs-agent waiting yet: the other agent takes over.
        XCTAssertEqual(book.request(call(codex, "sim", at: 5), now: start + 5).0, .allow)
        XCTAssertEqual(book.leases["sim"]?.holder, .agent(codex))
    }

    func testAgentWaitsWhileTheUserHoldsAndRunsOnRelease() {
        var book = LeaseBook()
        _ = book.request(call(claude, "sim"), now: start)
        book.hold("sim", now: start + 1)
        let waiting = call(claude, "sim", at: 2)
        XCTAssertEqual(book.request(waiting, now: start + 2).0, .wait)
        XCTAssertEqual(book.waiters(for: "sim").map(\.id), [waiting.id])

        let effects = book.release("sim", now: start + 30)
        XCTAssertEqual(effects.allowed, [waiting.id])
        XCTAssertTrue(book.waiters.isEmpty)
        XCTAssertEqual(book.leases["sim"]?.holder, .agent(claude))
    }

    func testWaitingCallGivesUpAtItsDeadline() {
        var book = LeaseBook()
        book.hold("sim", now: start)
        let waiting = call(claude, "sim", wait: 60)
        _ = book.request(waiting, now: start)
        XCTAssertTrue(tick(&book, at: 59).isEmpty)
        XCTAssertEqual(tick(&book, at: 60).denied, [waiting.id])
        XCTAssertTrue(book.isHeldByUser("sim"))
    }

    func testHoldEndsWhenTheUserIsAwayAndLetsAgentsThrough() {
        var book = LeaseBook()
        book.hold("sim", now: start)
        let waiting = call(codex, "sim")
        _ = book.request(waiting, now: start)
        XCTAssertTrue(tick(&book, at: 300, userAway: 599).isEmpty)
        XCTAssertEqual(tick(&book, at: 310, userAway: 600).allowed, [waiting.id])
        // "Never" keeps the hold however long the user is away.
        book.hold("sim", now: start + 400)
        _ = tick(&book, at: 5000, userAway: 5000, holdTimeout: nil)
        XCTAssertTrue(book.isHeldByUser("sim"))
    }

    func testQueuedUserGetsTheDeviceWhenTheAgentIsDone() {
        var book = LeaseBook()
        _ = book.request(call(claude, "sim"), now: start)
        book.joinQueue("sim", now: start + 1)
        XCTAssertTrue(book.queue.contains("sim"))
        XCTAssertEqual(book.leases["sim"]?.holder, .agent(claude))

        // The agent's turn ending hands it over straight away.
        XCTAssertEqual(book.agentStopped(claude.id, now: start + 20).handedToUser, ["sim"])
        XCTAssertTrue(book.isHeldByUser("sim"))
        XCTAssertFalse(book.queue.contains("sim"))
        // And from then on the agent waits.
        XCTAssertEqual(book.request(call(claude, "sim", at: 21), now: start + 21).0, .wait)
    }

    func testQueuedUserGetsTheDeviceAfterAgentIdleOrSessionEnd() {
        var book = LeaseBook()
        _ = book.request(call(claude, "sim"), now: start)
        book.joinQueue("sim", now: start)
        XCTAssertEqual(tick(&book, at: 600).handedToUser, ["sim"])

        var other = LeaseBook()
        _ = other.request(call(codex, "sim"), now: start)
        other.joinQueue("sim", now: start)
        XCTAssertEqual(other.endSession(codex.id, now: start + 5).handedToUser, ["sim"])
    }

    func testJoiningTheQueueOfAFreeDeviceHoldsIt() {
        var book = LeaseBook()
        book.joinQueue("sim", now: start)
        XCTAssertTrue(book.isHeldByUser("sim"))
    }

    func testStoppedDevicesDropTheirHoldsAndQueue() {
        var book = LeaseBook()
        book.hold("sim", now: start)
        _ = book.request(call(claude, "emu"), now: start)
        book.joinQueue("emu", now: start)
        _ = tick(&book, at: 5, running: [])
        XCTAssertTrue(book.leases.isEmpty)
        XCTAssertTrue(book.queue.isEmpty)
    }

    func testCancelledWaiterIsForgotten() {
        var book = LeaseBook()
        book.hold("sim", now: start)
        let waiting = call(claude, "sim")
        _ = book.request(waiting, now: start)
        book.cancel(waiting.id)
        XCTAssertTrue(book.release("sim", now: start + 1).allowed.isEmpty)
    }
}
