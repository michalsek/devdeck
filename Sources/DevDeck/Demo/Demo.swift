import Foundation

/// `--demo`: made-up devices, servers, leases and load, for screenshots. Nothing on the
/// Mac is scanned or changed: no socket for agents, no hook updates, no companion installs.
enum Demo {
    static let isOn = CommandLine.arguments.contains("--demo")

    static let iPhonePro = "6A1F2C3D-4B5E-4F60-8A7B-9C0D1E2F3A41"
    static let iPhone = "7B2E3D4C-5A6F-4071-9B8C-0D1E2F3A4B52"
    static let pixel = "avd:Pixel_9"

    static var devices: [DeviceItem] {
        func simulator(_ id: String, _ name: String, _ os: String, running: Bool) -> DeviceItem {
            DeviceItem(id: id, name: name, detail: os, kind: .simulator, platform: .ios, isRunning: running)
        }
        var pixel = DeviceItem(
            id: Self.pixel, name: "Pixel 9", detail: "sdk gphone64 arm64 · Android emulator",
            kind: .emulator, platform: .android, isRunning: true)
        pixel.serial = "emulator-5554"
        pixel.avdName = "Pixel_9"
        var phone = DeviceItem(
            id: "00008150-0011223344556677", name: "Test iPhone", detail: "iPhone 16 · iOS 26.1",
            kind: .physical, platform: .ios, isRunning: true)
        phone.connection = "USB"
        var medium = DeviceItem(
            id: "avd:Medium_Phone", name: "Medium Phone", detail: "Android emulator",
            kind: .emulator, platform: .android, isRunning: false)
        medium.avdName = "Medium_Phone"
        return [
            simulator(iPhonePro, "iPhone 17 Pro", "iOS 26.1", running: true),
            simulator(iPhone, "iPhone 17", "iOS 26.1", running: true),
            pixel,
            phone,
            simulator("8C3F4E5D-6B70-4182-AC9D-1E2F3A4B5C63", "iPad Air 11-inch (M3)", "iOS 26.1", running: false),
            simulator("9D405F6E-7C81-4293-BDAE-2F3A4B5C6D74", "iPhone SE (3rd generation)", "iOS 26.1", running: false),
            medium,
        ]
    }

    static var servers: [DevServer] {
        let started = Date.now.addingTimeInterval(-3 * 3600)
        return [
            DevServer(
                pid: 41201, ports: [8081], kind: "Metro · Expo", group: .devServer, isWeb: false,
                command: "node node_modules/.bin/expo start", cwd: "/Users/you/code/weather-app",
                project: .init(name: "weather-app", subtitle: ""), started: started,
                metro: .init(running: true, port: 8081, apps: ["iPhone 17 Pro"])),
            DevServer(
                pid: 41388, ports: [5173], kind: "Vite", group: .devServer, isWeb: true,
                command: "node node_modules/.bin/vite", cwd: "/Users/you/code/shop-web",
                project: .init(name: "shop-web", subtitle: ""), started: started.addingTimeInterval(5400),
                metro: nil),
            DevServer(
                pid: 39017, ports: [61508], kind: "Tool server", group: .agentTool, isWeb: false,
                command: "node argent tool-server start", cwd: nil,
                project: .init(name: "argent", subtitle: "version 0.30.1"), started: started, metro: nil),
        ]
    }

    static let weather = AgentSession(
        agent: .claude, sessionID: "demo-1", host: "T3 Code", project: .init(name: "weather-app", subtitle: ""))
    static let checkout = AgentSession(
        agent: .claude, sessionID: "demo-2", host: nil, project: .init(name: "checkout-flow", subtitle: ""))

    /// An agent driving the iPhone 17 Pro, the user holding the iPhone 17 with an agent call
    /// waiting for it, and a build waiting for room.
    static func book() -> LeaseBook {
        var book = LeaseBook()
        let now = Date.now
        func call(_ session: AgentSession, _ action: String, _ devices: [String], pools: [Pool] = [], ago: TimeInterval)
            -> LeaseBook.Waiter {
            LeaseBook.Waiter(
                id: UUID(), session: session, action: action, devices: devices, releases: [],
                since: now - ago, deadline: now + 3600, pools: pools)
        }
        _ = book.request(call(weather, "launch-app", [iPhonePro], ago: 1500), now: now - 1500)
        _ = book.request(call(weather, "gesture-tap", [iPhonePro], ago: 8), now: now - 8)
        book.hold(iPhone, now: now - 260)
        _ = book.request(call(checkout, "screenshot", [iPhone], ago: 75), now: now - 75)
        book.resources = .init(usage: [.build: 1], limits: [.build: 1])
        _ = book.request(call(checkout, "npx expo run:android", [], pools: [.build], ago: 40), now: now - 40)
        return book
    }

    static let builds = [
        ResourceMonitor.BuildJob(pid: 52001, kind: "Xcode build", project: "weather-app", started: .now.addingTimeInterval(-95)),
    ]

    static let daemons = [
        ResourceMonitor.Daemon(pid: 17887, kind: "Gradle daemon", footprint: 2_400_000_000),
        ResourceMonitor.Daemon(pid: 20899, kind: "Kotlin daemon", footprint: 650_000_000),
    ]

    static var snapshot: ResourceMonitor.Snapshot {
        var snapshot = ResourceMonitor.Snapshot()
        snapshot.memoryFree = 41
        snapshot.swapUsed = 3_100_000_000
        snapshot.swapTotal = 6_442_450_944
        snapshot.load = 6.3
        snapshot.cores = 14
        return snapshot
    }
}
