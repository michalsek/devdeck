import Foundation

/// An agent hook event, as far as sounds care.
struct SoundEvent: Equatable {
    enum Kind: Equatable {
        /// `source` "compact" is a session resumed after compaction.
        case sessionStart(source: String?)
        case promptSubmit
        case stop
        /// Claude Code's `notification_type`: idle_prompt, permission_prompt, elicitation_dialog, …
        case notification(type: String?)
        case permissionRequest(tool: String?)
        case bashFailed
        case preCompact
        case sessionEnd
    }

    let kind: Kind
    let session: String

    init(kind: Kind, session: String) {
        self.kind = kind
        self.session = session
    }

    /// Nil for events that never make a sound.
    init?(json: [String: Any]) {
        guard let session = json["session_id"] as? String else { return nil }
        self.session = session
        switch json["hook_event_name"] as? String {
        case "SessionStart": kind = .sessionStart(source: json["source"] as? String)
        case "UserPromptSubmit": kind = .promptSubmit
        case "Stop": kind = .stop
        case "Notification": kind = .notification(type: json["notification_type"] as? String)
        case "PermissionRequest": kind = .permissionRequest(tool: json["tool_name"] as? String)
        case "PostToolUseFailure" where json["tool_name"] as? String == "Bash": kind = .bashFailed
        case "PreCompact": kind = .preCompact
        case "SessionEnd": kind = .sessionEnd
        default: return nil
        }
    }
}

/// What to play and say for an event.
struct SoundCue: Equatable {
    let category: String
    /// The notification's text ("Done", "Needs approval: Bash"), nil for no notification.
    let notification: String?
}

/// Picks the sound category for each hook event, with peon-ping's rules for staying quiet:
/// rapid prompts are "annoyed", stops within 5 s and session starts within 30 s play once,
/// events replayed right after a session (re)starts are silent, and an idle reminder
/// doesn't repeat a completion the session already played.
struct SoundRouter {
    static let annoyedPrompts = 3
    static let annoyedWindow: TimeInterval = 10
    static let stopDebounce: TimeInterval = 5
    static let sessionStartCooldown: TimeInterval = 30
    static let replayWindow: TimeInterval = 3
    static let idleRepeatWindow: TimeInterval = 3600

    private var prompts: [String: [Date]] = [:]
    private var sessionStarts: [String: Date] = [:]
    private var completions: [String: Date] = [:]
    private var lastStop = Date.distantPast
    private var lastGreeting = Date.distantPast

    /// The cue for this event, or nil to stay quiet. `isEnabled` says whether a category is on.
    mutating func route(_ event: SoundEvent, now: Date, isEnabled: (String) -> Bool) -> SoundCue? {
        var cue: SoundCue?
        switch event.kind {
        case .sessionStart(let source):
            guard source != "compact" else { return nil }
            sessionStarts[event.session] = now
            guard now.timeIntervalSince(lastGreeting) >= Self.sessionStartCooldown else { return nil }
            cue = SoundCue(category: "session.start", notification: nil)
        case .promptSubmit:
            var times = (prompts[event.session] ?? []).filter { now.timeIntervalSince($0) < Self.annoyedWindow }
            times.append(now)
            prompts[event.session] = times
            if isEnabled("user.spam"), times.count >= Self.annoyedPrompts {
                cue = SoundCue(category: "user.spam", notification: nil)
            } else {
                cue = SoundCue(category: "task.acknowledge", notification: nil)
            }
        case .stop:
            defer { lastStop = now }
            guard now.timeIntervalSince(lastStop) >= Self.stopDebounce else { return nil }
            cue = SoundCue(category: "task.complete", notification: "Done")
        case .notification("idle_prompt"):
            if let done = completions[event.session], now.timeIntervalSince(done) < Self.idleRepeatWindow { return nil }
            cue = SoundCue(category: "task.complete", notification: "Done")
        case .notification("elicitation_dialog"):
            cue = SoundCue(category: "input.required", notification: "Question pending")
        case .notification:
            // permission_prompt sounds through PermissionRequest; other types are silent.
            return nil
        case .permissionRequest(let tool):
            cue = SoundCue(category: "input.required", notification: "Needs approval" + (tool.map { ": " + $0 } ?? ""))
        case .bashFailed:
            cue = SoundCue(category: "task.error", notification: nil)
        case .preCompact:
            cue = SoundCue(category: "resource.limit", notification: "Compacting context")
        case .sessionEnd:
            prompts[event.session] = nil
            sessionStarts[event.session] = nil
            completions[event.session] = nil
            return nil
        }
        guard let found = cue, isEnabled(found.category) else { return nil }
        if found.category == "session.start" {
            lastGreeting = now
        } else if let started = sessionStarts[event.session], now.timeIntervalSince(started) < Self.replayWindow {
            return nil
        }
        if found.category == "task.complete" { completions[event.session] = now }
        return found
    }
}
