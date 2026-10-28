import Foundation
import Observation

/// The last state DevDeck sent and the user's marker toggle, persisted in UserDefaults.
@MainActor @Observable
final class MarkerStore {
    static let shared = MarkerStore()

    private(set) var state: MarkerState?
    private(set) var markerEnabled: Bool

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let liveActivity = LiveActivityController()

    private init() {
        markerEnabled = defaults.object(forKey: Keys.markerEnabled) as? Bool ?? true
        state = defaults.data(forKey: Keys.state).flatMap { try? JSONDecoder().decode(MarkerState.self, from: $0) }
    }

    /// Records a state from DevDeck and updates the marker. While the marker is off the
    /// state is still recorded (so the home screen stays accurate) but never shown.
    func receive(_ newState: MarkerState) async {
        state = newState
        let data = try? JSONEncoder().encode(newState)
        defaults.set(data, forKey: Keys.state)
        // Keep the file in step so an older file never overrides a launch-argument or push state.
        if let data, (try? Data(contentsOf: Self.stateFileURL)) != data {
            try? FileManager.default.createDirectory(at: Self.stateFileURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: Self.stateFileURL, options: .atomic)
        }
        await sync()
    }

    /// Reads `Library/DevDeck/state.json` in the app's data container, which DevDeck writes
    /// before waking the app. Returns whether it carried a new state.
    @discardableResult
    func receiveFromStateFile() async -> Bool {
        guard let data = try? Data(contentsOf: Self.stateFileURL),
              let fileState = try? JSONDecoder().decode(MarkerState.self, from: data),
              fileState != state
        else {
            await sync()
            return false
        }
        await receive(fileState)
        return true
    }

    static var stateFileURL: URL {
        URL.libraryDirectory.appending(path: "DevDeck/state.json")
    }

    /// Written after every sync so DevDeck can tell whether the activity still exists (iOS ends
    /// Live Activities after about 8 hours) and restart it with `--devdeck-start`.
    static var statusFileURL: URL {
        URL.libraryDirectory.appending(path: "DevDeck/status.json")
    }

    func setMarkerEnabled(_ enabled: Bool) async {
        markerEnabled = enabled
        defaults.set(enabled, forKey: Keys.markerEnabled)
        await sync()
    }

    /// Makes the Live Activity match the current state and toggle, then reports it in status.json.
    func sync() async {
        await liveActivity.show(markerEnabled ? (state ?? .free) : nil)
        writeStatus()
    }

    private func writeStatus() {
        let status: [String: Any] = [
            "activity": liveActivity.isActive ? "active" : "none",
            "marker": markerEnabled,
            "updated": Int(Date().timeIntervalSince1970),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: Self.statusFileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.statusFileURL, options: .atomic)
    }

    private enum Keys {
        static let state = "lastState"
        static let markerEnabled = "markerEnabled"
    }
}
