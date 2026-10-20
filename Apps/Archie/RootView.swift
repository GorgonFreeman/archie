import Photos
import SwiftUI

struct RootView: View {
    @StateObject private var settings: SettingsStore
    @StateObject private var importer: ImportCoordinator
    @State private var pin = ""
    @State private var albums: [PHAssetCollection] = []
    @State private var deleteMessage: String?

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
                    Text(importer.status)
                        .foregroundStyle(.secondary)
                    if importer.total > 0 {
                        ProgressView(value: Double(importer.progress), total: Double(importer.total))
                    }
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
                    LabeledContent("Failed", value: "\(importer.summary.failed)")
                    LabeledContent("Retained", value: "\(importer.summary.retained)")
                    LabeledContent("Deleted", value: "\(importer.summary.deleted)")
                    LabeledContent("Bytes verified", value: ByteCountFormatter.string(
                        fromByteCount: importer.summary.bytesVerified,
                        countStyle: .file
                    ))
                }

                if !importer.summary.eligibleForDelete.isEmpty {
                    Section("Deletion") {
                        Text(
                            "\(importer.summary.eligibleForDelete.count) verified assets "
                                + "(\(ByteCountFormatter.string(fromByteCount: importer.summary.eligibleForDelete.reduce(0) { $0 + $1.bytes }, countStyle: .file))). "
                                + "Favourites/albums are re-checked at delete time."
                        )
                        if !PhotoAccess.canDelete {
                            Text("Full Photos access required to delete.")
                                .foregroundStyle(.red)
                        }
                        Button("Delete verified from iPhone", role: .destructive) {
                            Task {
                                do {
                                    let n = try await DeletionService.deleteEligible(
                                        outcomes: importer.summary.outcomes,
                                        settings: settings
                                    )
                                    var next = importer.summary
                                    next.deleted = n
                                    importer.summary = next
                                    deleteMessage = "Deleted \(n)"
                                } catch {
                                    deleteMessage = error.localizedDescription
                                }
                            }
                        }
                        .disabled(!PhotoAccess.canDelete || importer.isRunning)
                        if let deleteMessage {
                            Text(deleteMessage)
                        }
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
