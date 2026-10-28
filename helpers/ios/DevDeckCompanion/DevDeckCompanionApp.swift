import SwiftUI

@main
struct DevDeckCompanionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HomeView(store: .shared)
        }
        .onChange(of: scenePhase) { _, phase in
            // Live Activities can only be started from the foreground, so retry whenever we get there.
            if phase == .active {
                Task { await AppDelegate.becameActive() }
            }
        }
    }
}
