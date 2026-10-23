import Foundation

public enum FrameCodec {
    public static func encode(type: FrameType, payload: Data = Data()) -> Data {
        var out = Data()
        var length = UInt32(1 + payload.count).bigEndian
        out.append(Data(bytes: &length, count: 4))
        out.append(type.rawValue)
        out.append(payload)
        return out
    }

    public static func encodeJSON<T: Encodable>(type: FrameType, value: T) throws -> Data {
        try encode(type: type, payload: MessageCodec.encode(value))
    }
}

/// Accumulates bytes and yields complete frames.
public final class FrameParser: @unchecked Sendable {
    private var buffer = Data()

    public init() {}

    public func append(_ data: Data) {
        buffer.append(data)
    }

    public func nextFrame() -> (FrameType, Data)? {
        guard buffer.count >= 5 else { return nil }
        // Byte-wise big-endian read — `load(as: UInt32.self)` crashes on unaligned ARM pointers.
        let length = Int(readUInt32BigEndian(at: 0))
        guard length >= 1, buffer.count >= 4 + length else { return nil }
        let typeByte = buffer[4]
        guard let type = FrameType(rawValue: typeByte) else {
            buffer.removeSubrange(0..<(4 + length))
            return nil
        }
        let payload = Data(buffer[5..<(4 + length)])
        buffer.removeSubrange(0..<(4 + length))
        return (type, payload)
    }

    private func readUInt32BigEndian(at offset: Int) -> UInt32 {
        UInt32(buffer[offset]) << 24
            | UInt32(buffer[offset + 1]) << 16
            | UInt32(buffer[offset + 2]) << 8
            | UInt32(buffer[offset + 3])
    }
}
