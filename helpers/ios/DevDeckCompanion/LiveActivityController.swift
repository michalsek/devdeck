import ActivityKit
import OSLog
import UIKit

/// Keeps exactly one DevDeck Live Activity alive while the marker is on. `free` does not end it
/// (it renders as an idle island), because a new one can only be started from the foreground.
@MainActor
final class LiveActivityController {
    private let log = Logger(subsystem: "dev.devdeck.companion", category: "activity")

    var isActive: Bool { !running.isEmpty }

    private var running: [Activity<DevDeckActivityAttributes>] {
        Activity<DevDeckActivityAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }
    }

    /// `nil` (marker turned off) ends the activity; any state starts or updates it.
    func show(_ state: MarkerState?) async {
        let running = self.running

        guard let state else {
            for activity in running {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            if !running.isEmpty { log.notice("ended activity") }
            return
        }

        let content = ActivityContent(state: state, staleDate: nil)
        if let current = running.first {
            for extra in running.dropFirst() {
                await extra.end(nil, dismissalPolicy: .immediate)
            }
            if current.content.state != state {
                await current.update(content)
                log.notice("updated activity: \(state.state.rawValue, privacy: .public)")
            }
            return
        }

        let appState = UIApplication.shared.applicationState
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.notice("Live Activities are disabled for this app")
            return
        }
        do {
            _ = try Activity.request(attributes: DevDeckActivityAttributes(), content: content, pushType: nil)
            log.notice("started activity (app state \(appState.rawValue, privacy: .public))")
        } catch {
            // Expected while in the background; the scene-active hook retries in the foreground.
            log.notice("could not start activity (app state \(appState.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)")
        }
    }
}
