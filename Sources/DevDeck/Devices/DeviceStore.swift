import Foundation

struct DeviceItem: Identifiable, Hashable {
    enum Kind: Hashable { case simulator, emulator, physical }
    enum Platform: String, Hashable { case ios = "iOS", android = "Android" }

    let id: String
    let name: String
    /// Model and OS, e.g. "iOS 27.0" or "iPhone 16 · iOS 27.0".
    let detail: String
    let kind: Kind
    let platform: Platform
    /// Booted simulator, running emulator, or connected physical device.
    let isRunning: Bool
    var connection: String?
    var lastSeen: Date?
    /// adb serial for Android devices, AVD name for emulators.
    var serial: String?
    var avdName: String?

    var shortID: String { String(id.replacingOccurrences(of: "avd:", with: "").prefix(8)) }

    var stateLabel: String {
        switch (kind, isRunning) {
        case (.physical, true): connection.map { "Connected · \($0)" } ?? "Connected"
        case (.physical, false): "Not connected"
        case (_, true): kind == .simulator ? "Booted" : "Running"
        case (_, false): "Shut down"
        }
    }

    var canStop: Bool { isRunning && kind != .physical }
    var canStart: Bool { !isRunning && kind != .physical }
    var stopLabel: String { kind == .simulator ? "Shut Down" : "Stop" }
    var startLabel: String { kind == .simulator ? "Boot" : "Start" }
}

/// Lists simulators, emulators and physical devices with the platform tools
/// (`simctl`, `devicectl`, `adb`, `emulator`), polling every few seconds.
@MainActor
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [DeviceItem] = []
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var lastError: String?
    @Published private(set) var loaded = false

    private var timer: Timer?
    private var refreshing = false
    private var tick = 0
    /// devicectl is slow (about a second), so physical devices refresh less often.
    private var physical: [DeviceItem] = []

    init() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    var running: [DeviceItem] { devices.filter(\.isRunning) }

    func devices(_ kind: DeviceItem.Kind) -> [DeviceItem] { devices.filter { $0.kind == kind } }

    func refresh(force: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let includePhysical = force || tick % 3 == 0
        tick += 1

        async let simulators = Self.scanSimulators()
        async let android = Self.scanAndroid()
        if includePhysical { physical = await Self.scanPhysicalIOS() }
        let all = await simulators + android + physical
        devices = all.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        loaded = true
    }

    // MARK: - Actions

    func start(_ device: DeviceItem) {
        perform(device) {
            switch device.kind {
            case .simulator:
                let result = await Shell.run("xcrun", ["simctl", "boot", device.id])
                // Booting doesn't open a window; Simulator.app shows booted devices.
                _ = await Shell.run("/usr/bin/open", ["-a", "Simulator"])
                return result
            case .emulator:
                guard let avd = device.avdName else { return nil }
                return Shell.spawn("emulator", ["-avd", avd])
                    ? Shell.Result(status: 0, output: "")
                    : Shell.Result(status: 1, output: "Could not start the Android emulator.")
            case .physical:
                return nil
            }
        }
    }

    func stop(_ device: DeviceItem) {
        perform(device) { () -> Shell.Result? in
            switch device.kind {
            case .simulator:
                return await Shell.run("xcrun", ["simctl", "shutdown", device.id])
            case .emulator:
                guard let serial = device.serial else { return nil }
                return await Shell.run("adb", ["-s", serial, "emu", "kill"])
            case .physical:
                return nil
            }
        }
    }

    func showSimulatorApp() {
        Task { _ = await Shell.run("/usr/bin/open", ["-a", "Simulator"]) }
    }

    private func perform(_ device: DeviceItem, _ action: @escaping () async -> Shell.Result?) {
        busy.insert(device.id)
        Task {
            let result = await action()
            if let result, !result.ok {
                lastError = "\(device.name): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            } else {
                lastError = nil
            }
            // Emulators take a while to appear in adb; keep the spinner until the state flips.
            for _ in 0..<12 {
                await refresh(force: true)
                if devices.first(where: { $0.id == device.id })?.isRunning != device.isRunning { break }
                try? await Task.sleep(for: .seconds(1))
            }
            busy.remove(device.id)
        }
    }

    // MARK: - Scanning

    nonisolated static func scanSimulators() async -> [DeviceItem] {
        let result = await Shell.run("xcrun", ["simctl", "list", "devices", "-j"])
        guard result.ok,
              let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
              let runtimes = json["devices"] as? [String: [[String: Any]]]
        else { return [] }
        return runtimes.flatMap { runtime, devices in
            let os = runtimeName(runtime)
            return devices.compactMap { device -> DeviceItem? in
                guard device["isAvailable"] as? Bool ?? true,
                      let udid = device["udid"] as? String,
                      let name = device["name"] as? String
                else { return nil }
                return DeviceItem(
                    id: udid, name: name, detail: os, kind: .simulator, platform: .ios,
                    isRunning: device["state"] as? String == "Booted")
            }
        }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-27-0" → "iOS 27.0"
    nonisolated static func runtimeName(_ identifier: String) -> String {
        let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
        var parts = last.split(separator: "-").map(String.init)
        guard parts.count > 1 else { return last }
        let platform = parts.removeFirst().replacingOccurrences(of: "xrOS", with: "visionOS")
        return "\(platform) \(parts.joined(separator: "."))"
    }

    nonisolated static func scanPhysicalIOS() async -> [DeviceItem] {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("devdeck-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let result = await Shell.run("xcrun", ["devicectl", "list", "devices", "--json-output", file.path, "-q"])
        guard result.ok,
              let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = (json["result"] as? [String: Any])?["devices"] as? [[String: Any]]
        else { return [] }

        return devices.compactMap { device -> DeviceItem? in
            let hardware = device["hardwareProperties"] as? [String: Any] ?? [:]
            guard hardware["reality"] as? String == "physical" else { return nil }
            let properties = device["deviceProperties"] as? [String: Any] ?? [:]
            let connection = device["connectionProperties"] as? [String: Any] ?? [:]
            let transport = connection["transportType"] as? String
            let connected = connection["tunnelState"] as? String == "connected" || transport != nil
            let model = hardware["marketingName"] as? String ?? hardware["productType"] as? String ?? "iOS device"
            let os = (properties["osVersionNumber"] as? String).map { " · iOS \($0)" } ?? ""
            var item = DeviceItem(
                id: hardware["udid"] as? String ?? device["identifier"] as? String ?? UUID().uuidString,
                name: properties["name"] as? String ?? model,
                detail: model + os, kind: .physical, platform: .ios, isRunning: connected)
            item.connection = switch transport {
            case "wired": "USB"
            case "localNetwork": "Wi-Fi"
            default: nil
            }
            item.lastSeen = (connection["lastConnectionDate"] as? String)
                .flatMap { try? Date($0, strategy: .iso8601) }
            return item
        }
    }

    nonisolated static func scanAndroid() async -> [DeviceItem] {
        async let avdsResult = Shell.run("emulator", ["-list-avds"])
        let adb = await Shell.run("adb", ["devices", "-l"])
        var items: [DeviceItem] = []
        var runningAVDs: Set<String> = []

        if adb.ok {
            for line in adb.output.split(separator: "\n").dropFirst() {
                let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard fields.count >= 2, !fields[0].hasPrefix("*") else { continue }
                let serial = fields[0]
                let state = fields[1]
                let info = Dictionary(fields.dropFirst(2).compactMap { field -> (String, String)? in
                    let pair = field.split(separator: ":", maxSplits: 1).map(String.init)
                    return pair.count == 2 ? (pair[0], pair[1]) : nil
                }, uniquingKeysWith: { first, _ in first })
                let model = info["model"]?.replacingOccurrences(of: "_", with: " ")

                if serial.hasPrefix("emulator-") {
                    let avd = await Shell.run("adb", ["-s", serial, "emu", "avd", "name"], timeout: 5)
                        .output.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
                    if let avd { runningAVDs.insert(avd) }
                    var item = DeviceItem(
                        id: avd.map { "avd:\($0)" } ?? serial,
                        name: avd?.replacingOccurrences(of: "_", with: " ") ?? serial,
                        detail: [model, "Android emulator", state == "device" ? nil : state]
                            .compactMap { $0 }.joined(separator: " · "),
                        kind: .emulator, platform: .android, isRunning: true)
                    item.serial = serial
                    item.avdName = avd
                    items.append(item)
                } else {
                    var item = DeviceItem(
                        id: serial, name: model ?? serial,
                        detail: ["Android", state == "device" ? nil : state].compactMap { $0 }.joined(separator: " · "),
                        kind: .physical, platform: .android, isRunning: state == "device")
                    item.serial = serial
                    item.connection = serial.contains(":") ? "Wi-Fi" : "USB"
                    items.append(item)
                }
            }
        }

        let avds = await avdsResult
        if avds.ok {
            for name in avds.output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
            where !name.isEmpty && !name.contains(" ") && !runningAVDs.contains(name) {
                var item = DeviceItem(
                    id: "avd:\(name)", name: name.replacingOccurrences(of: "_", with: " "),
                    detail: "Android emulator", kind: .emulator, platform: .android, isRunning: false)
                item.avdName = name
                items.append(item)
            }
        }
        return items
    }
}
