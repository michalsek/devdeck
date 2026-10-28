import ActivityKit
import SwiftUI

struct MarkerSection: View {
    let store: MarkerStore

    var body: some View {
        Section {
            Toggle("Show marker", isOn: Binding(
                get: { store.markerEnabled },
                set: { enabled in Task { await store.setMarkerEnabled(enabled) } }
            ))
        } footer: {
            if ActivityAuthorizationInfo().areActivitiesEnabled {
                Text("Shows who is using this simulator in the Dynamic Island and on the Lock Screen. DevDeck on your Mac keeps tracking it either way.")
            } else {
                Text("Live Activities are turned off for DevDeck in Settings, so the marker can't appear.")
            }
        }
    }
}
