import SwiftUI

struct SoundsView: View {
    @EnvironmentObject private var store: PeonStore

    var body: some View {
        Form {
            PageHeader(page: .sounds)
            Section {
                Toggle("Mute all sounds", isOn: Binding(get: { store.paused }, set: { store.setPaused($0) }))
                LabeledContent("Volume") {
                    CommitSlider(value: store.volume, commit: store.setVolume, disabled: store.paused)
                        .frame(maxWidth: 260)
                }
                Toggle(isOn: Binding(
                    get: { store.desktopNotifications }, set: { store.setDesktopNotifications($0) })) {
                    Text("Desktop notifications")
                    Text("peon-ping's banners when an agent finishes or needs you")
                }
            }
            Section {
                ForEach(SoundCategory.all) { category in
                    CategoryRow(category: category, showsDetail: true)
                }
            } header: {
                Text("Sounds")
            } footer: {
                Text(store.supportsClientControls
                    ? "Each volume is relative to the main volume. At 0% the notification still shows but no sound plays."
                    : "Per-sound volume needs a peon-ping build with category_volumes support; on/off works everywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if store.lastError != nil {
                Section { ErrorRow(errors: [store.lastError]) }
            }
        }
        .formStyle(.grouped)
    }
}

struct PacksView: View {
    @EnvironmentObject private var store: PeonStore

    var body: some View {
        Form {
            PageHeader(page: .packs)
            Section {
                ForEach(store.packs) { pack in
                    PackRow(pack: pack, selected: pack.id == store.defaultPack)
                }
            } header: {
                Text("Installed Packs")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if store.hasPackRotation {
                        Text("Rotation mode \"\(store.rotationMode)\" with \(store.packRotation.count) pack(s) can override this for new sessions.")
                    }
                    Text("Install more with `peon packs list --registry` and `peon packs install <name>`.")
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
    @EnvironmentObject private var store: PeonStore
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
            PreviewButton(large: true) { store.preview(SoundCategory.all[0], pack: pack) }
        }
        .padding(.vertical, 2)
    }
}

struct ClientsView: View {
    @EnvironmentObject private var store: PeonStore

    var body: some View {
        Form {
            PageHeader(page: .clients)
            Section {
                ForEach(store.clientIDs, id: \.self) { id in
                    Toggle(isOn: Binding(get: { store.isClientEnabled(id) }, set: { store.setClientEnabled(id, $0) })) {
                        Text(ClientCatalog.name(for: id))
                        Text(subtitle(for: id))
                    }
                }
            } header: {
                Text("Apps Allowed to Play Sounds")
            } footer: {
                Text(store.supportsClientControls
                    ? "A disabled app gets no sounds and no notifications. Agents running inside T3 Code count as T3 Code."
                    : "This needs a peon-ping build with disabled_clients support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!store.supportsClientControls)
        }
        .formStyle(.grouped)
    }

    private func subtitle(for id: String) -> String {
        let detail = ClientCatalog.details[id].map { $0 + " · " } ?? ""
        guard let seen = store.recentClients[id] else { return detail + "not seen in the last 30 days" }
        return detail + "last active " + seen.formatted(.relative(presentation: .named))
    }
}
