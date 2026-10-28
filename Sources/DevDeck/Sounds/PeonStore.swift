import Foundation

/// Reads peon-ping's config/state from disk and writes changes back.
///
/// Mute and pack switching go through the `peon.sh` CLI so its side effects
/// (adapter sync, draft-pack checks) still apply. Plain config keys are patched
/// with a small Python helper so key order and formatting match what peon.sh
/// itself writes.
@MainActor
final class PeonStore: ObservableObject {
    @Published private(set) var paused = false
    @Published private(set) var volume = 0.5
    @Published private(set) var categoryEnabled: [String: Bool] = [:]
    @Published private(set) var categoryVolume: [String: Double] = [:]
    @Published private(set) var defaultPack = "peon"
    @Published private(set) var packs: [SoundPack] = []
    @Published private(set) var rotationMode = "random"
    @Published private(set) var packRotation: [String] = []
    @Published private(set) var disabledClients: Set<String> = []
    @Published private(set) var recentClients: [String: Date] = [:]
    @Published private(set) var desktopNotifications = true
    @Published private(set) var version = ""
    @Published private(set) var supportsClientControls = false
    @Published private(set) var lastError: String?
    /// False when peon-ping isn't installed; DevDeck then hides everything about sounds.
    @Published private(set) var installed = false
    /// The sample that's playing, as "pack/category", so its button can show pause.
    @Published private(set) var playingPreview: String?

    let peonDir: URL
    private var configURL: URL { peonDir.appendingPathComponent("config.json") }
    private var stateURL: URL { peonDir.appendingPathComponent(".state.json") }
    private var pausedURL: URL { peonDir.appendingPathComponent(".paused") }
    private var scriptURL: URL { peonDir.appendingPathComponent("peon.sh") }
    private var timer: Timer?
    private var previewProcess: Process?

    init() {
        peonDir = Self.resolvePeonDir()
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    /// Mirrors peon.sh's data-dir resolution for Homebrew/script installs.
    private static func resolvePeonDir() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["CLAUDE_PEON_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeDir = env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks/peon-ping")
        if FileManager.default.fileExists(atPath: hooksDir.appendingPathComponent("packs").path) {
            return hooksDir
        }
        return home.appendingPathComponent(".openpeon")
    }

    // MARK: - Reading

    func reload() {
        let config = Self.readJSON(configURL)
        let state = Self.readJSON(stateURL)

        installed = FileManager.default.fileExists(atPath: scriptURL.path)
        paused = FileManager.default.fileExists(atPath: pausedURL.path)
        volume = Self.double(config["volume"]) ?? 0.5
        defaultPack = config["default_pack"] as? String ?? config["active_pack"] as? String ?? "peon"
        rotationMode = config["pack_rotation_mode"] as? String ?? "random"
        packRotation = config["pack_rotation"] as? [String] ?? []
        desktopNotifications = config["desktop_notifications"] as? Bool ?? true

        let categories = config["categories"] as? [String: Any] ?? [:]
        categoryEnabled = Dictionary(uniqueKeysWithValues: SoundCategory.all.map {
            ($0.id, categories[$0.id] as? Bool ?? $0.defaultOn)
        })
        let volumes = config["category_volumes"] as? [String: Any] ?? [:]
        categoryVolume = volumes.compactMapValues(Self.double)

        disabledClients = Set(config["disabled_clients"] as? [String] ?? [])
        let recent = state["recent_clients"] as? [String: Any] ?? [:]
        recentClients = recent.compactMapValues { Self.double($0).map(Date.init(timeIntervalSince1970:)) }

        // packs/ is usually a symlink to ~/.openpeon/packs, which directory listing won't follow.
        let packsDir = peonDir.appendingPathComponent("packs").resolvingSymlinksInPath()
        let packDirs = (try? FileManager.default.contentsOfDirectory(
            at: packsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        packs = packDirs.compactMap(SoundPack.load).sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        version = (try? String(contentsOf: peonDir.appendingPathComponent("VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Per-category volume and client gating need a peon.sh that understands them.
        let script = (try? String(contentsOf: scriptURL.resolvingSymlinksInPath(), encoding: .utf8)) ?? ""
        supportsClientControls = script.contains("disabled_clients")
    }

    var activePack: SoundPack? { packs.first { $0.id == defaultPack } }

    /// True when sessions can get a pack other than the default one.
    var hasPackRotation: Bool { !packRotation.isEmpty || rotationMode == "session_override" }

    /// Clients worth showing: pinned ones, anything seen recently, anything disabled.
    var clientIDs: [String] {
        var ids = ClientCatalog.pinned
        for id in (Array(recentClients.keys) + Array(disabledClients)).sorted() where !ids.contains(id) {
            ids.append(id)
        }
        return ids
    }

    func isEnabled(_ category: SoundCategory) -> Bool { categoryEnabled[category.id] ?? category.defaultOn }
    func volume(for category: SoundCategory) -> Double { categoryVolume[category.id] ?? 1.0 }
    func isClientEnabled(_ id: String) -> Bool { !disabledClients.contains(id) }

    // MARK: - Writing

    func setPaused(_ value: Bool) {
        paused = value
        runPeon([value ? "pause" : "resume"])
    }

    func setVolume(_ value: Double) {
        volume = value
        patchConfig([.set(["volume"], Self.rounded(value))])
    }

    func setEnabled(_ category: SoundCategory, _ value: Bool) {
        categoryEnabled[category.id] = value
        patchConfig([.set(["categories", category.id], value)])
    }

    func setVolume(_ value: Double, for category: SoundCategory) {
        let rounded = Self.rounded(value)
        categoryVolume[category.id] = rounded
        // 1.0 is the default, so drop the key rather than store a no-op override.
        patchConfig([rounded >= 1.0
            ? .delete(["category_volumes", category.id])
            : .set(["category_volumes", category.id], rounded)])
    }

    func usePack(_ id: String) {
        defaultPack = id
        runPeon(["packs", "use", id])
    }

    func setClientEnabled(_ id: String, _ value: Bool) {
        if value { disabledClients.remove(id) } else { disabledClients.insert(id) }
        patchConfig([.set(["disabled_clients"], disabledClients.sorted())])
    }

    func setDesktopNotifications(_ value: Bool) {
        desktopNotifications = value
        patchConfig([.set(["desktop_notifications"], value)])
    }

    func isPlaying(_ category: SoundCategory, pack: SoundPack? = nil) -> Bool {
        playingPreview == Self.previewKey(category, pack ?? activePack)
    }

    /// Plays one random sound from the category at its effective volume, or
    /// stops it if that sample is already playing.
    func togglePreview(_ category: SoundCategory, pack: SoundPack? = nil) {
        let key = Self.previewKey(category, pack ?? activePack)
        let wasPlaying = playingPreview == key
        previewProcess?.terminate()
        previewProcess = nil
        playingPreview = nil
        guard !wasPlaying, let sound = (pack ?? activePack)?.sounds[category.id]?.randomElement() else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        let effective = volume * self.volume(for: category)
        process.arguments = ["-v", String(format: "%.3f", effective), sound.url.path]
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self, self.previewProcess === ended else { return }
                self.previewProcess = nil
                self.playingPreview = nil
            }
        }
        guard (try? process.run()) != nil else { return }
        previewProcess = process
        playingPreview = key
    }

    private static func previewKey(_ category: SoundCategory, _ pack: SoundPack?) -> String {
        "\(pack?.id ?? "")/\(category.id)"
    }

    func openConfig() {
        Self.run(URL(fileURLWithPath: "/usr/bin/open"), ["-t", configURL.path]) { _ in }
    }

    // MARK: - Process helpers

    private enum Patch {
        case set([String], Any)
        case delete([String])

        var json: [String: Any] {
            switch self {
            case let .set(path, value): ["path": path, "value": value]
            case let .delete(path): ["path": path, "delete": true]
            }
        }
    }

    /// Applies key-path patches to config.json atomically, preserving key order.
    private func patchConfig(_ patches: [Patch]) {
        guard let data = try? JSONSerialization.data(withJSONObject: patches.map(\.json)),
              let ops = String(data: data, encoding: .utf8)
        else { return }
        let script = """
        import json, os, sys, tempfile
        path = os.path.realpath(sys.argv[1])
        try:
            cfg = json.load(open(path))
        except Exception:
            cfg = {}
        for op in json.loads(sys.argv[2]):
            keys, node = op['path'], cfg
            for key in keys[:-1]:
                if not isinstance(node.get(key), dict):
                    node[key] = {}
                node = node[key]
            if op.get('delete'):
                node.pop(keys[-1], None)
            else:
                node[keys[-1]] = op['value']
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix='.tmp')
        with os.fdopen(fd, 'w') as f:
            json.dump(cfg, f, indent=2)
            f.write('\\n')
        os.replace(tmp, path)
        """
        Self.run(URL(fileURLWithPath: "/usr/bin/env"), ["python3", "-I", "-c", script, configURL.path, ops]) {
            [weak self] result in self?.finish(result)
        }
    }

    private func runPeon(_ args: [String]) {
        Self.run(URL(fileURLWithPath: "/bin/bash"), [scriptURL.path] + args) { [weak self] result in
            self?.finish(result)
        }
    }

    private func finish(_ result: ProcessResult) {
        lastError = result.status == 0 ? nil : result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        reload()
    }

    struct ProcessResult: Sendable {
        let status: Int32
        let output: String
    }

    /// Serial so config writes and pause/resume apply in the order the user made them.
    private static let processQueue = DispatchQueue(label: "DevDeck.peon", qos: .userInitiated)

    /// Runs a process off the main thread with a PATH that finds Homebrew's python3.
    private static func run(
        _ executable: URL, _ args: [String], completion: @escaping @MainActor (ProcessResult) -> Void
    ) {
        processQueue.async {
            let process = Process()
            process.executableURL = executable
            process.arguments = args
            // Run from $HOME so a project-local .claude/hooks/peon-ping/config.json can't take over.
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            var result = ProcessResult(status: -1, output: "")
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                result = ProcessResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
            } catch {
                result = ProcessResult(status: -1, output: error.localizedDescription)
            }
            let finished = result
            DispatchQueue.main.async { completion(finished) }
        }
    }

    private static func readJSON(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let string as String: Double(string)
        default: nil
        }
    }

    private static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
