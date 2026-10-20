import ArchieCore
import Foundation
import Network

/// Thin NWConnection send/receive with length-prefixed frames.
final class ConnectionIO: @unchecked Sendable {
    private let connection: NWConnection
    private let parser = FrameParser()
    private let queue: DispatchQueue
    private var pending: [(FrameType, Data)] = []
    private var waiters: [CheckedContinuation<(FrameType, Data), Error>] = []
    private var closed: Error?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        receiveLoop()
    }

    func send(type: FrameType, payload: Data = Data()) async throws {
        let frame = FrameCodec.encode(type: type, payload: payload)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            })
        }
    }

    func sendJSON<T: Encodable>(type: FrameType, value: T) async throws {
        try await send(type: type, payload: MessageCodec.encode(value))
    }

    func receive() async throws -> (FrameType, Data) {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let closed = self.closed {
                    cont.resume(throwing: closed)
                } else if !self.pending.isEmpty {
                    cont.resume(returning: self.pending.removeFirst())
                } else {
                    self.waiters.append(cont)
                }
            }
        }
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: ArchieConstants.chunkSize + 64) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.fail(error)
                    return
                }
                if let content {
                    self.parser.append(content)
                    while let frame = self.parser.nextFrame() {
                        if !self.waiters.isEmpty {
                            self.waiters.removeFirst().resume(returning: frame)
                        } else {
                            self.pending.append(frame)
                        }
                    }
                }
                if isComplete {
                    self.fail(ReceiverError.protocolError("connection closed"))
                    return
                }
                self.receiveLoop()
            }
        }
    }

    private func fail(_ error: Error) {
        closed = error
        let w = waiters
        waiters.removeAll()
        w.forEach { $0.resume(throwing: error) }
    }
}
