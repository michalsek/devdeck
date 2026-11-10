import Foundation

/// Why a physical device can't be used right now, and what the user can do about it.
enum DeviceProblem: Hashable {
    case locked, untrusted, unauthorized, offline

    /// "is locked"
    var text: String {
        switch self {
        case .locked: "is locked"
        case .untrusted: "doesn't trust this Mac yet"
        case .unauthorized: "doesn't allow USB debugging from this Mac yet"
        case .offline: "is offline"
        }
    }

    /// "Unlock it."
    var fix: String {
        switch self {
        case .locked: "Unlock it."
        case .untrusted: "Unlock it and tap Trust."
        case .unauthorized: "Unlock it and allow USB debugging in the prompt."
        case .offline: "Unplug it and plug it back in."
        }
    }

    /// A locked phone still takes installs and builds; nothing works while it isn't trusted.
    var blocksEverything: Bool { self != .locked }

    /// What a call for the device waits for: "Test iPhone is locked: unlock it"
    func waiting(for device: String) -> String {
        "\(device) \(text): \(fix.prefix(1).lowercased())\(fix.dropFirst().dropLast())"
    }
}

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
    /// Android: the model, as apps report it to Metro ("sdk_gphone64_arm64", "Pixel 8").
    var model: String?
    /// Android: host ports the device's `adb reverse` rules lead to (e.g. Metro's).
    var reversePorts: [Int] = []
    /// Physical devices: other names tools use for it (CoreDevice identifier, serial number, ECID, its name).
    var aliases: [String] = []
    /// Physical devices: what keeps agents from using it until the user steps in, e.g.
    /// "is locked" or "doesn't allow USB debugging yet".
    var problem: DeviceProblem?

    var shortID: String { String(id.replacingOccurrences(of: Self.avdPrefix, with: "").prefix(8)) }

    /// An emulator's id: "avd:<AVD name>", which stays the same across boots.
    static func avdID(_ name: String) -> String { avdPrefix + name }
    private static let avdPrefix = "avd:"

    var stateLabel: String {
        switch (kind, isRunning) {
        case (.physical, _) where problem != nil: problem == .locked ? "Locked" : "Needs you"
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
/// (`simctl`, `devicectl`, `adb`, `emulator`), on each `Pulse` tick.
@MainActor
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [DeviceItem] = []
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var lastError: String?
    @Published private(set) var loaded = false

    private var refreshing = false
    /// devicectl is slow (about a second), so physical devices refresh every
    /// `physicalInterval` at most, unless forced.
    private var physical: [DeviceItem] = []
    private var physicalScanned = Date.distantPast
    private static let physicalInterval: TimeInterval = 30
    /// Emulator serial → AVD name, so an emulator keeps its id when `adb emu avd name`
    /// is slow to answer (e.g. while adb is installing an app).
    private var knownAVDs: [String: String] = [:]

    init() {
        if Demo.isOn {
            devices = Demo.devices
            loaded = true
            return
        }
        Task { await refresh() }
    }

    var running: [DeviceItem] { devices.filter(\.isRunning) }

    var index: DeviceIndex { DeviceIndex(devices: devices) }

    func devices(_ kind: DeviceItem.Kind) -> [DeviceItem] { devices.filter { $0.kind == kind } }

    func refresh(force: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let includePhysical = force || Date.now.timeIntervalSince(physicalScanned) >= Self.physicalInterval
        if includePhysical { physicalScanned = .now }

        async let simulators = Self.scanSimulators()
        async let android = Self.scanAndroid(knownAVDs: knownAVDs)
        if includePhysical { physical = await Self.scanPhysicalIOS() }
        let all = await simulators + android + physical
        for item in all where item.kind == .emulator {
            if let serial = item.serial, let avd = item.avdName { knownAVDs[serial] = avd }
        }
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
                let result = await Shell.run("simctl", ["boot", device.id])
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
                return await Shell.run("simctl", ["shutdown", device.id])
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
        let result = await Shell.run("simctl", ["list", "devices", "-j"])
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
        let result = await Shell.run("devicectl", ["list", "devices", "--json-output", file.path, "-q"])
        guard result.ok,
              let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = (json["result"] as? [String: Any])?["devices"] as? [[String: Any]]
        else { return [] }

        let items = devices.compactMap { device -> DeviceItem? in
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
            item.aliases = [device["identifier"] as? String, hardware["serialNumber"] as? String,
                            (hardware["ecid"] as? NSNumber).map { $0.stringValue }, properties["name"] as? String]
                .compactMap { $0 }
            if connected, connection["pairingState"] as? String != "paired" {
                item.problem = .untrusted
            }
            return item
        }
        // Only connected, trusted phones can say whether they're locked (about a second each).
        return await withTaskGroup(of: DeviceItem.self) { group in
            for item in items {
                group.addTask {
                    guard item.isRunning, item.problem == nil, await isLocked(item.id) else { return item }
                    var locked = item
                    locked.problem = .locked
                    return locked
                }
            }
            var result: [DeviceItem] = []
            for await item in group { result.append(item) }
            return result
        }
    }

    /// `devicectl device info lockState`: a passcode is needed to use it now.
    nonisolated static func isLocked(_ id: String) async -> Bool {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-lock-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let result = await Shell.run(
            "devicectl", ["device", "info", "lockState", "--device", id, "--json-output", file.path, "-q"], timeout: 10)
        guard result.ok, let data = try? Data(contentsOf: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        return (json["result"] as? [String: Any])?["passcodeRequired"] as? Bool ?? false
    }

    nonisolated static func scanAndroid(knownAVDs: [String: String] = [:]) async -> [DeviceItem] {
        let adb = await Shell.run("adb", ["devices", "-l"])
        let table = ServerScanner.recentProcessTable()
        let listening = LibProc.listeningPorts(table.keys)
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
                let reverses = state == "device" ? await reversePorts(serial) : []

                if serial.hasPrefix("emulator-") {
                    // The emulator listening on the console port (emulator-5554 → 5554) names
                    // its AVD on its command line. Otherwise ask the console, which answers
                    // "Medium_Phone\r\nOK\r\n"; empty or slow means unknown.
                    let console = Int(serial.dropFirst("emulator-".count))
                    let owner = console.flatMap { port in listening.first { $0.value.contains(port) }?.key }
                    var avd = owner.flatMap { table[$0] }.flatMap { avdName(command: $0.command) }
                    if avd == nil {
                        let reply = await Shell.run("adb", ["-s", serial, "emu", "avd", "name"], timeout: 5)
                        avd = reply.ok
                            ? reply.output.split(whereSeparator: \.isNewline).first
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .flatMap { $0.isEmpty ? nil : $0 } ?? knownAVDs[serial]
                            : knownAVDs[serial]
                    }
                    if let avd { runningAVDs.insert(avd) }
                    var item = DeviceItem(
                        id: avd.map(DeviceItem.avdID) ?? serial,
                        name: avd?.replacingOccurrences(of: "_", with: " ") ?? serial,
                        detail: [model, "Android emulator", state == "device" ? nil : state]
                            .compactMap { $0 }.joined(separator: " · "),
                        kind: .emulator, platform: .android, isRunning: true)
                    item.serial = serial
                    item.avdName = avd
                    item.model = info["model"]
                    item.reversePorts = reverses
                    items.append(item)
                } else {
                    var item = DeviceItem(
                        id: serial, name: model ?? serial,
                        detail: ["Android", state == "device" ? nil : state].compactMap { $0 }.joined(separator: " · "),
                        kind: .physical, platform: .android, isRunning: state == "device")
                    switch state {
                    case "unauthorized": item.problem = .unauthorized
                    case "offline": item.problem = .offline
                    case "device": if await isLocked(serial: serial) { item.problem = .locked }
                    default: break
                    }
                    item.serial = serial
                    item.connection = serial.contains(":") ? "Wi-Fi" : "USB"
                    item.model = info["model"]
                    item.reversePorts = reverses
                    items.append(item)
                }
            }
        }

        for name in availableAVDs() where !runningAVDs.contains(name) {
            var item = DeviceItem(
                id: DeviceItem.avdID(name), name: name.replacingOccurrences(of: "_", with: " "),
                detail: "Android emulator", kind: .emulator, platform: .android, isRunning: false)
            item.avdName = name
            items.append(item)
        }
        return items
    }

    /// What `emulator -list-avds` prints: the `<name>.ini` files in the AVD folder.
    nonisolated static func availableAVDs() -> [String] {
        let env = ProcessInfo.processInfo.environment
        let folder = env["ANDROID_AVD_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: env["ANDROID_USER_HOME"] ?? env["ANDROID_EMULATOR_HOME"]
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".android").path)
                .appendingPathComponent("avd")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.filter { $0.hasSuffix(".ini") }.map { String($0.dropLast(4)) }.sorted()
    }

    /// The AVD on an emulator's command line: `-avd Medium_Phone` or `@Medium_Phone`.
    nonisolated static func avdName(command: String) -> String? {
        let args = command.split(separator: " ")
        if let index = args.firstIndex(of: "-avd"), index + 1 < args.count { return String(args[index + 1]) }
        return args.first { $0.hasPrefix("@") && $0.count > 1 }.map { String($0.dropFirst()) }
    }

    /// Whether an Android phone shows its lock screen.
    nonisolated static func isLocked(serial: String) async -> Bool {
        let result = await Shell.run("adb", [
            "-s", serial, "shell", "dumpsys window | grep -E 'mDreamingLockscreen=|isKeyguardShowing=|mShowingLockscreen='",
        ], timeout: 5)
        return result.ok && result.output.range(
            of: #"(mDreamingLockscreen|isKeyguardShowing|mShowingLockscreen)=true"#, options: .regularExpression) != nil
    }

    /// "emulator-5554 tcp:8081 tcp:8081" lines → the host ports (the last field).
    nonisolated static func reversePorts(_ serial: String) async -> [Int] {
        let result = await Shell.run("adb", ["-s", serial, "reverse", "--list"], timeout: 5)
        guard result.ok else { return [] }
        return result.output.split(separator: "\n").compactMap { line in
            line.split(separator: " ").last.flatMap { $0.hasPrefix("tcp:") ? Int($0.dropFirst(4)) : nil }
        }
    }
}
