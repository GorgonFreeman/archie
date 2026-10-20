import Foundation

enum Pairing {
    static func makePin() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}
