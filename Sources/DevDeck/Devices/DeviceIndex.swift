import Foundation

extension DeviceItem {
    /// Whether an agent's or a tool's name for a device means this one: its id (UDID,
    /// "avd:<name>") or its adb serial.
    func matches(_ key: String) -> Bool { id == key || serial == key || aliases.contains(key) }
}

/// The device list as the broker reads it: devices by any of their names, and which
/// running devices could stand in for another.
struct DeviceIndex {
    let devices: [DeviceItem]

    var running: [DeviceItem] { devices.filter(\.isRunning) }

    func device(_ key: String) -> DeviceItem? { devices.first { $0.matches(key) } }

    func name(of key: String) -> String { device(key)?.name ?? key }

    /// The device ids a target means (a call may name a device by its serial).
    func resolve(_ target: DeviceTarget) -> [String] {
        switch target {
        case .id(let key):
            return [device(key)?.id ?? key]
        case .bootedSimulator:
            let booted = running.filter { $0.kind == .simulator }
            return booted.count == 1 ? [booted[0].id] : []
        case .defaultAndroid:
            let connected = running.filter { $0.platform == .android }
            return connected.count == 1 ? [connected[0].id] : []
        case .allSimulators:
            return running.filter { $0.kind == .simulator }.map(\.id)
        }
    }

    /// Per device: other running simulators or emulators of the same kind and platform.
    func alternatives(for ids: [String]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for id in ids {
            guard let device = device(id), device.kind != .physical else { continue }
            result[id] = running.filter { $0.isSameKind(as: device) && $0.id != device.id }.map(\.id)
        }
        return result
    }

    /// For a call that boots a simulator or emulator: the ones of that kind already running.
    func runningOfKind(booting pools: [Pool], except ids: [String]) -> [String] {
        let kind: DeviceItem.Kind
        if pools.contains(.iosSimulator) {
            kind = .simulator
        } else if pools.contains(.androidEmulator) {
            kind = .emulator
        } else {
            return []
        }
        return running.filter { $0.kind == kind && !ids.contains($0.id) }.map(\.id)
    }

    func isRunning(_ id: String) -> Bool { running.contains { $0.matches(id) } }
}

extension DeviceItem {
    func isSameKind(as other: DeviceItem) -> Bool { kind == other.kind && platform == other.platform }
}
