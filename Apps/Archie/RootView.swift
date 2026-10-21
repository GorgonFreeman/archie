import Photos
import SwiftUI

struct RootView: View {
    @StateObject private var settings: SettingsStore
    @StateObject private var importer: ImportCoordinator
    @State private var pin = ""
    @State private var albums: [PHAssetCollection] = []

    init() {
        let settings = SettingsStore()
        _settings = StateObject(wrappedValue: settings)
        _importer = StateObject(wrappedValue: ImportCoordinator(settings: settings))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac receiver") {
                    TextField("PIN", text: $pin)
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                    Button(importer.isRunning ? "Importing…" : "Start import") {
                        Task { await importer.run(pin: pin) }
                    }
                    .disabled(importer.isRunning || pin.count < 4)
                    if importer.isRunning {
                        Button(importer.isPaused ? "Resume" : "Pause") {
                            if importer.isPaused { importer.resume() }
                            else { importer.pause() }
                        }
                    }
                    Text(importer.status)
                        .foregroundStyle(.secondary)
                    if importer.total > 0 {
                        ProgressView(value: Double(importer.progress), total: Double(importer.total))
                    }
                    Text("Deletes when you pause or when the run finishes (one Photos prompt). Tap Allow when asked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Protection") {
                    Toggle("Protect favourites", isOn: $settings.protectFavourites)
                    ForEach(albums, id: \.localIdentifier) { album in
                        Toggle(album.localizedTitle ?? "Album", isOn: Binding(
                            get: { settings.protectedAlbumIds.contains(album.localIdentifier) },
                            set: { _ in settings.toggleAlbum(album.localIdentifier) }
                        ))
                    }
                }

                Section("Summary") {
                    LabeledContent("Imported", value: "\(importer.summary.imported)")
                    LabeledContent("Verified", value: "\(importer.summary.verified)")
                    LabeledContent("Deleted", value: "\(importer.summary.deleted)")
                    LabeledContent("Retained", value: "\(importer.summary.retained)")
                    LabeledContent("Failed", value: "\(importer.summary.failed)")
                    LabeledContent("Bytes verified", value: ByteCountFormatter.string(
                        fromByteCount: importer.summary.bytesVerified,
                        countStyle: .file
                    ))
                    if !PhotoAccess.canDelete {
                        Text("Full Photos access required to delete — imports still run.")
                            .foregroundStyle(.red)
                    }
                }

                if !importer.summary.retainedOutcomes.isEmpty {
                    Section("Retained") {
                        ForEach(importer.summary.retainedOutcomes) { o in
                            Text("\(o.retainReason?.rawValue ?? "?") — \(o.id)")
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .navigationTitle("Archie")
            .task {
                _ = await PhotoAccess.request()
                loadAlbums()
            }
        }
    }

    private func loadAlbums() {
        let result = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: nil
        )
        var list: [PHAssetCollection] = []
        result.enumerateObjects { c, _, _ in list.append(c) }
        albums = list
    }
}
