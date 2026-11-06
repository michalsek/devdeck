import SwiftUI

/// Under a device an agent-device session has claimed: "Stale agent-device claim · maps-app ·
/// last command 58 min ago" (the session and who opened it are in the tooltip).
struct ClaimLine: View {
    @EnvironmentObject private var claims: ClaimStore
    let status: ClaimStatus

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = claims.state(of: status, now: context.date)
            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                Text(ClaimText.summary(status, state: state, now: context.date))
            }
            .foregroundStyle(state.isStale ? Color.orange : Color.purple)
        }
        .font(.caption)
        .lineLimit(1)
        .help(ClaimHelp.text(status, owner: claims.owner(of: status)))
    }
}

enum ClaimHelp {
    /// Tooltip: the session, who drives it, and what Release Claim does.
    static func text(_ status: ClaimStatus, owner: ClaimOwner?) -> String {
        var lines = ["agent-device session \(status.claim.session) has claimed this device; other sessions get DEVICE_IN_USE until it closes."]
        if let owner { lines.append("Opened by \(owner.session.agentDescription) in \(owner.session.project.name).") }
        if !status.claim.workspace.isEmpty { lines.append("Workspace: \(status.claim.workspace)") }
        lines.append("Release Claim closes the session. The agent that opened it has to open the device again.")
        return lines.joined(separator: "\n")
    }
}
