import SwiftUI

/// Every device someone holds or waits for: the holder, then the line (you first, then
/// waiting agent calls in the order they'll get through), with actions for each.
struct LeasesView: View {
    @EnvironmentObject private var devices: DeviceStore
    @EnvironmentObject private var leases: LeaseStore

    var body: some View {
        Form {
            PageHeader(page: .leases)
            if busy.isEmpty {
                Section {
                    Text(devices.loaded ? "No agent is using a device, and you hold none." : "Loading…")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(busy) { device in
                Section {
                    HolderRow(device: device)
                    if leases.isQueued(for: device) {
                        LineRow(symbol: "person.fill", tint: .blue, title: "You", detail: "Next in line") {
                            Button("Leave Queue") { leases.leaveQueue(device) }
                        }
                    }
                    let waiting = leases.waiters(for: device)
                    ForEach(Array(waiting.enumerated()), id: \.element.id) { index, waiter in
                        WaiterRow(waiter: waiter, first: index == 0)
                    }
                } header: {
                    Text(device.name)
                }
            }
            if !free.isEmpty {
                Section {
                    ForEach(free) { device in
                        HStack {
                            StatusDot(tone: .running)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text(device.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            LeaseButton(device: device)
                        }
                    }
                } header: {
                    Text("Nobody Is Using")
                } footer: {
                    Text("Agents keep a device while they work. Another agent's calls wait until the first agent's turn ends or it's been quiet for 2 minutes; if a free device of the same kind is running, the agent is sent there instead. Your holds and your place in line come first. A call waits up to 9 minutes before it's turned away.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Running devices someone holds, queues for or waits for.
    private var busy: [DeviceItem] {
        devices.running.filter {
            leases.lease(for: $0) != nil || leases.isQueued(for: $0) || !leases.waiters(for: $0).isEmpty
        }
    }

    private var free: [DeviceItem] {
        devices.running.filter { device in !busy.contains { $0.id == device.id } }
    }
}

/// The current holder of a device, with take over / release.
private struct HolderRow: View {
    @EnvironmentObject private var leases: LeaseStore
    let device: DeviceItem

    var body: some View {
        if let lease = leases.lease(for: device) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                switch lease.holder {
                case .agent(let session):
                    LineRow(
                        symbol: "cpu", tint: .purple, title: session.label,
                        detail: [
                            lease.turnEnded ? "turn ended" : "\(lease.lastActionName) \(Format.age(since: lease.lastAction, now: context.date)) ago",
                            "has it for \(Format.age(since: lease.since, now: context.date))",
                            session.host.map { "in \($0)" },
                        ].compactMap { $0 }.joined(separator: " · ")
                    ) {
                        LeaseButton(device: device)
                    }
                case .user:
                    LineRow(
                        symbol: "person.fill", tint: .blue, title: "You",
                        detail: "Holding it for \(Format.age(since: lease.since, now: context.date))"
                    ) {
                        LeaseButton(device: device)
                    }
                }
            }
        } else {
            LineRow(symbol: "circle.dashed", tint: .secondary, title: "Nobody", detail: "Free") {
                LeaseButton(device: device)
            }
        }
    }
}

/// An agent call waiting for the device.
private struct WaiterRow: View {
    @EnvironmentObject private var leases: LeaseStore
    let waiter: LeaseBook.Waiter
    let first: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            LineRow(
                symbol: "hourglass", tint: .orange, title: waiter.session.label,
                detail: "\(waiter.action) · waiting \(Format.age(since: waiter.since, now: context.date))"
            ) {
                if !first {
                    Button("Move to Front") { leases.moveToFront(waiter) }
                        .help("Let this call through next")
                }
                Button("Turn Away") { leases.dismiss(waiter) }
                    .help("Stop it waiting; the agent is told the device is in use")
            }
        }
    }
}

/// Icon, title and detail on the left, actions on the right.
private struct LineRow<Actions: View>: View {
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
