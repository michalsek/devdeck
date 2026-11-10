import AppKit
import AVFoundation
import Foundation

/// Agent sounds: for each agent event, a sound from the chosen voice pack and, when the
/// agent is done or needs the user, a notification. Packs use peon-ping's format (CESP).
/// Packs and settings live in `~/Library/Application Support/DevDeck/Sounds`.
@MainActor
final class SoundStore: NSObject, ObservableObject, AVAudioPlayerDelegate {
    struct Settings: Codable, Equatable {
        /// DevDeck plays agent sounds (and hooks the events that play them).
        var enabled = false
        var muted = false
        var volume = 0.5
        var pack: String?
        /// Categories switched away from their default.
        var categories: [String: Bool] = [:]
        /// Volume relative to `volume`, per category; 1 when absent.
        var categoryVolumes: [String: Double] = [:]
        var notifications = true

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Settings()
            enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
            muted = try values.decodeIfPresent(Bool.self, forKey: .muted) ?? defaults.muted
            volume = try values.decodeIfPresent(Double.self, forKey: .volume) ?? defaults.volume
            pack = try values.decodeIfPresent(String.self, forKey: .pack)
            categories = try values.decodeIfPresent([String: Bool].self, forKey: .categories) ?? [:]
            categoryVolumes = try values.decodeIfPresent([String: Double].self, forKey: .categoryVolumes) ?? [:]
            notifications = try values.decodeIfPresent(Bool.self, forKey: .notifications) ?? defaults.notifications
        }
    }

    @Published private(set) var settings: Settings
    @Published private(set) var packs: [SoundPack] = []
    /// The sample that's playing, as "pack/category", so its button can show stop.
    @Published private(set) var playingPreview: String?
    @Published private(set) var lastError: String?

    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DevDeck/Sounds")
    static let packsFolder = folder.appendingPathComponent("Packs")
    private static let settingsURL = folder.appendingPathComponent("settings.json")

    private let notifier: Notifier
    private var router = SoundRouter()
    /// The last sound played per category, so the next one differs.
    private var lastPlayed: [String: URL] = [:]
    private var players: [AVAudioPlayer] = []
    private var preview: AVAudioPlayer?
    private var packsWatcher: DispatchSourceFileSystemObject?

    init(notifier: Notifier) {
        self.notifier = notifier
        settings = (try? Data(contentsOf: Self.settingsURL))
            .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        super.init()
        guard !Demo.isOn else { return }
        try? FileManager.default.createDirectory(at: Self.packsFolder, withIntermediateDirectories: true)
        reloadPacks()
        watchPacks()
    }

    var activePack: SoundPack? { packs.first { $0.id == settings.pack } ?? packs.first }

    func isEnabled(_ category: SoundCategory) -> Bool { isEnabled(category.id) }
    func volume(for category: SoundCategory) -> Double { settings.categoryVolumes[category.id] ?? 1 }

    private func isEnabled(_ id: String) -> Bool {
        settings.categories[id] ?? SoundCategory.all.first { $0.id == id }?.defaultOn ?? true
    }

    // MARK: - Agent events

    /// A hook event from an agent: play its sound, and notify when the agent is done or needs
    /// the user, unless the app it runs in is in front.
    func hear(_ json: [String: Any], session: AgentSession, agentPID: Int32?) {
        guard settings.enabled, let event = SoundEvent(json: json) else { return }
        if event.kind == .promptSubmit { notifier.clearAgent(session: session.id) }
        guard let cue = router.route(event, now: .now, isEnabled: isEnabled) else { return }
        if !settings.muted, let pack = activePack, let sound = pick(cue.category, from: pack) {
            play(sound.url, volume: settings.volume * (settings.categoryVolumes[cue.category] ?? 1))
        }
        guard let text = cue.notification, settings.notifications else { return }
        let app = agentPID.flatMap(Self.hostApp)
        guard app?.isActive != true else { return }
        notifier.agent(session: session.id, title: session.project.name, body: text, app: app?.processIdentifier)
    }

    /// A random sound of the category, not the one played last when there's a choice.
    private func pick(_ category: String, from pack: SoundPack) -> Sound? {
        let sounds = pack.sounds[category] ?? []
        let fresh = sounds.count > 1 ? sounds.filter { $0.url != lastPlayed[category] } : sounds
        let sound = fresh.randomElement()
        lastPlayed[category] = sound?.url
        return sound
    }

    @discardableResult
    private func play(_ url: URL, volume: Double) -> AVAudioPlayer? {
        guard volume > 0, let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.volume = Float(min(1, volume))
        player.delegate = self
        player.play()
        players.append(player)
        return player
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated {
            players.removeAll { $0 === player }
            if preview === player {
                preview = nil
                playingPreview = nil
            }
        }
    }

    /// The app the agent runs in: the first of its ancestors that's a regular app.
    private static func hostApp(_ pid: Int32) -> NSRunningApplication? {
        let table = ServerScanner.recentProcessTable()
        var current = pid
        while current > 1 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular { return app }
            guard let parent = table[current]?.ppid else { return nil }
            current = parent
        }
        return nil
    }

    // MARK: - Previews

    func isPlaying(_ category: SoundCategory, pack: SoundPack? = nil) -> Bool {
        playingPreview == Self.previewKey(category, pack ?? activePack)
    }

    /// Plays a sound of the category at its volume, or stops it if that sample is playing.
    func togglePreview(_ category: SoundCategory, pack: SoundPack? = nil) {
        let key = Self.previewKey(category, pack ?? activePack)
        let wasPlaying = playingPreview == key
        preview?.stop()
        if let preview { players.removeAll { $0 === preview } }
        preview = nil
        playingPreview = nil
        guard !wasPlaying, let sound = (pack ?? activePack)?.sounds[category.id]?.randomElement(),
              let player = play(sound.url, volume: settings.volume * volume(for: category))
        else { return }
        preview = player
        playingPreview = key
    }

    private static func previewKey(_ category: SoundCategory, _ pack: SoundPack?) -> String {
        "\(pack?.id ?? "")/\(category.id)"
    }

    // MARK: - Settings

    func setEnabled(_ value: Bool) { update { $0.enabled = value } }
    func setMuted(_ value: Bool) { update { $0.muted = value } }
    func setVolume(_ value: Double) { update { $0.volume = Self.rounded(value) } }
    func setNotifications(_ value: Bool) { update { $0.notifications = value } }
    func usePack(_ id: String) { update { $0.pack = id } }

    func setEnabled(_ category: SoundCategory, _ value: Bool) {
        update { $0.categories[category.id] = value == category.defaultOn ? nil : value }
    }

    func setVolume(_ value: Double, for category: SoundCategory) {
        let rounded = Self.rounded(value)
        update { $0.categoryVolumes[category.id] = rounded >= 1 ? nil : rounded }
    }

    private func update(_ change: (inout Settings) -> Void) {
        change(&settings)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: Self.settingsURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Couldn't save sound settings: \(error.localizedDescription)"
        }
    }

    private static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    // MARK: - Packs

    func revealPacks() { NSWorkspace.shared.open(Self.packsFolder) }

    private func reloadPacks() {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: Self.packsFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        packs = dirs.compactMap(SoundPack.load).sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Packs added or removed in Finder (or by an agent) show up at once.
    private func watchPacks() {
        let fd = open(Self.packsFolder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reloadPacks() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        packsWatcher = source
    }

    // MARK: - From peon-ping

    /// peon-ping's data folder (its hook folder, or `~/.openpeon`), if it's installed.
    static var peonPingFolder: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let claude = env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        return [claude.appendingPathComponent("hooks/peon-ping"), home.appendingPathComponent(".openpeon")]
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("packs").path) }
    }

    /// Copies peon-ping's packs and settings here, removes its hooks, and plays sounds from
    /// DevDeck. peon-ping's files stay where they are.
    func switchFromPeonPing(hooks: HookInstaller) async {
        guard let peon = Self.peonPingFolder else { return }
        let source = peon.appendingPathComponent("packs").resolvingSymlinksInPath()
        for pack in (try? FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
            let target = Self.packsFolder.appendingPathComponent(pack.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            do {
                try FileManager.default.copyItem(at: pack.resolvingSymlinksInPath(), to: target)
            } catch {
                lastError = "Couldn't copy \(pack.lastPathComponent): \(error.localizedDescription)"
            }
        }
        let config = (try? Data(contentsOf: peon.appendingPathComponent("config.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        update { settings in
            if let volume = (config["volume"] as? NSNumber)?.doubleValue { settings.volume = volume }
            settings.pack = config["default_pack"] as? String ?? config["active_pack"] as? String ?? settings.pack
            for (id, on) in config["categories"] as? [String: Bool] ?? [:] {
                let category = SoundCategory.all.first { $0.id == id }
                settings.categories[id] = on == category?.defaultOn ? nil : on
            }
            for (id, volume) in config["category_volumes"] as? [String: NSNumber] ?? [:] where volume.doubleValue < 1 {
                settings.categoryVolumes[id] = volume.doubleValue
            }
            settings.notifications = config["desktop_notifications"] as? Bool ?? settings.notifications
            settings.muted = FileManager.default.fileExists(atPath: peon.appendingPathComponent(".paused").path)
        }
        reloadPacks()
        // Before DevDeck's sound hooks go in, so the two edits of settings.json don't overlap.
        await hooks.removeHooks(containing: "peon-ping/")
        setEnabled(true)
    }
}
