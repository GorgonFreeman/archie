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

    private var busy: Bool { importer.isRunning || importer.isScanning }
    private var canConnect: Bool { pin.count >= 4 }
    private var scanLabel: String {
        let n = importer.leftoverReadyCount
        let base = importer.isScanning ? "Scanning leftovers" : "Scan leftovers"
        return n > 0 ? "\(base) (\(n))" : base
    }
    private var deleteLabel: String {
        let n = importer.verifiedReadyCount
        return n > 0 ? "Delete Verified (\(n))" : "Delete Verified"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac receiver") {
                    TextField("PIN", text: $pin)
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)

                    Button(importer.isRunning ? "Importing…" : "Import") {
                        Task { await importer.run(pin: pin) }
                    }
                    .disabled(busy || !canConnect)

                    Button(scanLabel) {
                        Task { await importer.scanLeftovers(pin: pin) }
                    }
                    .disabled(busy || !canConnect)

                    Button(deleteLabel) {
                        importer.deleteVerified()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(importer.verifiedReadyCount == 0)

                    if importer.isRunning {
                        Button(importer.isPaused ? "Resume" : "Pause") {
                            if importer.isPaused { importer.resume() }
                            else { importer.pause() }
                        }
                    }

                    Text(importer.status)
                        .foregroundStyle(.secondary)

                    if importer.isScanning {
                        if importer.scanTotal > 0 {
                            ProgressView(
                                value: Double(importer.scanScanned),
                                total: Double(importer.scanTotal)
                            )
                        } else {
                            ProgressView()
                        }
                    } else if importer.total > 0 {
                        ProgressView(
                            value: Double(importer.progress),
                            total: Double(importer.total)
                        )
                    }

                    Text("Import copies to the Mac. Scan leftovers verifies the archive and queues matching phone assets for Delete Verified. Import pauses before the newest month so you can favourite first.")
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
            .alert(item: $importer.recentMonthOffer) { offer in
                Alert(
                    title: Text("Reached \(offer.monthLabel)"),
                    message: Text(
                        "Import paused before the most recent month so you can favourite anything you still want to keep. Protected favourites/albums are skipped on delete. Continue when ready."
                    ),
                    dismissButton: .default(Text("Continue")) {
                        importer.continuePastRecentMonth()
                    }
                )
            }
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
