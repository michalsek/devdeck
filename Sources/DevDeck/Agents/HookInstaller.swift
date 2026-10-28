import Foundation

/// Adds and removes DevDeck's hooks in Claude Code's settings.json and Codex's hooks.json.
/// Both use the same shape; entries are recognized by the `devdeck-hook` command, and
/// everything else in the file is left as it was.
@MainActor
final class HookInstaller: ObservableObject {
    @Published private(set) var installed: Set<AgentKind> = []
    @Published private(set) var lastError: String?

    init() {
        refresh()
        // The app may have moved since the hooks were installed; point them at this copy.
        // Only from an app bundle, so a debug run doesn't take the hooks over.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        for agent in installed where !hasCurrentCommand(agent) { set(agent, enabled: true) }
    }

    /// Whether the agent is set up on this Mac (its config folder exists).
    func isAvailable(_ agent: AgentKind) -> Bool {
        FileManager.default.fileExists(atPath: Self.configURL(agent).deletingLastPathComponent().path)
    }

    func set(_ agent: AgentKind, enabled: Bool) {
        let url = Self.configURL(agent)
        let events = try? JSONSerialization.data(withJSONObject: Self.events)
        Task {
            let result = await Shell.run("/usr/bin/env", [
                "python3", "-I", "-c", Self.editScript, url.path, Self.command(agent), enabled ? "1" : "0",
                String(decoding: events ?? Data(), as: UTF8.self),
            ])
            lastError = result.ok ? nil : "\(agent.title) hooks: " + result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            refresh()
        }
    }

    func refresh() {
        installed = Set(AgentKind.allCases.filter { !commands(in: Self.configURL($0)).isEmpty })
    }

    // MARK: - Config

    /// Hook events and matchers. Async, so they never delay the agent.
    static let events: [String: String] = [
        "PreToolUse": "mcp__argent__.*|Bash",
        "SessionEnd": "",
    ]

    static func configURL(_ agent: AgentKind) -> URL {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch agent {
        case .claude:
            let dir = env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
            return dir.appendingPathComponent("settings.json")
        case .codex:
            let dir = env["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
            return dir.appendingPathComponent("hooks.json")
        }
    }

    /// The helper ships next to the app's executable. `|| true` keeps the hook harmless
    /// if DevDeck is deleted.
    static func command(_ agent: AgentKind) -> String {
        let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("devdeck-hook")
        let quoted = "'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "\(quoted) \(agent.rawValue) 2>/dev/null || true"
    }

    private func hasCurrentCommand(_ agent: AgentKind) -> Bool {
        commands(in: Self.configURL(agent)).allSatisfy { $0 == Self.command(agent) }
    }

    private func commands(in url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any]
        else { return [] }
        return hooks.values.compactMap { $0 as? [[String: Any]] }.joined()
            .compactMap { $0["hooks"] as? [[String: Any]] }.joined()
            .compactMap { $0["command"] as? String }
            .filter { $0.contains("devdeck-hook") }
    }

    /// argv: path, command, "1" to install / "0" to remove, events JSON.
    private static let editScript = """
    import json, os, sys, tempfile
    path, command, install, events = os.path.realpath(sys.argv[1]), sys.argv[2], sys.argv[3] == '1', json.loads(sys.argv[4])
    try:
        with open(path) as f:
            cfg = json.load(f)
    except FileNotFoundError:
        cfg = {}
    hooks = cfg.get('hooks', {})
    for event in list(hooks):
        groups = []
        for group in hooks[event]:
            handlers = group.get('hooks', [])
            kept = [h for h in handlers if 'devdeck-hook' not in h.get('command', '')]
            if kept or not handlers:
                group['hooks'] = kept
                groups.append(group)
        if groups:
            hooks[event] = groups
        else:
            del hooks[event]
    if install:
        for event, matcher in events.items():
            hooks.setdefault(event, []).append({'matcher': matcher, 'hooks': [
                {'type': 'command', 'command': command, 'timeout': 3, 'async': True}]})
    if hooks:
        cfg['hooks'] = hooks
    else:
        cfg.pop('hooks', None)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix='.tmp')
    with os.fdopen(fd, 'w') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
        f.write('\\n')
    if os.path.exists(path):
        os.chmod(tmp, os.stat(path).st_mode & 0o777)
    os.replace(tmp, path)
    """
}
