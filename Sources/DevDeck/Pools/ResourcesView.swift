import SwiftUI

/// The Mac's load, the limits for heavy work, the calls waiting for room, and idle
/// build daemons that can be stopped to free memory.
struct ResourcesView: View {
    @EnvironmentObject private var monitor: ResourceMonitor
    @EnvironmentObject private var leases: LeaseStore
    @EnvironmentObject private var devices: DeviceStore
    @EnvironmentObject private var servers: ServerStore

    var body: some View {
        Form {
            PageHeader(page: .resources)
            Section("This Mac") {
                LabeledContent("Memory available") {
                    HStack(spacing: 10) {
                        Gauge(value: Double(monitor.snapshot.memoryFree), in: 0...100) { EmptyView() }
                            .gaugeStyle(.accessoryLinearCapacity)
                            .tint(monitor.memoryLow ? .orange : .green)
                            .frame(width: 120)
                        Text("\(monitor.snapshot.memoryFree)% · pressure \(monitor.snapshot.pressureLabel)")
                            .monospacedDigit()
                    }
                }
                LabeledContent("Swap used", value: "\(gigabytes(monitor.snapshot.swapUsed)) of \(gigabytes(monitor.snapshot.swapTotal))")
                LabeledContent("CPU load", value: String(format: "%.1f on %d cores", monitor.snapshot.load, monitor.snapshot.cores))
                LabeledContent("Temperature", value: monitor.snapshot.thermal.label)
            }

            Section {
                ForEach(Pool.allCases) { pool in
                    LabeledContent {
                        Stepper(value: limit(pool), in: 1...10) {
                            Text("limit \(monitor.limits[pool] ?? pool.defaultLimit)").monospacedDigit()
                        }
                        .fixedSize()
                    } label: {
                        Text(pool.title)
                        Text(running(pool))
                    }
                }
            } header: {
                Text("Limits")
            } footer: {
                Text("An agent that boots a simulator or emulator, starts a native build or starts a dev server over its limit waits until there's room (up to 9 minutes). Your own work counts towards the limits, but is never held back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(selection: $monitor.minFreeMemory) {
                    Text("Never").tag(0)
                    ForEach([10, 15, 20, 25, 30], id: \.self) { Text("Below \($0)% free").tag($0) }
                } label: {
                    Text("Hold heavy work when memory is low")
                    Text("Also while macOS reports memory pressure")
                }
                Toggle(isOn: $monitor.backgroundBuilds) {
                    Text("Run builds at background priority while you're at the Mac")
                    Text("Native builds use the efficiency cores and slower disk access, so they take longer but the Mac stays smooth. Back to normal after 2 minutes without input.")
                }
            } header: {
                Text("Keeping the Mac Responsive")
            }

            if !leases.waitingForRoom.isEmpty {
                Section("Waiting for Room") {
                    ForEach(leases.waitingForRoom) { waiter in
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            HStack {
                                Image(systemName: "hourglass").foregroundStyle(.orange).frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(waiter.session.label)
                                    Text("\(waiter.action) · \(waiter.pools.map(\.title).joined(separator: ", ")) · waiting \(Format.age(since: waiter.since, now: context.date))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Run Now") { leases.runNow(waiter) }
                                    .help("Let it start despite the limits")
                                Button("Turn Away") { leases.dismiss(waiter) }
                                    .help("Stop it waiting; the agent is told the Mac is busy")
                            }
                        }
                    }
                }
            }

            if !monitor.idleDaemons.isEmpty {
                Section {
                    ForEach(monitor.idleDaemons) { daemon in
                        LabeledContent(daemon.kind, value: gigabytes(daemon.footprint))
                    }
                    HStack {
                        Spacer()
                        Button("Stop Idle Daemons") { monitor.stopIdleDaemons() }
                    }
                } header: {
                    Text("Idle Build Daemons")
                } footer: {
                    Text("Gradle and Kotlin keep these running between builds. Stopping them frees the memory; the next Android build starts a little slower.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func limit(_ pool: Pool) -> Binding<Int> {
        Binding(get: { monitor.limits[pool] ?? pool.defaultLimit }, set: { monitor.limits[pool] = $0 })
    }

    /// "2 running: iPhone 17, Pixel 9"
    private func running(_ pool: Pool) -> String {
        let names: [String] = switch pool {
        case .iosSimulator: devices.running.filter { $0.kind == .simulator }.map(\.name)
        case .androidEmulator: devices.running.filter { $0.kind == .emulator }.map(\.name)
        case .build: monitor.builds.map { [$0.kind, $0.project].compactMap { $0 }.joined(separator: " · ") }
        case .devServer: servers.devServers.map(\.project.name)
        }
        return names.isEmpty ? "None running" : "\(names.count) running: " + names.joined(separator: ", ")
    }

    private func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}
