import Foundation

/// Persists protect-favourites toggle and protected album localIdentifiers.
final class SettingsStore: ObservableObject {
    @Published var protectFavourites: Bool {
        didSet { defaults.set(protectFavourites, forKey: Keys.protectFavourites) }
    }

    @Published var protectedAlbumIds: [String] {
        didSet { defaults.set(protectedAlbumIds, forKey: Keys.protectedAlbums) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let protectFavourites = "protectFavourites"
        static let protectedAlbums = "protectedAlbumIds"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Keys.protectFavourites) == nil {
            protectFavourites = true
        } else {
            protectFavourites = defaults.bool(forKey: Keys.protectFavourites)
        }
        protectedAlbumIds = defaults.stringArray(forKey: Keys.protectedAlbums) ?? []
    }

    func toggleAlbum(_ id: String) {
        if let idx = protectedAlbumIds.firstIndex(of: id) {
            protectedAlbumIds.remove(at: idx)
        } else {
            protectedAlbumIds.append(id)
        }
    }
}
