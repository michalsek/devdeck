import Foundation

/// The one timer behind DevDeck's periodic scans. Every store refreshes on the same tick,
/// so DevDeck wakes once per tick rather than once per store (each wake takes the app out
/// of App Nap, which runningboardd has to process). It ticks every `busyInterval` while
/// the user is looking or an agent is active, and every `quietInterval` otherwise.
@MainActor
final class Pulse {
    static let busyInterval: TimeInterval = 5
    static let quietInterval: TimeInterval = 30
    /// An agent counts as active this long after its last hook call.
    static let activeWindow: TimeInterval = 120

    /// Work that keeps the pulse busy besides viewers and agent calls (e.g. waiting calls).
    var hasWork: () -> Bool = { false }
    private var handlers: [() -> Void] = []
    private var viewers: Set<String> = []
    private var lastActivity = Date.distantPast
    private var timer: Timer?

    var isBusy: Bool {
        !viewers.isEmpty || Date.now.timeIntervalSince(lastActivity) < Self.activeWindow || hasWork()
    }

    /// Starts ticking with these handlers, in order.
    func start(_ handlers: [() -> Void]) {
        self.handlers = handlers
        schedule()
    }

    /// The menu or dashboard opened (fresh data now) or closed.
    func setViewing(_ viewer: String, _ viewing: Bool) {
        if viewing {
            viewers.insert(viewer)
            tick()
        } else {
            viewers.remove(viewer)
        }
    }

    /// An agent called: tick within `busyInterval` if the next tick is further off.
    func noteActivity() {
        lastActivity = .now
        if let fire = timer?.fireDate, fire.timeIntervalSinceNow > Self.busyInterval {
            schedule()
        }
    }

    private func tick() {
        guard !handlers.isEmpty else { return }
        handlers.forEach { $0() }
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        let interval = isBusy ? Self.busyInterval : Self.quietInterval
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Lets macOS line the wake-up up with others.
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
