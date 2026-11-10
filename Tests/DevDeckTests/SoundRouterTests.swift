import XCTest
@testable import DevDeck

final class SoundRouterTests: XCTestCase {
    /// One router through a timeline: each step is (seconds, session, event, expected cue).
    func testRoutesLikePeonPing() {
        let disabled: Set<String> = ["task.acknowledge"]
        var router = SoundRouter()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let steps: [(Double, String, SoundEvent.Kind, SoundCue?)] = [
            (0, "a", .sessionStart(source: "startup"), SoundCue(category: "session.start", notification: nil)),
            // Another session starting within 30 s doesn't greet again.
            (10, "b", .sessionStart(source: "startup"), nil),
            // Events replayed within 3 s of a session start are silent.
            (11, "b", .stop, nil),
            (20, "a", .stop, SoundCue(category: "task.complete", notification: "Done")),
            (22, "a", .stop, nil),
            // The idle reminder doesn't repeat a completion the session played.
            (30, "a", .notification(type: "idle_prompt"), nil),
            (30, "c", .notification(type: "idle_prompt"), SoundCue(category: "task.complete", notification: "Done")),
            (40, "a", .notification(type: "permission_prompt"), nil),
            (41, "a", .permissionRequest(tool: "Bash"),
             SoundCue(category: "input.required", notification: "Needs approval: Bash")),
            (42, "a", .notification(type: "elicitation_dialog"),
             SoundCue(category: "input.required", notification: "Question pending")),
            // Prompts: acknowledgement is off; the third within 10 s is "annoyed".
            (50, "a", .promptSubmit, nil),
            (52, "a", .promptSubmit, nil),
            (54, "a", .promptSubmit, SoundCue(category: "user.spam", notification: nil)),
            (60, "a", .bashFailed, SoundCue(category: "task.error", notification: nil)),
            (61, "a", .preCompact, SoundCue(category: "resource.limit", notification: "Compacting context")),
            (62, "a", .sessionStart(source: "compact"), nil),
            (70, "a", .sessionEnd, nil),
            // After the session ended its completion is forgotten.
            (71, "a", .notification(type: "idle_prompt"), SoundCue(category: "task.complete", notification: "Done")),
        ]
        for (seconds, session, kind, expected) in steps {
            let cue = router.route(
                SoundEvent(kind: kind, session: session), now: start.addingTimeInterval(seconds),
                isEnabled: { !disabled.contains($0) })
            XCTAssertEqual(cue, expected, "at \(seconds) s: \(kind)")
        }
    }
}
