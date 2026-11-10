import SwiftUI

struct SoundsView: View {
    @EnvironmentObject private var store: SoundStore
    @EnvironmentObject private var hooks: HookInstaller
    @State private var switching = false

    var body: some View {
        Form {
            PageHeader(page: .sounds)
            if !store.settings.enabled, SoundStore.peonPingFolder != nil {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("peon-ping is installed")
                            Text("Switching copies its voice packs and settings to DevDeck and removes its hooks.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Switch from peon-ping") {
                            switching = true
                            Task {
                                await store.switchFromPeonPing(hooks: hooks)
                                switching = false
                            }
                        }
                        .disabled(switching)
                    }
                }
            }
            Section {
                Toggle(isOn: Binding(get: { store.settings.enabled }, set: { store.setEnabled($0) })) {
                    Text("Play agent sounds")
                    Text("For agents with DevDeck's hooks (General)")
                }
            }
            Section {
                Toggle("Mute all sounds", isOn: Binding(get: { store.settings.muted }, set: { store.setMuted($0) }))
                LabeledContent("Volume") {
                    CommitSlider(value: store.settings.volume, commit: store.setVolume, disabled: store.settings.muted)
                        .frame(maxWidth: 260)
                }
                Toggle(isOn: Binding(get: { store.settings.notifications }, set: { store.setNotifications($0) })) {
                    Text("Notifications")
                    Text("When an agent is done or needs you, unless its app is in front")
                }
            }
            .disabled(!store.settings.enabled)
            Section {
                ForEach(SoundCategory.all) { category in
                    CategoryRow(category: category, showsDetail: true)
                }
            } header: {
                Text("Sounds")
            } footer: {
                Text("Each volume is relative to the main volume. At 0% the notification still shows but no sound plays.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!store.settings.enabled)
            if store.lastError != nil {
                Section { ErrorRow(errors: [store.lastError]) }
            }
        }
        .formStyle(.grouped)
    }
}

struct PacksView: View {
    @EnvironmentObject private var store: SoundStore

    var body: some View {
        Form {
            PageHeader(page: .packs)
            Section {
                ForEach(store.packs) { pack in
                    PackRow(pack: pack, selected: pack.id == store.activePack?.id)
                }
                if store.packs.isEmpty {
                    Text("No packs yet").foregroundStyle(.secondary)
                }
            } header: {
                Text("Installed Packs")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("A pack is a folder with an `openpeon.json` (the CESP format peon-ping uses). Put one in the packs folder and it shows up here.")
                    Spacer()
                    Button("Show Packs Folder") { store.revealPacks() }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// A single-choice row: clicking anywhere on it picks the pack; the play button only previews.
private struct PackRow: View {
    @EnvironmentObject private var store: SoundStore
    let pack: SoundPack
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button { store.usePack(pack.id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pack.displayName)
                        Text(pack.id).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            PreviewButton(large: true, playing: store.isPlaying(SoundCategory.all[0], pack: pack)) {
                store.togglePreview(SoundCategory.all[0], pack: pack)
            }
        }
        .padding(.vertical, 2)
    }
}
