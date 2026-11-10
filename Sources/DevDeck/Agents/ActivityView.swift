import SwiftUI

/// What DevDeck decided about agents, newest first: calls that waited or were turned away,
/// what you did, and what was cleaned up.
struct ActivityView: View {
    @EnvironmentObject private var activity: ActivityLog
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Everything"
        case agents = "Agents Held Back"
        case user = "Your Actions"
        case metro = "Metro"

        var id: String { rawValue }

        func includes(_ kind: ActivityEntry.Kind) -> Bool {
            switch self {
            case .all: true
            case .agents: [.ranAfterWait, .turnedAway, .redirected, .guarded, .needsUser, .limit].contains(kind)
            case .user: [.user, .letThrough, .claimReleased, .cleanedUp].contains(kind)
            case .metro: kind == .metro
            }
        }
    }

    var body: some View {
        Form {
            PageHeader(page: .activity)
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            if days.isEmpty {
                Section { Text("Nothing yet.").foregroundStyle(.secondary) }
            }
            ForEach(days, id: \.day) { day in
                Section(day.title) {
                    ForEach(day.entries) { ActivityRow(entry: $0) }
                }
            }
            if !activity.entries.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ConfirmButton(title: "Clear Activity") { activity.clear() }
                    }
                } footer: {
                    Text("Kept for a week.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var days: [(day: Date, title: String, entries: [ActivityEntry])] {
        let calendar = Calendar.current
        let shown = activity.entries.reversed().filter { filter.includes($0.kind) }
        var result: [(day: Date, title: String, entries: [ActivityEntry])] = []
        for entry in shown {
            let day = calendar.startOfDay(for: entry.date)
            if result.last?.day == day {
                result[result.count - 1].entries.append(entry)
            } else {
                let title = calendar.isDateInToday(day) ? "Today"
                    : calendar.isDateInYesterday(day) ? "Yesterday" : day.formatted(date: .complete, time: .omitted)
                result.append((day, title, [entry]))
            }
        }
        return result
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.kind.symbol)
                .foregroundStyle(entry.kind.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.subject ?? entry.agent ?? entry.kind.title).lineLimit(1)
                    Spacer()
                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if entry.subject != nil, let agent = entry.agent {
                    Text(agent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(entry.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .help(entry.detail)
            }
        }
        .padding(.vertical, 2)
    }
}

extension ActivityEntry.Kind {
    var title: String {
        switch self {
        case .ranAfterWait: "Ran after waiting"
        case .turnedAway: "Turned away"
        case .redirected: "Sent elsewhere"
        case .letThrough: "Let through"
        case .guarded: "Needs your OK"
        case .needsUser: "Device needs you"
        case .user: "You"
        case .claimReleased: "Claim released"
        case .cleanedUp: "Cleaned up"
        case .metro: "Metro"
        case .limit: "Limit changed"
        }
    }

    var symbol: String {
        switch self {
        case .ranAfterWait: "hourglass.bottomhalf.filled"
        case .turnedAway: "hand.raised.fill"
        case .redirected: "arrow.triangle.branch"
        case .letThrough: "arrow.right.circle.fill"
        case .guarded: "exclamationmark.shield.fill"
        case .needsUser: "iphone.radiowaves.left.and.right"
        case .user: "person.fill"
        case .claimReleased: "lock.open.fill"
        case .cleanedUp: "sparkles"
        case .metro: "server.rack"
        case .limit: "gauge.with.dots.needle.33percent"
        }
    }

    var tint: Color {
        switch self {
        case .ranAfterWait, .redirected: .orange
        case .turnedAway, .guarded: .red
        case .needsUser: .yellow
        case .user, .letThrough: .blue
        case .claimReleased, .cleanedUp: .green
        case .metro: .purple
        case .limit: .orange
        }
    }
}
