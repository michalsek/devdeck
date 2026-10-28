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
        book.tick(now: start + offset, running: running, userAway: userAway, userHoldTimeout: holdTimeout)
    }

    func testAgentWaitsForAnotherAgentUntilItsTurnEnds() {
        var book = LeaseBook()
        XCTAssertEqual(book.request(call(claude, "sim"), now: start), .allow)
        XCTAssertEqual(book.leases["sim"]?.holder, .agent(claude))
        // The same session (or its subagents) carries on freely.
        XCTAssertEqual(book.request(call(claude, "sim", at: 1), now: start + 1), .allow)

        let waiting = call(codex, "sim", at: 5)
        XCTAssertEqual(book.request(waiting, now: start + 5), .wait)
        XCTAssertEqual(book.agentStopped(claude.id, now: start + 30).allowed, [waiting.id])
        XCTAssertEqual(book.leases["sim"]?.holder, .agent(codex))
        // Now Claude waits for Codex.
        XCTAssertEqual(book.request(call(claude, "sim", at: 31), now: start + 31), .wait)
    }

    func testAgentTakesOverAfterTheHolderIsQuietForTwoMinutes() {
        var book = LeaseBook()
        _ = book.request(call(claude, "sim"), now: start)
        let waiting = call(codex, "sim", at: 10)
        XCTAssertEqual(book.request(waiting, now: start + 10), .wait)
        XCTAssertTrue(tick(&book, at: 119).isEmpty)
        XCTAssertEqual(tick(&book, at: 120).allowed, [waiting.id])
        // A fresh call after a quiet spell simply takes it.
        _ = book.request(call(claude, "sim", at: 400), now: start + 400)
        XCTAssertEqual(book.leases["sim"]?.holder, .agent(claude))
    }

    func testBusyAgentIsSentToAFreeDeviceOfTheSameKind() {
        var book = LeaseBook()
        _ = book.request(call(claude, "sim"), now: start)
        _ = book.request(call(claude, "sim2"), now: start)
        let alternatives = ["sim": ["sim2", "sim3"]]
        // sim2 is Claude's too, so only sim3 is offered.
        XCTAssertEqual(book.request(call(codex, "sim", at: 5), alternatives: alternatives, now: start + 5), .redirect(["sim3"]))
        XCTAssertTrue(book.waiters.isEmpty)
        // Nowhere else to go: wait.
        XCTAssertEqual(book.request(call(codex, "sim", at: 6), alternatives: ["sim": ["sim2"]], now: start + 6), .wait)
    }

    func testUserHoldWaitsEvenWithAFreeDevice() {
        var book = LeaseBook()
        book.hold("sim", now: start)
        XCTAssertEqual(book.request(call(codex, "sim"), alternatives: ["sim": ["sim2"]], now: start), .wait)
    }

    func testQueuedUserComesBeforeWaitingAgents() {
        var book = LeaseBook()
        _ = book.request(call(claude, "sim"), now: start)
        book.joinQueue("sim", now: start + 1)
        let waiting = call(codex, "sim", at: 2)
        XCTAssertEqual(book.request(waiting, now: start + 2), .wait)
        let effects = book.agentStopped(claude.id, now: start + 10)
        XCTAssertEqual(effects.handedToUser, ["sim"])
        XCTAssertTrue(effects.allowed.isEmpty)
        XCTAssertEqual(book.release("sim", now: start + 20).allowed, [waiting.id])
    }

    func testWaitersCanBeReorderedOrTurnedAway() {
        var book = LeaseBook()
        book.hold("sim", now: start)
        let first = call(claude, "sim")
        let second = call(codex, "sim", at: 1)
        _ = book.request(first, now: start)
        _ = book.request(second, now: start + 1)
        book.moveToFront(second.id)
        // Second goes first and takes the lease; first keeps waiting for it.
        XCTAssertEqual(book.release("sim", now: start + 5).allowed, [second.id])
        XCTAssertEqual(book.waiters.map(\.id), [first.id])
        XCTAssertEqual(book.dismiss(first.id).denied, [LeaseBook.Denial(waiter: first.id, reason: .dismissed)])
        XCTAssertTrue(book.waiters.isEmpty)
    }

    func testAgentWaitsWhileTheUserHoldsAndRunsOnRelease() {
        var book = LeaseBook()
        _ = book.request(call(claude, "sim"), now: start)
        book.hold("sim", now: start + 1)
        let waiting = call(claude, "sim", at: 2)
        XCTAssertEqual(book.request(waiting, now: start + 2), .wait)
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
        XCTAssertEqual(tick(&book, at: 60).denied, [LeaseBook.Denial(waiter: waiting.id, reason: .timedOut)])
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
        XCTAssertEqual(book.request(call(claude, "sim", at: 21), now: start + 21), .wait)
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
