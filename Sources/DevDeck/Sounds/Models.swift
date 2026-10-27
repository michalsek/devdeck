import Foundation

struct SoundCategory: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let defaultOn: Bool

    static let all: [SoundCategory] = [
        .init(id: "session.start", title: "Session start", detail: "An agent session begins", defaultOn: true),
        .init(id: "task.acknowledge", title: "Task acknowledged", detail: "The agent picks up a prompt", defaultOn: false),
        .init(id: "task.complete", title: "Task complete", detail: "The agent finished and is waiting for you", defaultOn: true),
        .init(id: "task.error", title: "Error", detail: "A tool call or command failed", defaultOn: true),
        .init(id: "input.required", title: "Input required", detail: "Permission prompt or question", defaultOn: true),
        .init(id: "resource.limit", title: "Resource limit", detail: "Context compaction or rate limits", defaultOn: true),
        .init(id: "user.spam", title: "Annoyed", detail: "Easter egg when prompts arrive rapidly", defaultOn: true),
    ]
}

struct Sound: Hashable {
    let url: URL
    let label: String
}

struct SoundPack: Identifiable, Hashable {
    let id: String
    let displayName: String
    let sounds: [String: [Sound]]

    /// Reads a CESP manifest (`openpeon.json`, or legacy `manifest.json`) from a pack directory.
    static func load(from dir: URL) -> SoundPack? {
        let manifestURL = ["openpeon.json", "manifest.json"]
            .map { dir.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let manifestURL,
              let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let name = dir.lastPathComponent
        var sounds: [String: [Sound]] = [:]
        let categories = json["categories"] as? [String: Any] ?? [:]
        for (category, value) in categories {
            let entries = (value as? [String: Any])?["sounds"] as? [[String: Any]] ?? []
            sounds[category] = entries.compactMap { entry in
                guard let file = entry["file"] as? String, !file.isEmpty else { return nil }
                // Same resolution as peon.sh: bare names live in sounds/, paths are pack-relative.
                let url = file.contains("/")
                    ? dir.appendingPathComponent(file)
                    : dir.appendingPathComponent("sounds").appendingPathComponent(file)
                return Sound(url: url, label: entry["label"] as? String ?? file)
            }
        }
        return SoundPack(id: name, displayName: json["display_name"] as? String ?? name, sounds: sounds)
    }
}

enum ClientCatalog {
    /// Clients always offered in the UI, in display order.
    static let pinned = ["claude", "t3code", "codex", "cursor", "opencode", "gemini", "copilot", "windsurf"]

    static let displayNames: [String: String] = [
        "claude": "Claude Code",
        "t3code": "T3 Code",
        "codex": "OpenAI Codex",
        "cursor": "Cursor",
        "opencode": "OpenCode",
        "kilo": "Kilo CLI",
        "kiro": "Kiro",
        "kiro-ide": "Kiro IDE",
        "gemini": "Gemini CLI",
        "copilot": "GitHub Copilot",
        "windsurf": "Windsurf",
        "kimi": "Kimi Code",
        "antigravity": "Antigravity",
        "amp": "Amp",
        "deepagents": "DeepAgents",
        "openclaw": "OpenClaw",
        "rovodev": "Rovo Dev CLI",
        "omp": "oh-my-pi",
        "qwen": "Qwen Code",
        "iflow": "iFlow CLI",
        "trae": "Trae",
        "eca": "ECA",
        "grok": "Grok Build",
    ]

    static let details: [String: String] = [
        "claude": "Claude Code in a terminal or IDE",
        "t3code": "Any agent running inside T3 Code",
    ]

    static func name(for id: String) -> String {
        displayNames[id] ?? id.replacingOccurrences(of: "-", with: " ").capitalized
    }
}
