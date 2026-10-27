import SwiftUI

enum Format {
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

/// Status dot used in every list: green running, orange needs a look, grey off.
struct StatusDot: View {
    enum Tone { case running, attention, off }
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
        case .off: .secondary.opacity(0.5)
        }
    }
}

struct Pill: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint == .secondary ? Color.primary : tint)
    }
}

/// A destructive button that asks first: the first click turns it into
/// "Confirm", which acts on a second click within a few seconds. Works inside
/// the menu bar panel, where a modal dialog would close the panel.
struct ConfirmButton: View {
    let title: String
    var busy = false
    let action: () -> Void

    @State private var armed = false

    var body: some View {
        if busy {
            ProgressView().controlSize(.small).frame(minWidth: 44)
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
        .controlSize(.small)
    }
}

/// Empty or not-yet-loaded list state.
struct Placeholder: View {
    let title: String
    let systemImage: String
    var detail: String?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let detail { Text(detail) }
        }
    }
}
