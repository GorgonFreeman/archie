import ArchieCore
import XCTest

final class DeviceArchiveTests: XCTestCase {
    func testFolderNameUsesDeviceName() {
        XCTAssertEqual(DeviceArchive.folderName(forDeviceName: "John's iPhone"), "John's iPhone")
    }

    func testFolderNameSanitizesSeparators() {
        XCTAssertEqual(DeviceArchive.folderName(forDeviceName: "Foo/Bar:Baz"), "Foo-Bar-Baz")
    }

    func testFolderNameFallback() {
        XCTAssertEqual(DeviceArchive.folderName(forDeviceName: nil), "iPhone")
        XCTAssertEqual(DeviceArchive.folderName(forDeviceName: "   "), "iPhone")
        XCTAssertEqual(DeviceArchive.folderName(forDeviceName: "../x"), "x")
    }

    func testRootAppendsFolder() {
        let base = URL(fileURLWithPath: "/tmp/ArchieArchive", isDirectory: true)
        let root = DeviceArchive.root(baseArchiveRoot: base, deviceName: "Pixel")
        XCTAssertEqual(root.lastPathComponent, "Pixel")
        XCTAssertEqual(root.deletingLastPathComponent().path, base.path)
    }
}
