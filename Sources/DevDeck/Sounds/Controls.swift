import SwiftUI

/// A slider that edits a local copy while dragging and commits once on release,
/// so each drag costs one config write instead of dozens.
struct CommitSlider: View {
    let value: Double
    let commit: (Double) -> Void
    var disabled = false

    @State private var draft: Double = 0
    @State private var editing = false

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $draft, in: 0...1) { isEditing in
                editing = isEditing
                if !isEditing { commit(draft) }
            }
            .controlSize(.small)
            Text("\(Int((draft * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .disabled(disabled)
        .onAppear { draft = value }
        .onChange(of: value) { _, newValue in
            if !editing { draft = newValue }
        }
    }
}

struct PreviewButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.circle")
        }
        .buttonStyle(.borderless)
        .help("Play a sample")
    }
}

/// One row per sound category: on/off, volume relative to master, preview.
/// Compact (menu) puts everything on one line; detailed (settings) adds the description.
struct CategoryRow: View {
    @EnvironmentObject private var store: PeonStore
    let category: SoundCategory
    var showsDetail = false

    var body: some View {
        if showsDetail {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    toggle
                    Spacer()
                    preview
                }
                Text(category.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                slider.padding(.leading, 20)
            }
        } else {
            HStack(spacing: 6) {
                toggle.frame(width: 140, alignment: .leading)
                slider
                preview
            }
        }
    }

    private var enabled: Bool { store.isEnabled(category) }

    private var toggle: some View {
        Toggle(category.title, isOn: Binding(get: { enabled }, set: { store.setEnabled(category, $0) }))
            .toggleStyle(.checkbox)
            .help(category.detail)
    }

    private var slider: some View {
        CommitSlider(
            value: store.volume(for: category),
            commit: { store.setVolume($0, for: category) },
            disabled: !enabled || !store.supportsClientControls
        )
    }

    private var preview: some View {
        PreviewButton { store.preview(category) }
            .disabled(!enabled || (store.activePack?.sounds[category.id]?.isEmpty ?? true))
    }
}
