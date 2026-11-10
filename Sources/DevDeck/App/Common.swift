import CoreGraphics
import SwiftUI

enum UserActivity {
    /// Time since the last keyboard, mouse or trackpad input anywhere on the Mac.
    /// Needs no permission.
    static func secondsSinceInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}

enum Format {
    /// "30 seconds", "1 minute", "9 minutes", "2 hours", for a stretch of time in a sentence.
    static func duration(_ seconds: TimeInterval) -> String {
        let value = Int(seconds.rounded())
        func unit(_ n: Int, _ name: String) -> String { "\(n) \(name)\(n == 1 ? "" : "s")" }
        if value < 60 || value % 60 != 0 { return unit(value, "second") }
        if value < 3600 || value % 3600 != 0 { return unit(value / 60, "minute") }
        return unit(value / 3600, "hour")
    }

    /// "45 s", "12 min", "5 h", "3 d"
    static func age(since date: Date?, now: Date = .now) -> String {
        guard let date else { return "—" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "\(seconds) s"
        case ..<3600: return "\(seconds / 60) min"
        case ..<86400: return "\(seconds / 3600) h"
        default: return "\(seconds / 86400) d"
        }
    }
}

/// Status dot used in every list: green running, orange needs a look, purple driven by
/// an agent, blue held by you, grey off.
struct StatusDot: View {
    enum Tone { case running, attention, agent, user, off }
    let tone: Tone

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch tone {
        case .running: .green
        case .attention: .orange
        case .agent: .purple
        case .user: .blue
        case .off: .secondary.opacity(0.5)
        }
    }
}

/// A destructive button that asks first: the first click turns it into
/// "Confirm", which acts on a second click within a few seconds.
struct ConfirmButton: View {
    let title: String
    var busy = false
    let action: () -> Void

    @State private var armed = false

    var body: some View {
        if busy {
            ProgressView().controlSize(.small).frame(minWidth: 52)
        } else if armed {
            button.buttonStyle(.borderedProminent).tint(.red).help("Click again to confirm")
        } else {
            button.buttonStyle(.bordered).foregroundStyle(.red)
        }
    }

    private var button: some View {
        Button(armed ? "Confirm" : title) {
            if armed {
                armed = false
                action()
            } else {
                armed = true
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    armed = false
                }
            }
        }
    }
}

/// Icon, title and detail on the left, actions on the right.
struct LineRow<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { actions() }
        }
        .padding(.vertical, 2)
    }
}
