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

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var builds: [BuildJob] = []
    /// Gradle and Kotlin daemons, while no Gradle build is running.
    @Published private(set) var idleDaemons: [Daemon] = []
    @Published private(set) var loaded = false

    @Published var limits: [Pool: Int] {
        didSet { UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: limits.map { ($0.rawValue, $1) }), forKey: "poolLimits") }
    }
    /// Start no heavy work while free memory is below this percentage; 0 turns it off.
    @Published var minFreeMemory: Int {
        didSet { UserDefaults.standard.set(minFreeMemory, forKey: "minFreeMemory") }
    }
    /// Run native builds at background priority while the user is at the Mac.
    @Published var backgroundBuilds: Bool {
        didSet {
            UserDefaults.standard.set(backgroundBuilds, forKey: "backgroundBuilds")
            Task { await updatePriorities() }
        }
    }

    private var timer: Timer?
    private var scanning = false
    /// Processes put at background priority, to restore later.
    private var demoted: Set<Int32> = []
    private var table: [Int32: ServerScanner.ProcessRow] = [:]

    init() {
        let stored = UserDefaults.standard.dictionary(forKey: "poolLimits") as? [String: Int] ?? [:]
        limits = Dictionary(uniqueKeysWithValues: Pool.allCases.map { ($0, stored[$0.rawValue] ?? $0.defaultLimit) })
        minFreeMemory = UserDefaults.standard.object(forKey: "minFreeMemory") as? Int ?? 15
        backgroundBuilds = UserDefaults.standard.bool(forKey: "backgroundBuilds")
        if Demo.isOn {
            snapshot = Demo.snapshot
            builds = Demo.builds
            idleDaemons = Demo.daemons
            loaded = true
            return
        }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    var memoryLow: Bool { minFreeMemory > 0 && (snapshot.memoryFree < minFreeMemory || snapshot.pressure >= 2) }

    func refresh() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let scan = await Task.detached(priority: .utility) { Self.scan() }.value
        snapshot = scan.snapshot
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

    /// While the user is at the Mac (input in the last 2 minutes), builds and the Gradle
    /// daemons doing their work run at background priority: efficiency cores, throttled I/O.
    /// Slower builds, a smooth Mac. Restored when the user is away or the option is off.
    private func updatePriorities() async {
        guard !Demo.isOn else { return }
        let active = LeaseStore.secondsSinceUserInput() < 120
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
    }

    private nonisolated static func scan() -> Scan {
        let table = ServerScanner.processTable()
        let builds = buildJobs(in: table)
        let gradleBuilding = builds.contains { $0.kind == "Gradle build" }
        let daemons = gradleBuilding ? [] : table.values.compactMap { row -> Daemon? in
            let kind = isGradleDaemon(row.command) ? "Gradle daemon"
                : row.command.contains("KotlinCompileDaemon") || row.command.contains("kotlin-daemon") ? "Kotlin daemon" : nil
            return kind.map { Daemon(pid: row.pid, kind: $0, footprint: footprint(row.pid)) }
        }.sorted { $0.footprint > $1.footprint }
        return Scan(snapshot: snapshot(), builds: builds, idleDaemons: daemons, table: table)
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
        let cwds = ServerScanner.workingDirectories(independent.map(\.0.pid))
        return independent.map { row, kind in
            BuildJob(
                pid: row.pid, kind: kind,
                project: cwds[row.pid].map { ServerScanner.project(for: $0, fallback: kind).name },
                started: row.started)
        }.sorted { ($0.started ?? .distantPast) < ($1.started ?? .distantPast) }
    }

    nonisolated static func buildKind(_ row: ServerScanner.ProcessRow) -> String? {
        let command = row.command
        if row.executable == "xcodebuild" { return "Xcode build" }
        if command.contains("org.gradle.wrapper.GradleWrapperMain") || command.contains("org.gradle.launcher.GradleMain") {
            return "Gradle build"
        }
        if command.range(of: #"expo(/bin/cli)? run:(ios|android)"#, options: .regularExpression) != nil { return "Expo run" }
        if command.range(of: #"react-native run-(ios|android)"#, options: .regularExpression) != nil { return "React Native run" }
        if command.contains("eas build") && command.contains("--local") { return "EAS local build" }
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
