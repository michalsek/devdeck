import Combine
import Foundation
import os

/// What the companion app shows on a device (see helpers/README.md).
struct MarkerState: Codable, Equatable {
    var state: String
    var holder: String?
    var host: String?
    var project: String?
    var action: String?
    var since: Int?

    static let free = MarkerState(state: "free")

    init(state: String, holder: String? = nil, host: String? = nil, project: String? = nil,
         action: String? = nil, since: Int? = nil) {
        self.state = state
        self.holder = holder
        self.host = host
        self.project = project
        self.action = action
        self.since = since
    }

    init(lease: LeaseStore.Lease) {
        let since = Int(lease.since.timeIntervalSince1970)
        switch lease.holder {
        case .agent(let session):
            self.init(
                state: "agent", holder: session.agent.title, host: session.host,
                project: session.project.name, action: lease.lastActionName, since: since)
        case .user:
            self.init(state: "user", holder: "You", since: since)
        }
    }

    /// Whether the device needs telling. The last action changes on every call, so it
    /// isn't worth a wake-up on its own.
    func differs(from other: MarkerState?) -> Bool {
        guard let other else { return true }
        return (state, holder, host, project) != (other.state, other.holder, other.host, other.project)
    }

    var json: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) }
}

/// Mirrors each lease onto the simulator or emulator itself through the DevDeck companion
/// app: a Live Activity in the Dynamic Island on iOS, a silent notification on Android.
/// Physical devices are left alone.
@MainActor
final class MarkerController {
    private static let log = Logger(subsystem: "dev.devdeck.app", category: "markers")

    nonisolated static let bundleID = "dev.devdeck.companion"

    private let leases: LeaseStore
    private let devices: DeviceStore
    private let settings: AppSettings
    private var subscription: AnyCancellable?
    /// Last state each device acknowledged.
    private var sent: [String: MarkerState] = [:]
    /// Devices with a companion operation in flight.
    private var working: Set<String> = []
    /// Devices seen shut down, so their next boot can start the iOS marker.
    private var seenStopped: Set<String> = []
    /// Simulators that booted while DevDeck was watching and still need their marker started.
    private var pendingStart: Set<String> = []
    /// Every device seen so far; nil until the first device list arrives.
    private var known: Set<String>?

    init(leases: LeaseStore, devices: DeviceStore, settings: AppSettings) {
        self.leases = leases
        self.devices = devices
        self.settings = settings
        subscription = Publishers.CombineLatest3(leases.$book, devices.$devices, settings.$deviceMarkers)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.reconcile() }
    }

    nonisolated static var companionApp: URL? { resource("DevDeckCompanion.app") }
    nonisolated static var companionAPK: URL? { resource("devdeck-companion.apk") }

    private nonisolated static func resource(_ name: String) -> URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("Companions/" + name)
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Starts the iOS marker now. It brings the companion to the front for a moment,
    /// so it only happens on request or right after a boot.
    func startMarker(on device: DeviceItem) {
        guard device.kind == .simulator else { return }
        sent[device.markerKey] = nil
        pendingStart.insert(device.markerKey)
        reconcile()
    }

    private func reconcile() {
        guard devices.loaded else { return }
        // A simulator that shows up already running was created and booted just now.
        let firstLook = known == nil
        defer { known = (known ?? []).union(devices.devices.map(\.markerKey)) }
        for device in devices.devices where device.kind != .physical {
            if !firstLook, known?.contains(device.markerKey) == false, device.isRunning, device.kind == .simulator {
                pendingStart.insert(device.markerKey)
            }
            if !device.isRunning {
                seenStopped.insert(device.markerKey)
                sent[device.markerKey] = nil
                pendingStart.remove(device.markerKey)
                continue
            }
            if seenStopped.remove(device.markerKey) != nil, device.kind == .simulator {
                pendingStart.insert(device.markerKey)
            }
            guard settings.deviceMarkers, !working.contains(device.markerKey) else { continue }
            let state = leases.lease(for: device).map(MarkerState.init) ?? .free
            let start = pendingStart.contains(device.markerKey)
            guard start || state.differs(from: sent[device.markerKey]) else { continue }

            working.insert(device.markerKey)
            Self.log.info("\(device.markerKey, privacy: .public): sending \(state.state, privacy: .public)\(start ? " (start)" : "", privacy: .public)")
            Task {
                let delivered: Bool
                switch device.kind {
                case .simulator: delivered = await Self.sendToSimulator(device.id, state, start: start)
                case .emulator: delivered = await Self.sendToEmulator(device.serial, state)
                case .physical: delivered = false
                }
                working.remove(device.markerKey)
                Self.log.info("\(device.markerKey, privacy: .public): \(state.state, privacy: .public) \(delivered ? "delivered" : "failed", privacy: .public)")
                if delivered {
                    sent[device.markerKey] = state
                    if start { pendingStart.remove(device.markerKey) }
                }
            }
        }
    }

    // MARK: - iOS simulators

    private nonisolated static func sendToSimulator(_ udid: String, _ state: MarkerState, start: Bool) async -> Bool {
        guard let app = companionApp else { return false }
        var container = await dataContainer(udid)
        if container == nil {
            // Nothing to show yet: install only once there is.
            if state == .free && !start { return true }
            guard await Shell.run("xcrun", ["simctl", "install", udid, app.path], timeout: 60).ok else { return false }
            container = await dataContainer(udid)
        }
        guard let container else { return false }

        let dir = container.appendingPathComponent("Library/DevDeck")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard (try? Data(state.json.utf8).write(to: dir.appendingPathComponent("state.json"), options: .atomic)) != nil
        else { return false }

        if start {
            // Live Activities can only be started from the front; the companion sends
            // itself back to the home screen straight away.
            return await Shell.run("xcrun", [
                "simctl", "launch", "--terminate-running-process", udid, bundleID, "--devdeck-start",
            ], timeout: 30).ok
        }
        // Wakes the companion in the background so it re-reads state.json. simctl exits
        // non-zero because the payload has nothing to show, which is expected.
        let payload = FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-push-\(udid).json")
        try? Data(#"{"aps":{"content-available":1}}"#.utf8).write(to: payload)
        defer { try? FileManager.default.removeItem(at: payload) }
        _ = await Shell.run("xcrun", ["simctl", "push", udid, bundleID, payload.path], timeout: 15)
        return true
    }

    private nonisolated static func dataContainer(_ udid: String) async -> URL? {
        let result = await Shell.run("xcrun", ["simctl", "get_app_container", udid, bundleID, "data"], timeout: 15)
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.ok && !path.isEmpty ? URL(fileURLWithPath: path) : nil
    }

    /// Whether the simulator's Live Activity is running, from the companion's status file.
    nonisolated static func simulatorMarkerActive(_ udid: String) async -> Bool? {
        guard let container = await dataContainer(udid),
              let data = try? Data(contentsOf: container.appendingPathComponent("Library/DevDeck/status.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return json["activity"] as? String == "active"
    }

    // MARK: - Android emulators

    private nonisolated static func sendToEmulator(_ serial: String?, _ state: MarkerState) async -> Bool {
        guard let serial, let apk = companionAPK else { return false }
        let installed = await Shell.run("adb", ["-s", serial, "shell", "pm", "path", bundleID], timeout: 15)
        if !installed.output.contains("package:") {
            if state == .free { return true }
            guard await Shell.run("adb", ["-s", serial, "install", "-r", apk.path], timeout: 120).ok else { return false }
            _ = await Shell.run("adb", [
                "-s", serial, "shell", "pm", "grant", bundleID, "android.permission.POST_NOTIFICATIONS",
            ], timeout: 15)
        }
        // `adb shell` joins its arguments into one remote command line, so quote the JSON.
        let quoted = "'" + state.json.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let result = await Shell.run("adb", [
            "-s", serial, "shell", "am", "broadcast", "-n", bundleID + "/.StateReceiver", "-f", "0x20",
            "--es", "json", quoted,
        ], timeout: 15)
        // "Broadcast completed: result=1, data=\"shown\"" (or hidden, disabled, dismissed, blocked).
        return result.ok && result.output.contains("result=1")
    }
}

private extension DeviceItem {
    /// A running emulator is listed as "avd:<name>" or, while adb is busy, by its serial;
    /// the serial stays the same either way.
    var markerKey: String { serial ?? id }
}
