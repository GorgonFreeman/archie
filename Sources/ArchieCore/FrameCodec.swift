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
        let length = Int(buffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        guard length >= 1, buffer.count >= 4 + length else { return nil }
        let typeByte = buffer[4]
        guard let type = FrameType(rawValue: typeByte) else {
            buffer.removeSubrange(0..<(4 + length))
            return nil
        }
        let payload = buffer.subdata(in: 5..<(4 + length))
        buffer.removeSubrange(0..<(4 + length))
        return (type, payload)
    }
}
