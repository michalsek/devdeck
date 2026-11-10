import DevDeckProtocol
import SwiftUI

/// Every device someone holds or waits for: the holder and any agent-device claim, then the
/// line (you first, then waiting agent calls in the order they'll get through), with
/// actions for each.
struct LeasesView: View {
    @EnvironmentObject private var devices: DeviceStore
    @EnvironmentObject private var leases: LeaseStore
    @EnvironmentObject private var claims: ClaimStore

    var body: some View {
        Form {
            PageHeader(page: .leases)
            if claims.lastError != nil {
                Section { ErrorRow(errors: [claims.lastError]) }
            }
            let asking = leases.book.waiters.filter { $0.approval != nil }
            if !asking.isEmpty {
                Section {
                    ForEach(asking) { waiter in
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            LineRow(
                                symbol: "exclamationmark.shield.fill", tint: .red, title: "\(waiter.session.label): \(waiter.action)",
                                detail: "It \(waiter.approval ?? "") · waiting \(Format.age(since: waiter.since, now: context.date))"
                            ) {
                                Button("Let Through") { leases.runNow(waiter) }
                                Button("Turn Away") { leases.dismiss(waiter) }
                            }
                            .help("It \(waiter.approval ?? "").")
                        }
                    }
                } header: {
                    Text("Needs Your OK")
                } footer: {
                    Text("Commands that affect every agent's devices or servers, or stop something another agent or you started, wait until you let them through.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if busy.isEmpty {
                Section {
                    Text(devices.loaded ? "No agent is using a device, and you hold none." : "Loading…")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(busy) { device in
                Section {
                    let claimed = claims.claims(for: device)
                    // A claim with no DevDeck lease isn't "free": the claim row says who has it.
                    if leases.lease(for: device) != nil || claimed.isEmpty {
                        HolderRow(device: device)
                    }
                    ForEach(Array(claimed.enumerated()), id: \.element.id) { index, status in
                        ClaimRow(status: status, device: device, leaseActions: index == 0 && leases.lease(for: device) == nil)
                    }
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
                    Text(Self.rules)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private static var rules: String {
        let lease = LeaseBook.Timing()
        let claim = ClaimState.Timing()
        return "Agents keep a device while they work. Another agent's calls wait until the first agent's turn ends or it's been quiet for \(Format.duration(lease.handoff)); if a free device of the same kind is running, the agent is sent there instead. Your holds and your place in line come first. A call waits up to \(Format.duration(HookProtocol.maxWait)) before it's turned away. Devices claimed by agent-device (T3 Code's device tools) are listed too: a claim nobody has used for \(Format.duration(claim.afterTurn)) after its agent's turn ended, or for \(Format.duration(claim.idle)), is marked stale, and Release Claim closes its session."
    }

    /// Running devices someone holds, queues for, waits for or has claimed with agent-device.
    private var busy: [DeviceItem] {
        devices.running.filter {
            leases.lease(for: $0) != nil || leases.isQueued(for: $0)
                || leases.waiters(for: $0).contains { $0.approval == nil }
                || !claims.claims(for: $0).isEmpty
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

/// An agent-device session's claim on the device, with Release Claim.
private struct ClaimRow: View {
    @EnvironmentObject private var leases: LeaseStore
    @EnvironmentObject private var claims: ClaimStore
    let status: ClaimStatus
    let device: DeviceItem
    /// Hold / take over, when there's no DevDeck lease row to carry them.
    let leaseActions: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = claims.state(of: status, now: context.date)
            LineRow(
                symbol: "lock.fill", tint: state.isStale ? .orange : .purple,
                title: "agent-device session \(AgentDevice.shortName(status.claim.session))",
                detail: ClaimText.detail(status, owner: claims.owner(of: status), state: state, now: context.date)
            ) {
                if leaseActions { LeaseButton(device: device) }
                ConfirmButton(title: "Release Claim", busy: claims.isReleasing(status)) { leases.releaseClaim(status) }
                    .help("Close agent-device session \(status.claim.session) so the device is free")
            }
            .help(ClaimHelp.text(status, owner: claims.owner(of: status)))
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
