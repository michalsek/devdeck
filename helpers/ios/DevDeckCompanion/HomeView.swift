import SwiftUI

/// One section per concern; adding device controls later is one more section here.
struct HomeView: View {
    let store: MarkerStore

    var body: some View {
        NavigationStack {
            List {
                CurrentStateSection(state: store.state)
                AboutSection()
                MarkerSection(store: store)
            }
            .navigationTitle("DevDeck")
        }
    }
}
