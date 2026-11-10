import Foundation
import os

/// One thing DevDeck decided or did about an agent, for the Activity page.
struct ActivityEntry: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        /// A call waited, then ran.
        case ranAfterWait
        /// A call was turned away: it waited too long, or the user said no.
        case turnedAway
        /// A call was sent to a free device, or to a running one instead of booting.
        case redirected
        /// The user let a waiting call through.
        case letThrough
        /// A call needs the user's OK (it affects every agent) or breaks their rules.
        case guarded
        /// A device needs the user (locked, not trusted, not connected).
        case needsUser
        /// The user held, took over or released a device.
        case user
        /// An agent-device claim was released.
        case claimReleased
        /// Processes or devices an agent left behind were stopped.
        case cleanedUp
        /// A Metro server: started for an agent, or an app attached to another project's one.
        case metro
    }

    var id = UUID()
    var date = Date.now
    let kind: Kind
    /// "Claude Code · my-app"
    var agent: String?
    /// The device, server or command it was about.
    var subject: String?
    let detail: String
    /// The agent session (`AgentSession.id`), to list a session's activity.
    var session: String?
}

/// What DevDeck decided about agents, newest last, kept for a week in
/// `~/Library/Application Support/DevDeck/activity.jsonl`.
@MainActor
final class ActivityLog: ObservableObject {
    private static let log = Logger(subsystem: "dev.devdeck.app", category: "activity")
    private static let keep: TimeInterval = 7 * 86400
    private static let limit = 2000

    @Published private(set) var entries: [ActivityEntry] = []

    private let file: URL?

    init() {
        if Demo.isOn {
            file = nil
            entries = Demo.activity
            return
        }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DevDeck/activity.jsonl")
        self.file = file
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        let cutoff = Date.now.addingTimeInterval(-Self.keep)
        entries = Array(text.split(separator: "\n")
            .compactMap { try? decoder.decode(ActivityEntry.self, from: Data($0.utf8)) }
            .filter { $0.date > cutoff }
            .suffix(Self.limit))
        rewrite()
    }

    func add(
        _ kind: ActivityEntry.Kind, agent: String? = nil, subject: String? = nil, _ detail: String, session: String? = nil
    ) {
        let entry = ActivityEntry(kind: kind, agent: agent, subject: subject, detail: detail, session: session)
        entries.append(entry)
        Self.log.info("\(kind.rawValue, privacy: .public) \(agent ?? "-", privacy: .public) \(subject ?? "-", privacy: .public): \(detail, privacy: .public)")
        if entries.count > Self.limit + 200 {
            entries.removeFirst(entries.count - Self.limit)
            rewrite()
        } else if let file, var line = try? JSONEncoder().encode(entry) {
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            } else {
                rewrite()
            }
        }
    }

    func clear() {
        entries = []
        rewrite()
    }

    private func rewrite() {
        guard let file else { return }
        let encoder = JSONEncoder()
        var data = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
