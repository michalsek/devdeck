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

/// Plays a sample, and turns into a pause button while it plays (clicking it stops).
/// Large on the dashboard pages, small in the menu.
struct PreviewButton: View {
    var large = false
    let playing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: (playing ? "pause.circle" : "play.circle") + (large ? ".fill" : ""))
                .font(.system(size: large ? 24 : 13))
                .contentTransition(.symbolEffect(.replace))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(large ? Color.accentColor : .secondary)
                .frame(width: large ? 30 : 18, height: large ? 30 : 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(playing ? "Stop" : "Play a sample")
        .accessibilityLabel(playing ? "Stop" : "Play a sample")
    }
}

/// One row per sound category: on/off, volume relative to master, preview.
/// Compact (menu) puts everything on one line; detailed (dashboard) adds the description.
struct CategoryRow: View {
    @EnvironmentObject private var store: PeonStore
    let category: SoundCategory
    var showsDetail = false

    var body: some View {
        if showsDetail {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.title)
                            Text(category.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle(category.title, isOn: enabledBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    slider
                }
                preview
            }
            .padding(.vertical, 2)
        } else {
            HStack(spacing: 6) {
                Toggle(category.title, isOn: enabledBinding)
                    .toggleStyle(.checkbox)
                    .help(category.detail)
                    .frame(width: 140, alignment: .leading)
                slider
                preview
            }
        }
    }

    private var enabled: Bool { store.isEnabled(category) }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { enabled }, set: { store.setEnabled(category, $0) })
    }

    private var slider: some View {
        CommitSlider(
            value: store.volume(for: category),
            commit: { store.setVolume($0, for: category) },
            disabled: !enabled || !store.supportsClientControls
        )
    }

    private var preview: some View {
        PreviewButton(large: showsDetail, playing: store.isPlaying(category)) { store.togglePreview(category) }
            .disabled(!enabled || (store.activePack?.sounds[category.id]?.isEmpty ?? true))
    }
}
