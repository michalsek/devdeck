import Foundation
import os

/// Adds and removes DevDeck's hooks in Claude Code's settings.json and Codex's hooks.json.
/// Both use the same shape; entries are recognized by the `devdeck-hook` command, and
/// everything else in the file is left as it was.
@MainActor
final class HookInstaller: ObservableObject {
    private static let log = Logger(subsystem: "dev.devdeck.app", category: "hooks")

    @Published private(set) var installed: Set<AgentKind> = []
    @Published private(set) var lastError: String?

    init() {
        refresh()
        // The app may have moved, or this version wants different hooks; bring them up to
        // date. Only from an app bundle, so a debug run doesn't take the hooks over.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        for agent in installed where !isCurrent(agent) {
            Self.log.info("\(agent.rawValue, privacy: .public): hooks out of date, updating")
            set(agent, enabled: true)
        }
    }

    /// Whether the agent is set up on this Mac (its config folder exists).
    func isAvailable(_ agent: AgentKind) -> Bool {
        FileManager.default.fileExists(atPath: Self.configURL(agent).deletingLastPathComponent().path)
    }

    func set(_ agent: AgentKind, enabled: Bool) {
        let url = Self.configURL(agent)
        let events = try? JSONSerialization.data(withJSONObject: Self.hooks.map {
            ["event": $0.event, "matcher": $0.matcher, "async": $0.async, "timeout": $0.timeout]
        })
        Task {
            let result = await Shell.run("/usr/bin/env", [
                "python3", "-I", "-c", Self.editScript, url.path, Self.command(agent), enabled ? "1" : "0",
                String(decoding: events ?? Data(), as: UTF8.self),
            ])
            lastError = result.ok ? nil : "\(agent.title) hooks: " + result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            Self.log.info("\(agent.rawValue, privacy: .public): hooks \(enabled ? "installed" : "removed", privacy: .public), status \(result.status)")
            refresh()
        }
    }

    func refresh() {
        installed = Set(AgentKind.allCases.filter { !commands(in: Self.configURL($0)).isEmpty })
    }

    // MARK: - Config

    struct Hook: Hashable {
        let event: String
        let matcher: String
        let async: Bool
        let timeout: Int
    }

    /// `PreToolUse` waits for DevDeck's answer (the helper gives up after 540 s, under the
    /// timeout); the others only report, in the background.
    static let hooks: [Hook] = [
        Hook(event: "PreToolUse", matcher: "mcp__argent__.*|Bash", async: false, timeout: 600),
        Hook(event: "Stop", matcher: "", async: true, timeout: 3),
        Hook(event: "SessionEnd", matcher: "", async: true, timeout: 3),
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

    /// The helper ships next to the app's executable. If DevDeck is deleted the hook does
    /// nothing; otherwise the helper's exit code (2 blocks the call) and message pass through.
    static func command(_ agent: AgentKind) -> String {
        let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("devdeck-hook")
        let quoted = "'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "test -x \(quoted) || exit 0; exec \(quoted) \(agent.rawValue)"
    }

    /// Whether the installed hooks are exactly the ones this copy of DevDeck wants.
    private func isCurrent(_ agent: AgentKind) -> Bool {
        let installed = installedHooks(in: Self.configURL(agent))
        return installed.count == Self.hooks.count
            && Set(installed.map(\.hook)) == Set(Self.hooks)
            && installed.allSatisfy { $0.command == Self.command(agent) }
    }

    private func commands(in url: URL) -> [String] {
        installedHooks(in: url).map(\.command)
    }

    private func installedHooks(in url: URL) -> [(hook: Hook, command: String)] {
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let events = json["hooks"] as? [String: Any]
        else { return [] }
        var found: [(Hook, String)] = []
        for (event, groups) in events {
            for group in groups as? [[String: Any]] ?? [] {
                for handler in group["hooks"] as? [[String: Any]] ?? [] {
                    guard let command = handler["command"] as? String, command.contains("devdeck-hook") else { continue }
                    let hook = Hook(
                        event: event, matcher: group["matcher"] as? String ?? "",
                        async: handler["async"] as? Bool ?? false, timeout: handler["timeout"] as? Int ?? 0)
                    found.append((hook, command))
                }
            }
        }
        return found
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
        for hook in events:
            handler = {'type': 'command', 'command': command, 'timeout': hook['timeout']}
            if hook['async']:
                handler['async'] = True
            hooks.setdefault(hook['event'], []).append({'matcher': hook['matcher'], 'hooks': [handler]})
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
