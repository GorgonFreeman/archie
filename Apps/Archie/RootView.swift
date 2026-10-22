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
        _pin = State(initialValue: settings.lastPin)
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
                    Button("Scan archive leftovers") {
                        Task { await importer.auditArchiveLeftovers(pin: pin) }
                    }
                    .disabled(importer.isRunning || importer.isAuditing || pin.count < 4)
                    if importer.isAuditing {
                        if importer.auditTotal > 0 {
                            ProgressView(
                                value: Double(importer.auditScanned),
                                total: Double(importer.auditTotal)
                            )
                        } else {
                            ProgressView()
                        }
                        if importer.auditReadyCount > 0 {
                            Button("Delete \(importer.auditReadyCount) verified so far") {
                                importer.deleteAuditLeftoversNow()
                            }
                        }
                    }
                    if importer.isRunning {
                        Button(importer.isPaused ? "Resume" : "Pause") {
                            if importer.isPaused { importer.resume() }
                            else { importer.pause() }
                        }
                        if importer.pendingDeleteCount > 0 {
                            Button("Delete \(importer.pendingDeleteCount) verified so far") {
                                importer.deleteVerifiedNow()
                            }
                        }
                    }
                    Text(importer.status)
                        .foregroundStyle(.secondary)
                    if importer.total > 0 {
                        ProgressView(value: Double(importer.progress), total: Double(importer.total))
                    }
                    Text("Delete verified as they arrive during audit or import. Pause still flushes immediately; end of run asks for any leftover.")
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
            .alert(item: $importer.leftoverOffer) { offer in
                let incompleteNote = offer.incompleteSkipped > 0
                    ? " \(offer.incompleteSkipped) incomplete archive assets were skipped (will reimport)."
                    : ""
                return Alert(
                    title: Text("Delete verified leftovers?"),
                    message: Text(
                        "\(offer.count) assets are fully verified in the Mac archive (every file present, sha256 match) but still on this phone. Delete them now? Protected favourites/albums are skipped.\(incompleteNote)"
                    ),
                    primaryButton: .destructive(Text("Delete \(offer.count)")) {
                        importer.respondToLeftoverOffer(delete: true)
                    },
                    secondaryButton: .cancel(Text("Keep")) {
                        importer.respondToLeftoverOffer(delete: false)
                    }
                )
            }
            .task {
                _ = await PhotoAccess.request()
                loadAlbums()
                // App start: if we have a saved PIN and receiver is up, audit leftovers.
                if pin.count >= 4 {
                    await importer.auditArchiveLeftovers(pin: pin)
                }
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
