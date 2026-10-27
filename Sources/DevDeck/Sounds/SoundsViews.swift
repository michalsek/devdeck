import SwiftUI

struct SoundsView: View {
    @EnvironmentObject private var store: PeonStore

    var body: some View {
        Form {
            Section {
                Toggle("Mute all sounds", isOn: Binding(get: { store.paused }, set: { store.setPaused($0) }))
                LabeledContent("Volume") {
                    CommitSlider(value: store.volume, commit: store.setVolume)
                }
            }
            Section {
                Toggle("Desktop notifications", isOn: Binding(
                    get: { store.desktopNotifications }, set: { store.setDesktopNotifications($0) }))
            } footer: {
                Text("Agent sounds come from peon-ping. Desktop notifications are its banners when an agent finishes or needs you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(SoundCategory.all) { category in
                    CategoryRow(category: category, showsDetail: true)
                }
            } header: {
                Text("Categories")
            } footer: {
                Text(store.supportsClientControls
                    ? "Category volume is relative to the main volume. At 0% the notification still shows but no sound plays."
                    : "Category volume needs a peon-ping build with category_volumes support; on/off works everywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sounds")
    }
}

struct PacksView: View {
    @EnvironmentObject private var store: PeonStore

    var body: some View {
        Form {
            Section {
                ForEach(store.packs) { pack in
                    HStack {
                        Image(systemName: pack.id == store.defaultPack ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(pack.id == store.defaultPack ? Color.accentColor : .secondary)
                        VStack(alignment: .leading) {
                            Text(pack.displayName)
                            Text(pack.id).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        PreviewButton { store.preview(SoundCategory.all[0], pack: pack) }
                        Button("Use") { store.usePack(pack.id) }
                            .disabled(pack.id == store.defaultPack)
                    }
                }
            } header: {
                Text("Installed packs")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if store.hasPackRotation {
                        Text("Rotation mode \"\(store.rotationMode)\" with \(store.packRotation.count) pack(s) can override the default for new sessions.")
                    }
                    Text("Install more with `peon packs list --registry` and `peon packs install <name>`.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Voice Packs")
    }
}

struct ClientsView: View {
    @EnvironmentObject private var store: PeonStore

    var body: some View {
        Form {
            Section {
                ForEach(store.clientIDs, id: \.self) { id in
                    Toggle(isOn: Binding(get: { store.isClientEnabled(id) }, set: { store.setClientEnabled(id, $0) })) {
                        VStack(alignment: .leading) {
                            Text(ClientCatalog.name(for: id))
                            Text(subtitle(for: id)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Apps allowed to play sounds")
            } footer: {
                Text(store.supportsClientControls
                    ? "A disabled client gets no sounds and no notifications. Agents running inside T3 Code count as T3 Code."
                    : "Client control needs a peon-ping build with disabled_clients support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(!store.supportsClientControls)
        .navigationTitle("Clients")
    }

    private func subtitle(for id: String) -> String {
        let detail = ClientCatalog.details[id].map { $0 + " · " } ?? ""
        guard let seen = store.recentClients[id] else { return detail + "not seen in the last 30 days" }
        return detail + "last active " + seen.formatted(.relative(presentation: .named))
    }
}
