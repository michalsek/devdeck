import SwiftUI

struct CurrentStateSection: View {
    let state: MarkerState?

    var body: some View {
        Section("Now") {
            if let state, state.state != .free {
                LabeledContent("Who") {
                    HStack(spacing: 6) {
                        Image(systemName: state.symbol).foregroundStyle(state.tint)
                        Text(state.displayHolder)
                    }
                }
                if let host = state.host, !host.isEmpty {
                    LabeledContent("Via", value: host)
                }
                if let project = state.project, !project.isEmpty {
                    LabeledContent("Project", value: project)
                }
                if let action = state.action, !action.isEmpty {
                    LabeledContent("Action", value: action)
                }
                if let since = state.sinceDate {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        LabeledContent("Since", value: since.formatted(.relative(presentation: .named)))
                    }
                }
            } else {
                LabeledContent("Who", value: "Nobody")
            }
        }
    }
}
