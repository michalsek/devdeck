import AppKit
import Darwin
import Foundation

/// How loaded the Mac is: memory, CPU, temperature, the native builds running, and build
/// daemons sitting idle. Also holds the limits for each `Pool` and, if asked, runs builds
/// at background priority while the user is at the Mac.
@MainActor
final class ResourceMonitor: ObservableObject {
    struct Snapshot: Equatable {
        /// Share of memory the system considers available, 0–100.
        var memoryFree = 100
        /// 1 normal, 2 warning, 4 critical.
        var pressure = 1
        var swapUsed: UInt64 = 0
        var swapTotal: UInt64 = 0
        /// Bytes moved in and out of swap since the Mac started; nil if it couldn't be read.
        var swapTraffic: UInt64?
        var load: Double = 0
        var cores = ProcessInfo.processInfo.activeProcessorCount
        var thermal = ProcessInfo.ThermalState.nominal

        var pressureLabel: String {
            switch pressure {
            case 4...: "critical"
            case 2...: "warning"
            default: "normal"
            }
        }
    }

    struct BuildJob: Identifiable, Hashable {
        let pid: Int32
        let kind: String
        let project: String?
        let started: Date?
        var id: Int32 { pid }
    }

    struct Daemon: Identifiable, Hashable {
        let pid: Int32
        let kind: String
        let footprint: UInt64
        var id: Int32 { pid }
    }

    /// One of the user's own apps (not a developer tool) and the memory its processes take.
    struct UserApp: Identifiable, Hashable, Sendable {
        let name: String
        /// The app's bundle; its processes are the ones running from inside it.
        let path: String
        var footprint: UInt64 = 0
        var id: String { path }
    }

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var builds: [BuildJob] = []
    /// Gradle and Kotlin daemons, while no Gradle build is running.
    @Published private(set) var idleDaemons: [Daemon] = []
    /// The user's apps, largest first.
    @Published private(set) var userApps: [UserApp] = []
    @Published private(set) var loaded = false

    /// The most of each kind of heavy work the user allows; `limits(usage:)` may allow less.
    @Published var ceilings: [Pool: Int] {
        didSet { UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: ceilings.map { ($0.rawValue, $1) }), forKey: "poolLimits") }
    }
    /// Start no heavy work while free memory is below this percentage; 0 turns it off.
    @Published var minFreeMemory: Int {
        didSet { UserDefaults.standard.set(minFreeMemory, forKey: "minFreeMemory") }
    }
    /// Start no heavy work while the Mac is swapping hard. macOS can report normal memory
    /// pressure while it moves pages in and out of swap all the time, and everything crawls.
    /// How much is swapped out says little: pages stay there long after the pressure is gone.
    @Published var holdWhileSwapping: Bool {
        didSet { UserDefaults.standard.set(holdWhileSwapping, forKey: "holdWhileSwapping") }
    }
    /// Swap traffic (in and out) that counts as swapping hard, in bytes a second, averaged
    /// over `swapWindow`.
    static let swapLimit: Double = 16 * 1_048_576
    static let swapWindow: TimeInterval = 30
    /// Swap-ins plus swap-outs so far, in bytes, with when they were read.
    private var swapSamples: [(date: Date, bytes: UInt64)] = []
    /// Run native builds at background priority while the user is at the Mac.
    @Published var backgroundBuilds: Bool {
        didSet {
            UserDefaults.standard.set(backgroundBuilds, forKey: "backgroundBuilds")
            Task { await updatePriorities() }
        }
    }

    private var scanning = false
    /// Processes put at background priority, to restore later.
    private var demoted: Set<Int32> = []
    private var table: [Int32: ServerScanner.ProcessRow] = [:]

    init() {
        let stored = UserDefaults.standard.dictionary(forKey: "poolLimits") as? [String: Int] ?? [:]
        ceilings = Dictionary(uniqueKeysWithValues: Pool.allCases.map { ($0, stored[$0.rawValue] ?? $0.defaultLimit) })
        minFreeMemory = UserDefaults.standard.object(forKey: "minFreeMemory") as? Int ?? 15
        holdWhileSwapping = UserDefaults.standard.object(forKey: "holdWhileSwapping") as? Bool ?? true
        backgroundBuilds = UserDefaults.standard.bool(forKey: "backgroundBuilds")
        if Demo.isOn {
            snapshot = Demo.snapshot
            builds = Demo.builds
            idleDaemons = Demo.daemons
            loaded = true
            return
        }
        Task { await refresh() }
    }

    var memoryLow: Bool { memoryProblem != nil }

    /// What each pool allows now, given what's running in it: the ceiling, or less to leave
    /// room for the user's apps (see `PoolRoom`). Memory and the app in front are read now.
    func limits(usage: [Pool: Int]) -> [Pool: PoolRoom.Limit] {
        let available = Self.availableMemory()
        let apps = userApps.reduce(0) { $0 + $1.footprint }
        let game = gameInFront
        return Dictionary(uniqueKeysWithValues: Pool.allCases.map { pool in
            (pool, PoolRoom.limit(
                pool, ceiling: ceilings[pool] ?? pool.defaultLimit, used: usage[pool] ?? 0, available: available,
                appsFootprint: apps, game: game))
        })
    }

    /// The name of the app in front when it's a game (its category is one of the games ones).
    var gameInFront: String? {
        guard let app = NSWorkspace.shared.frontmostApplication, let url = app.bundleURL else { return nil }
        let category = gameCategories[url.path] ?? {
            let found = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String ?? ""
            gameCategories[url.path] = found
            return found
        }()
        return category.hasSuffix("games") ? app.localizedName : nil
    }

    private var gameCategories: [String: String] = [:]

    /// Memory macOS can still hand out: kern.memorystatus_level percent of the Mac's memory.
    nonisolated static func availableMemory() -> UInt64 {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        return total / 100 * UInt64(sysctlInt("kern.memorystatus_level") ?? 100)
    }

    /// Developer tools aren't the user's apps: their load is what the pools count.
    private static let developerTools: Set<String> = [
        "com.apple.dt.Xcode", "com.apple.iphonesimulator", "com.google.android.studio",
    ]

    /// Why nothing heavy should start now: "memory is low (12% free)" or "the Mac is swapping
    /// hard (40 MB/s)". macOS reports "warning" pressure often while plenty is still free, so
    /// only critical pressure counts on its own.
    var memoryProblem: String? {
        if minFreeMemory > 0, snapshot.memoryFree < minFreeMemory || snapshot.pressure >= 4 {
            return "memory is low (\(snapshot.memoryFree)% free)"
        }
        if holdWhileSwapping, swapRate > Self.swapLimit {
            return String(format: "the Mac is swapping hard (%.0f MB/s)", swapRate / 1_048_576)
        }
        return nil
    }

    /// Bytes a second moved in and out of swap, over the last `swapWindow`.
    var swapRate: Double {
        guard let first = swapSamples.first, let last = swapSamples.last, last.date > first.date else { return 0 }
        return Double(last.bytes &- first.bytes) / last.date.timeIntervalSince(first.date)
    }

    func refresh() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> UserApp? in
            guard app.activationPolicy == .regular, let url = app.bundleURL, let id = app.bundleIdentifier,
                  !Self.developerTools.contains(id), id != Bundle.main.bundleIdentifier
            else { return nil }
            return UserApp(name: app.localizedName ?? url.deletingPathExtension().lastPathComponent, path: url.path)
        }
        let scan = await Task.detached(priority: .utility) { Self.scan(apps: apps) }.value
        snapshot = scan.snapshot
        userApps = scan.userApps
        let now = Date.now
        if let traffic = scan.snapshot.swapTraffic { swapSamples.append((now, traffic)) }
        swapSamples.removeAll { now.timeIntervalSince($0.date) > Self.swapWindow }
        builds = scan.builds
        idleDaemons = scan.idleDaemons
        table = scan.table
        loaded = true
        await updatePriorities()
    }

    /// Stops idle Gradle and Kotlin daemons; Gradle starts a fresh one for the next build.
    func stopIdleDaemons() {
        for daemon in idleDaemons { kill(daemon.pid, SIGTERM) }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await refresh()
        }
    }

    // MARK: - Priority

    /// The user counts as at the Mac this long after their last input.
    static let activeWindow: TimeInterval = 120

    /// While the user is at the Mac (input in the last `activeWindow`), builds and the Gradle
    /// daemons doing their work run at background priority: efficiency cores, throttled I/O.
    /// Slower builds, a smooth Mac. Restored when the user is away or the option is off.
    private func updatePriorities() async {
        guard !Demo.isOn else { return }
        let active = UserActivity.secondsSinceInput() < Self.activeWindow
        var wanted: Set<Int32> = []
        if backgroundBuilds && active && !builds.isEmpty {
            var children: [Int32: [Int32]] = [:]
            for row in table.values { children[row.ppid, default: []].append(row.pid) }
            var queue = builds.map(\.pid)
            while let pid = queue.popLast() {
                guard wanted.insert(pid).inserted else { continue }
                queue += children[pid] ?? []
            }
            if builds.contains(where: { $0.kind == "Gradle build" }) {
                wanted.formUnion(table.values.filter { Self.isGradleDaemon($0.command) }.map(\.pid))
            }
        }
        let demote = wanted.subtracting(demoted)
        let restore = demoted.subtracting(wanted).filter { table[$0] != nil }
        demoted = wanted
        for pid in demote { _ = await Shell.run("/usr/sbin/taskpolicy", ["-b", "-p", String(pid)], timeout: 5) }
        for pid in restore { _ = await Shell.run("/usr/sbin/taskpolicy", ["-B", "-p", String(pid)], timeout: 5) }
    }

    // MARK: - Scanning

    private struct Scan: Sendable {
        var snapshot: Snapshot
        var builds: [BuildJob]
        var idleDaemons: [Daemon]
        var table: [Int32: ServerScanner.ProcessRow]
        var userApps: [UserApp]
    }

    private nonisolated static func scan(apps: [UserApp]) -> Scan {
        let table = ServerScanner.recentProcessTable()
        var userApps = apps
        for row in table.values {
            guard let index = userApps.firstIndex(where: { row.command.hasPrefix($0.path + "/") }) else { continue }
            userApps[index].footprint += footprint(row.pid)
        }
        let builds = buildJobs(in: table)
        let gradleBuilding = builds.contains { $0.kind == "Gradle build" }
        let daemons = gradleBuilding ? [] : table.values.compactMap { row -> Daemon? in
            return daemonKind(row.command).map { Daemon(pid: row.pid, kind: $0, footprint: footprint(row.pid)) }
        }.sorted { $0.footprint > $1.footprint }
        return Scan(
            snapshot: snapshot(), builds: builds, idleDaemons: daemons, table: table,
            userApps: userApps.filter { $0.footprint > 0 }.sorted { $0.footprint > $1.footprint })
    }

    /// Native builds, counted once each: a build started by another build (expo run →
    /// xcodebuild) is part of it.
    nonisolated static func buildJobs(in table: [Int32: ServerScanner.ProcessRow]) -> [BuildJob] {
        let roots = table.values.compactMap { row -> (ServerScanner.ProcessRow, String)? in
            buildKind(row).map { (row, $0) }
        }
        let rootPIDs = Set(roots.map(\.0.pid))
        let independent = roots.filter { row, _ in
            var parent = row.ppid
            while parent > 1, let next = table[parent] {
                if rootPIDs.contains(parent) { return false }
                parent = next.ppid
            }
            return true
        }
        let cwds = LibProc.workingDirectories(independent.map(\.0.pid))
        return independent.map { row, kind in
            BuildJob(
                pid: row.pid, kind: kind,
                project: cwds[row.pid].map { ServerScanner.project(for: $0, fallback: kind).name },
                started: row.started)
        }.sorted { ($0.started ?? .distantPast) < ($1.started ?? .distantPast) }
    }

    nonisolated static func buildKind(_ row: ServerScanner.ProcessRow) -> String? {
        let command = row.command
        // `test-without-building` runs UI-test runners (argent's, agent-device's) that stay up for hours.
        if row.executable == "xcodebuild" { return row.command.contains(" test-without-building") ? nil : "Xcode build" }
        if command.contains("org.gradle.wrapper.GradleWrapperMain") || command.contains("org.gradle.launcher.GradleMain") {
            return "Gradle build"
        }
        if command.range(of: #"expo(/bin/cli)? run:(ios|android)"#, options: .regularExpression) != nil { return "Expo run" }
        if command.range(of: #"react-native run-(ios|android)"#, options: .regularExpression) != nil { return "React Native run" }
        if command.contains("eas build") && command.contains("--local") { return "EAS local build" }
        return nil
    }

    /// "Gradle daemon" or "Kotlin daemon": build daemons that stay between builds.
    nonisolated static func daemonKind(_ command: String) -> String? {
        if isGradleDaemon(command) { return "Gradle daemon" }
        if command.contains("KotlinCompileDaemon") || command.contains("kotlin-daemon") { return "Kotlin daemon" }
        return nil
    }

    nonisolated static func isGradleDaemon(_ command: String) -> Bool {
        command.contains("org.gradle.launcher.daemon.bootstrap.GradleDaemon")
    }

    /// Memory a process really uses (including compressed and swapped pages).
    nonisolated static func footprint(_ pid: Int32) -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? info.ri_phys_footprint : 0
    }

    nonisolated static func snapshot() -> Snapshot {
        var snapshot = Snapshot()
        snapshot.memoryFree = Int(sysctlInt("kern.memorystatus_level") ?? 100)
        snapshot.pressure = Int(sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1)
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            snapshot.swapUsed = swap.xsu_used
            snapshot.swapTotal = swap.xsu_total
        }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let read = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if read == KERN_SUCCESS {
            snapshot.swapTraffic = (stats.swapins &+ stats.swapouts) &* UInt64(vm_kernel_page_size)
        }
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) > 0 { snapshot.load = loads[0] }
        snapshot.thermal = ProcessInfo.processInfo.thermalState
        return snapshot
    }

    private nonisolated static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "normal"
        case .fair: "warm"
        case .serious: "hot"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
