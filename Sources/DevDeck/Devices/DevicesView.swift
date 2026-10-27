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
    let device: DeviceItem

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(tone: device.isRunning ? .running : .off)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(device.stateLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // Fixed width keeps the state text aligned for rows without an action.
            Color.clear.frame(width: 84, height: 1).overlay(alignment: .trailing) { actions }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy ID") { Pasteboard.copy(device.serial ?? device.id) }
        }
    }

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
