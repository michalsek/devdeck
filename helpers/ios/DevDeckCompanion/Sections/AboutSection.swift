import SwiftUI

struct AboutSection: View {
    var body: some View {
        Section("What is this?") {
            Text("DevDeck on your Mac shows whether a coding agent or you are using this simulator.")
            Text("While an agent drives it, a \(Image(systemName: "cpu")) marker sits in the Dynamic Island. Leave the simulator alone until it's gone.")
        }
    }
}
