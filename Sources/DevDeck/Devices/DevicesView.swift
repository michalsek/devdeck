import AppKit
import SwiftUI

struct DevicesView: View {
    @EnvironmentObject private var store: DeviceStore
    @State private var showStoppedSimulators = false

    var body: some View {
        List {
            section("iOS Simulators", kind: .simulator, emptyText: "No simulators booted")
            section("Android Emulators", kind: .emulator, emptyText: "No Android emulators")
            section("Physical Devices", kind: .physical, emptyText: "No paired devices")
            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .overlay {
            if !store.loaded { ProgressView() }
        }
        .navigationTitle("Devices")
        .navigationSubtitle("\(store.running.count) running")
        .toolbar {
            ToolbarItemGroup {
                Button("Open Simulator", systemImage: "iphone") { store.showSimulatorApp() }
                    .help("Open Simulator.app")
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await store.refresh(force: true) }
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, kind: DeviceItem.Kind, emptyText: String) -> some View {
        let all = store.devices(kind)
        // Shut-down simulators can number in the dozens, so they fold away.
        let visible = kind == .simulator ? all.filter(\.isRunning) : all
        let folded = kind == .simulator ? all.filter { !$0.isRunning } : []
        Section(title) {
            if visible.isEmpty {
                Text(emptyText).foregroundStyle(.secondary)
            }
            ForEach(visible) { DeviceRow(device: $0) }
            if !folded.isEmpty {
                DisclosureGroup("Shut down (\(folded.count))", isExpanded: $showStoppedSimulators) {
                    ForEach(folded) { DeviceRow(device: $0) }
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct DeviceRow: View {
    @EnvironmentObject private var store: DeviceStore
    let device: DeviceItem
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(tone: device.isRunning ? .running : .off)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !compact {
                Text(device.stateLabel)
                    .foregroundStyle(device.isRunning ? .primary : .secondary)
                    .frame(width: 150, alignment: .leading)
            }
            if compact {
                actions
            } else {
                // Fixed width keeps the state column aligned for rows without an action.
                Color.clear.frame(width: 90, height: 1).overlay(alignment: .trailing) { actions }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(device.serial ?? device.id, forType: .string)
            }
        }
    }

    private var subtitle: String {
        var parts = [device.detail]
        if !compact, device.kind != .emulator { parts.append(device.shortID) }
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
                Button(device.startLabel) { store.start(device) }.controlSize(.small)
            }
        }
    }
}
