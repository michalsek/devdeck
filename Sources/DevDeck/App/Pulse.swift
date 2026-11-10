import Foundation

/// The one timer behind DevDeck's periodic scans. Every store refreshes on the same tick,
/// so DevDeck wakes once per tick rather than once per store (each wake takes the app out
/// of App Nap, which runningboardd has to process).
///
/// The tick follows the agents: a hook call brings it down to `fastest`, and each tick
/// without one doubles it, up to `slowest`. A call waiting for room keeps it at `fastest`.
/// Opening the menu or dashboard refreshes once, at once.
@MainActor
final class Pulse {
    static let fastest: TimeInterval = 5
    static let slowest: TimeInterval = 60

    /// Work that keeps the tick fast besides agent calls (e.g. waiting calls).
    var hasWork: () -> Bool = { false }
    private var handlers: [() -> Void] = []
    private var interval = Pulse.fastest
    private var timer: Timer?

    /// Starts ticking with these handlers, in order.
    func start(_ handlers: [() -> Void]) {
        self.handlers = handlers
        schedule()
    }

    /// The menu or dashboard opened: show fresh data.
    func refreshNow() { tick() }

    /// An agent called: tick within `fastest`, and keep ticking fast while calls come.
    func noteActivity() {
        interval = Self.fastest
        if let fire = timer?.fireDate, fire.timeIntervalSinceNow > Self.fastest {
            schedule()
        }
    }

    private func tick() {
        guard !handlers.isEmpty else { return }
        handlers.forEach { $0() }
        interval = hasWork() ? Self.fastest : min(interval * 2, Self.slowest)
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Lets macOS line the wake-up up with others.
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
