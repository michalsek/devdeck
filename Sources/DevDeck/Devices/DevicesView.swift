import AppKit
import SwiftUI

struct DevicesView: View {
    @EnvironmentObject private var store: DeviceStore
    @State private var showStoppedSimulators = false

    var body: some View {
        Form {
            PageHeader(page: .devices)
            section("iOS Simulators", kind: .simulator, emptyText: "No simulators booted")
            section("Android Emulators", kind: .emulator, emptyText: "No Android emulators")
            section("Physical Devices", kind: .physical, emptyText: "No paired devices")
            if store.lastError != nil {
                Section { ErrorRow(errors: [store.lastError]) }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func section(_ title: String, kind: DeviceItem.Kind, emptyText: String) -> some View {
        let all = store.devices(kind)
        // Shut-down simulators can number in the dozens, so they fold away.
        let visible = kind == .simulator ? all.filter(\.isRunning) : all
        let folded = kind == .simulator ? all.filter { !$0.isRunning } : []
        Section {
            if visible.isEmpty {
                Text(store.loaded ? emptyText : "Loading…").foregroundStyle(.secondary)
            }
            ForEach(visible) { DeviceRow(device: $0) }
            if !folded.isEmpty {
                DisclosureGroup("Shut down (\(folded.count))", isExpanded: $showStoppedSimulators) {
                    ForEach(folded) { DeviceRow(device: $0) }
                }
            }
            if kind == .simulator {
                HStack {
                    Spacer()
                    Button("Open Simulator") { store.showSimulatorApp() }
                }
            }
        } header: {
            Text(title)
        } footer: {
            if kind == .physical {
                Text("iPhones and iPads paired with this Mac, and Android devices connected over adb.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct DeviceRow: View {
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var leases: LeaseStore
    let device: DeviceItem

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(tone: lease.map { $0.isUser ? .user : .agent } ?? (device.isRunning ? .running : .off))
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let lease {
                    LeaseLine(lease: lease, waiting: leases.waiters(for: device), queued: leases.isQueued(for: device))
                }
            }
            Spacer(minLength: 8)
            if device.isRunning { LeaseButton(device: device) }
            Text(device.stateLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // Fixed width keeps the state text aligned for rows without an action.
            Color.clear.frame(width: 84, height: 1).overlay(alignment: .trailing) { actions }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy ID") { Pasteboard.copy(device.serial ?? device.id) }
            if lease?.isUser == false { Button("Forget This Agent") { leases.forget(device) } }
        }
    }

    private var lease: LeaseStore.Lease? { leases.lease(for: device) }

    private var subtitle: String {
        var parts = [device.detail]
        if device.kind != .emulator { parts.append(device.shortID) }
        if device.kind == .physical, !device.isRunning, let seen = device.lastSeen {
            parts.append("last seen " + seen.formatted(.relative(presentation: .named)))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var actions: some View {
        let busy = store.busy.contains(device.id)
        if device.canStop {
            ConfirmButton(title: device.stopLabel, busy: busy) { store.stop(device) }
        } else if device.canStart {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button(device.startLabel) { store.start(device) }
            }
        }
    }
}

/// Hold a free device, take over (or queue for) one an agent drives, or release yours.
struct LeaseButton: View {
    @EnvironmentObject private var leases: LeaseStore
    let device: DeviceItem

    var body: some View {
        switch leases.lease(for: device)?.holder {
        case .agent:
            let queued = leases.isQueued(for: device)
            Menu("Take Over") {
                Button("Take Over Now") { leases.hold(device) }
                if queued {
                    Button("Leave Queue") { leases.leaveQueue(device) }
                } else {
                    Button("Join Queue") { leases.joinQueue(device) }
                }
                Divider()
                Button("Forget This Agent") { leases.forget(device) }
            } primaryAction: {
                leases.hold(device)
            }
            .fixedSize()
            .help("Take it now and make agents wait, or join the queue to get it when the agent is done")
        case .user:
            Button("Release") { leases.release(device) }
                .help("Let waiting agents use it again")
        case nil:
            Button("Hold") { leases.hold(device) }
                .help("Keep agents off this device until you release it")
        }
    }
}

/// Under a device someone holds: "Claude Code · gesture-tap 12 s ago · my-app", or
/// "Held by you · 2 agent calls waiting".
private struct LeaseLine: View {
    let lease: LeaseStore.Lease
    let waiting: [LeaseBook.Waiter]
    let queued: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 4) {
                switch lease.holder {
                case .agent(let session):
                    Image(systemName: "cpu")
                    Text("\(session.agent.title) · \(lease.turnEnded ? "turn ended" : "\(lease.lastActionName) \(Format.age(since: lease.lastAction, now: context.date)) ago") · \(session.project.name)"
                        + (queued ? " · you're next" : "")
                        + (waiting.isEmpty ? "" : " · \(waiting.count) waiting"))
                case .user:
                    Image(systemName: "person.fill")
                    Text("Held by you for \(Format.age(since: lease.since, now: context.date))"
                        + (waiting.isEmpty ? "" : " · \(waiting.count) agent call\(waiting.count == 1 ? "" : "s") waiting"))
                }
            }
        }
        .font(.caption)
        .foregroundStyle(lease.isUser ? Color.blue : Color.purple)
        .lineLimit(1)
        .help(help)
    }

    private var help: String {
        switch lease.holder {
        case .agent(let session):
            "Driven by \(session.agentDescription). Leave it alone until the agent is done."
        case .user:
            (["Agents wait until you release it."] + waiting.map { "Waiting: \($0.session.label) (\($0.action))" })
                .joined(separator: "\n")
        }
    }
}
