import SwiftUI

/// The agent sessions DevDeck has heard from: what each is doing, the devices it holds or
/// booted, the processes it started, and Clean Up for what a finished one left running.
struct AgentsView: View {
    @EnvironmentObject private var agents: AgentStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            Form {
                PageHeader(page: .agents)
                if agents.records.isEmpty {
                    Section {
                        Text("No agent has used a device, a build or a dev server yet. Agents show up here once their hooks report to DevDeck (General → Agent Activity).")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(ordered(now: context.date)) { record in
                    AgentSection(record: record, now: context.date)
                }
            }
            .formStyle(.grouped)
        }
    }

    /// Working first, then idle, then ended; the most recent first within each.
    private func ordered(now: Date) -> [AgentRecord] {
        func rank(_ record: AgentRecord) -> Int {
            switch record.state(now: now, idleAfter: AgentStore.idleAfter) {
            case .working: 0
            case .idle: 1
            case .ended: 2
            }
        }
        return agents.sorted.sorted { rank($0) < rank($1) }
    }
}

private struct AgentSection: View {
    @EnvironmentObject private var agents: AgentStore
    @EnvironmentObject private var leases: LeaseStore
    @EnvironmentObject private var claims: ClaimStore
    @EnvironmentObject private var devices: DeviceStore
    @EnvironmentObject private var activity: ActivityLog
    let record: AgentRecord
    let now: Date

    var body: some View {
        let state = record.state(now: now, idleAfter: AgentStore.idleAfter)
        let left = agents.leftovers(of: record)
        Section {
            LineRow(symbol: symbol(state), tint: tint(state), title: status(state), detail: detail) {
                if state != .working, !left.isEmpty {
                    ConfirmButton(title: "Clean Up", busy: agents.cleaning.contains(record.id)) { agents.cleanUp(record.id) }
                        .help("Stop \(left.summary)")
                } else if state == .ended {
                    Button("Forget") { agents.forget(record.id) }
                }
            }
            ForEach(held, id: \.device.id) { item in
                LineRow(symbol: "iphone", tint: .purple, title: item.device.name, detail: item.detail) {}
            }
            ForEach(leases.book.waiters.filter { $0.session.id == record.id }) { waiter in
                LineRow(
                    symbol: "hourglass", tint: .orange, title: waiter.action,
                    detail: "waiting \(Format.age(since: waiter.since, now: now))") {
                    Button("Let Through") { leases.runNow(waiter) }
                    Button("Turn Away") { leases.dismiss(waiter) }
                }
            }
            ForEach(booted) { device in
                LineRow(symbol: "power", tint: .secondary, title: device.name, detail: "Booted by this agent") {
                    ConfirmButton(title: device.stopLabel) { devices.stop(device) }
                }
            }
            ForEach(record.processes) { process in
                LineRow(symbol: process.symbol, tint: .green, title: process.label, detail: process.detail(now: now)) {
                    ConfirmButton(title: "Stop") { agents.stop(process, of: record.id) }
                }
            }
            ForEach(recent) { entry in
                LineRow(symbol: entry.kind.symbol, tint: entry.kind.tint, title: entry.subject ?? entry.kind.title,
                          detail: "\(entry.date.formatted(date: .omitted, time: .shortened)) · \(entry.detail)") {}
                    .help(entry.detail)
            }
        } header: {
            Text(record.session.label)
        }
    }

    private var detail: String {
        [record.session.host.map { "in \($0)" }, record.session.project.subtitle.isEmpty ? nil : record.session.project.subtitle,
         record.pid.map { "pid \($0)" }, "first seen \(record.firstSeen.formatted(date: .omitted, time: .shortened))"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func status(_ state: AgentRecord.State) -> String {
        switch state {
        case .working: "Working · \(record.lastAction) \(Format.age(since: record.lastSeen, now: now)) ago"
        case .idle: "Idle · turn ended \(Format.age(since: record.turnEnded, now: now)) ago"
        case .ended: "Session ended \(Format.age(since: record.ended, now: now)) ago"
        }
    }

    private func symbol(_ state: AgentRecord.State) -> String {
        switch state {
        case .working: "cpu"
        case .idle: "moon.zzz.fill"
        case .ended: "checkmark.circle.fill"
        }
    }

    private func tint(_ state: AgentRecord.State) -> Color {
        switch state {
        case .working: .purple
        case .idle: .secondary
        case .ended: .green
        }
    }

    /// Devices it leases or has claimed with agent-device.
    private var held: [(device: DeviceItem, detail: String)] {
        devices.running.compactMap { device in
            if let lease = leases.lease(for: device), lease.holder.session?.id == record.id {
                return (device, lease.turnEnded ? "Leased · turn ended" : "Leased · \(lease.lastActionName) \(Format.age(since: lease.lastAction, now: now)) ago")
            }
            if let status = claims.claims(for: device).first(where: { claims.owner(of: $0)?.session.id == record.id }) {
                return (device, ClaimText.summary(status, state: claims.state(of: status, now: now), now: now))
            }
            return nil
        }
    }

    /// Devices it booted that are still running and that it doesn't hold any more.
    private var booted: [DeviceItem] {
        let holding = Set(held.map(\.device.id))
        return devices.running.filter { record.booted.contains($0.id) && !holding.contains($0.id) }
    }

    private var recent: [ActivityEntry] {
        Array(activity.entries.reversed().filter { $0.session == record.id }.prefix(3))
    }
}

extension OwnedProcess {
    var symbol: String {
        switch kind {
        case .devServer: "server.rack"
        case .build: "hammer.fill"
        }
    }

    /// "up 2 h · 1.4 GB · pid 4122"
    func detail(now: Date) -> String {
        [started.map { "up \(Format.age(since: $0, now: now))" },
         footprint > 0 ? String(format: "%.1f GB", Double(footprint) / 1_073_741_824) : nil, "pid \(pid)"]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
