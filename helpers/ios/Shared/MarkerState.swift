import ActivityKit
import Foundation
import SwiftUI

/// The device's marker state exactly as DevDeck sends it (see helpers/README.md).
struct MarkerState: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case agent, user, free
    }

    var state: Kind
    var holder: String?
    var host: String?
    var project: String?
    var action: String?
    /// Unix seconds when the current hold started.
    var since: Double?
}

extension MarkerState {
    /// Nobody holds the simulator. The activity stays alive but renders as an idle island.
    static let free = MarkerState(state: .free)

    var isFree: Bool { state == .free }

    /// Decodes the JSON text passed via `--devdeck-state` or a push.
    init?(json: String) {
        guard let state = try? JSONDecoder().decode(MarkerState.self, from: Data(json.utf8)) else { return nil }
        self = state
    }

    /// Decodes the `devdeck` key of a push payload: a JSON object, or JSON text.
    init?(pushValue: Any?) {
        if let text = pushValue as? String {
            self.init(json: text)
        } else if let object = pushValue, JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let state = try? JSONDecoder().decode(MarkerState.self, from: data) {
            self = state
        } else {
            return nil
        }
    }

    var symbol: String { state == .agent ? "cpu" : "person.fill" }

    /// Purple for agent-driven (as on the Mac), DevDeck green when you hold it.
    var tint: Color { state == .agent ? .purple : Color("UserGreen") }

    var displayHolder: String {
        if let holder, !holder.isEmpty { return holder }
        return state == .agent ? "An agent" : "You"
    }

    /// One word for the compact Dynamic Island: "Claude Code" -> "Claude".
    var shortHolder: String {
        String(displayHolder.split(separator: " ").first ?? "").prefix(10).description
    }

    var sinceDate: Date? { since.map { Date(timeIntervalSince1970: $0) } }

    /// "project · action", skipping whatever is missing.
    var detail: String? {
        let parts = [project, action].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The Live Activity shown while someone holds the simulator. Everything lives in the
/// content state, so one activity is updated in place as the holder or action changes.
struct DevDeckActivityAttributes: ActivityAttributes {
    typealias ContentState = MarkerState
}
