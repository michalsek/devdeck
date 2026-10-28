import OSLog
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    private let log = Logger(subsystem: "dev.devdeck.companion", category: "app")

    /// `--devdeck-start`: DevDeck launched us right after boot only to start the Live Activity
    /// (which needs the foreground); go back to the home screen as soon as that's done.
    @MainActor private static var pendingStartLaunch = ProcessInfo.processInfo.arguments.contains("--devdeck-start")

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if let state = Self.launchState() {
            log.notice("launch state: \(state.state.rawValue, privacy: .public)")
            Task { await MarkerStore.shared.receive(state) }
        } else {
            Task { await MarkerStore.shared.receiveFromStateFile() }
        }
        // For real APNs pushes carrying a "devdeck" key. On the simulator `simctl push` wakes the
        // app through a background fetch instead (see performFetch below).
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard let state = MarkerState(pushValue: userInfo["devdeck"]) else {
            log.error("push without a valid devdeck state")
            completionHandler(.noData)
            return
        }
        log.notice("push state: \(state.state.rawValue, privacy: .public) (app state \(application.applicationState.rawValue, privacy: .public))")
        Task {
            await MarkerStore.shared.receive(state)
            completionHandler(.newData)
        }
    }

    func application(_ application: UIApplication,
                     performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // On the simulator `simctl push` never calls didReceiveRemoteNotification; it wakes the
        // app with a background fetch instead (the payload only becomes a user notification).
        // So DevDeck writes the state file first and uses the push purely as a wake-up.
        log.notice("background fetch wake (app state \(application.applicationState.rawValue, privacy: .public))")
        Task {
            let changed = await MarkerStore.shared.receiveFromStateFile()
            completionHandler(changed ? .newData : .noData)
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        log.notice("registered for remote notifications")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        log.notice("remote notification registration failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Called whenever the scene becomes active: start or refresh the activity, and for a
    /// `--devdeck-start` launch send the app straight back to the background.
    @MainActor static func becameActive() async {
        await MarkerStore.shared.receiveFromStateFile()
        guard pendingStartLaunch else { return }
        pendingStartLaunch = false
        Logger(subsystem: "dev.devdeck.companion", category: "app").notice("--devdeck-start: suspending")
        // Private but long-standing: what the home gesture does. Fine for a simulator-only helper.
        UIApplication.shared.perform(NSSelectorFromString("suspend"))
    }

    /// `--devdeck-state '<json>'` from the launch arguments.
    private static func launchState() -> MarkerState? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--devdeck-state"), index + 1 < args.count else { return nil }
        return MarkerState(json: args[index + 1])
    }
}
