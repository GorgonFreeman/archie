import Photos

enum PhotoAccess {
    static func request() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    static var status: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// Spec: under limited access, never delete.
    static var canDelete: Bool {
        status == .authorized
    }

    static var canImport: Bool {
        status == .authorized || status == .limited
    }
}
