import ActivityKit
import SwiftUI
import WidgetKit

/// Who is using the simulator: robot-ish `cpu` in purple for an agent, a person in green for you.
/// The activity stays alive while nobody holds the simulator (`free`), so that state renders as
/// an idle island: nothing in the compact and minimal regions.
struct MarkerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DevDeckActivityAttributes.self) { context in
            LockScreenMarker(state: context.state)
        } dynamicIsland: { context in
            let state = context.state
            let island = DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if state.isFree {
                        FreeLine().padding(.leading, 4)
                    } else {
                        Label {
                            Text(state.displayHolder).lineLimit(1)
                        } icon: {
                            Image(systemName: state.symbol).foregroundStyle(state.tint)
                        }
                        .font(.headline)
                        .padding(.leading, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !state.isFree, let detail = state.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 4)
                    }
                }
            } compactLeading: {
                if !state.isFree {
                    Image(systemName: state.symbol).foregroundStyle(state.tint)
                }
            } compactTrailing: {
                if !state.isFree {
                    Text(state.shortHolder).foregroundStyle(state.tint)
                }
            } minimal: {
                if !state.isFree {
                    Image(systemName: state.symbol).foregroundStyle(state.tint)
                }
            }
            .keylineTint(state.isFree ? .clear : state.tint)
            guard state.isFree else { return island }
            // Free: no margins either, so the island stays as close to its idle size as possible.
            return island
                .contentMargins(.all, 0, for: .compactLeading)
                .contentMargins(.all, 0, for: .compactTrailing)
                .contentMargins(.all, 0, for: .minimal)
        }
    }
}

/// "DevDeck · Nobody is using this simulator", for the free state.
private struct FreeLine: View {
    var body: some View {
        HStack(spacing: 8) {
            Image("DevDeckGlyph")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
            Text("DevDeck · Nobody is using this simulator")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.footnote)
    }
}

private struct LockScreenMarker: View {
    let state: MarkerState

    var body: some View {
        Group {
            if state.isFree {
                FreeLine()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 10) {
                    Image("DevDeckGlyph")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                    Label {
                        Text(state.displayHolder).fontWeight(.semibold)
                    } icon: {
                        Image(systemName: state.symbol).foregroundStyle(state.tint)
                    }
                    .lineLimit(1)
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    if let detail = state.detail {
                        Text(detail)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .font(.subheadline)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
