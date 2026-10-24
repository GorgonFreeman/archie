import Foundation
import Network

/// Phone-side Bonjour + TLS client. Speaks the Archie frame protocol.
public final class TransferClient: @unchecked Sendable {
    private let pin: String
    private let deviceName: String
    private let queue = DispatchQueue(label: "archie.client")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var io: ClientIO?
    private var readyCont: CheckedContinuation<Void, Error>?
    private var alive = false

    public init(pin: String, deviceName: String) {
        self.pin = pin
        self.deviceName = deviceName
    }

    /// False after the NWConnection fails/cancels or IO is closed.
    public var isAlive: Bool {
        queue.sync {
            guard alive, let io else { return false }
            return !io.isClosedUnlocked
        }
    }

    public func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            readyCont = cont
            startBrowser()
        }
        guard let io else { throw TransferError.notConnected }
        try await io.sendJSON(
            type: .hello,
            value: HelloPayload(role: "iphone", pin: pin, deviceName: deviceName)
        )
        let (type, payload) = try await io.receive(timeoutNanoseconds: ArchieConstants.ioTimeoutNanoseconds)
        switch type {
        case .hello:
            _ = try MessageCodec.decode(HelloPayload.self, from: payload)
        case .fail:
            let fail = try MessageCodec.decode(FailPayload.self, from: payload)
            throw TransferError.rejected(fail.reason)
        default:
            throw TransferError.protocolError("expected HELLO ack")
        }
    }

    /// Tear down Bonjour/TLS so `connect()` / `reconnect()` can start clean.
    public func disconnect() {
        queue.sync {
            browser?.cancel()
            browser = nil
            connection?.cancel()
            connection = nil
            if let io {
                io.noteClosed(TransferError.connectionLost("disconnected"))
            }
            self.io = nil
            alive = false
            if let cont = readyCont {
                readyCont = nil
                cont.resume(throwing: TransferError.connectionLost("disconnected"))
            }
        }
    }

    /// Drop the dead link and Bonjour+HELLO again (same PIN).
    public func reconnect() async throws {
        disconnect()
        try await connect()
    }

    /// Cheap liveness check (used before resume). Throws `connectionLost` if the link is dead.
    public func ping() async throws {
        guard isAlive, let io else { throw TransferError.connectionLost("not connected") }
        try await io.send(type: .ping)
        let (type, _) = try await io.receive(timeoutNanoseconds: ArchieConstants.pingTimeoutNanoseconds)
        guard type == .pong else {
            throw TransferError.protocolError("expected PONG")
        }
    }

    /// Settled archive assetIds (resources present on disk). Fast — no SHA verify.
    public func fetchSettledIds() async throws -> Set<String> {
        guard let io else { throw TransferError.notConnected }
        try await io.send(type: .settledIdsFetch)
        let (type, payload) = try await io.receive(timeoutNanoseconds: ArchieConstants.ioTimeoutNanoseconds)
        switch type {
        case .settledIdsResult:
            let body = try MessageCodec.decode(SettledIdsPayload.self, from: payload)
            return Set(body.assetIds)
        case .fail:
            let fail = try MessageCodec.decode(FailPayload.self, from: payload)
            throw TransferError.rejected(fail.reason)
        default:
            throw TransferError.protocolError("expected SETTLED_IDS_RESULT")
        }
    }

    public func sendResource(
        begin: AssetBeginPayload,
        bytes: AsyncThrowingStream<Data, Error>
    ) async throws -> ReceiptPayload {
        guard let io else { throw TransferError.notConnected }
        try await io.sendJSON(type: .assetBegin, value: begin)
        for try await chunk in bytes {
            try await io.send(type: .chunk, payload: chunk)
        }
        try await io.sendJSON(
            type: .resourceEnd,
            value: ResourceEndPayload(sha256: begin.declaredSha256, size: begin.size)
        )
        let (type, payload) = try await io.receive(timeoutNanoseconds: ArchieConstants.ioTimeoutNanoseconds)
        switch type {
        case .receipt:
            let receipt = try MessageCodec.decode(ReceiptPayload.self, from: payload)
            // Phone-side gate: never treat a mismatched receipt as success.
            guard receipt.sha256.lowercased() == begin.declaredSha256.lowercased(),
                  receipt.size == begin.size,
                  !receipt.relativePath.isEmpty else {
                throw TransferError.protocolError("receipt does not match declared hash/size")
            }
            return receipt
        case .fail:
            let fail = try MessageCodec.decode(FailPayload.self, from: payload)
            throw TransferError.rejected(fail.reason)
        default:
            throw TransferError.protocolError("expected RECEIPT")
        }
    }

    /// Ask Mac to date-rename the verified asset; required before phone delete.
    public func settleAsset(assetId: String) async throws -> AssetSettledPayload {
        guard let io else { throw TransferError.notConnected }
        try await io.sendJSON(type: .assetSettle, value: AssetSettlePayload(assetId: assetId))
        let (type, payload) = try await io.receive(timeoutNanoseconds: ArchieConstants.ioTimeoutNanoseconds)
        switch type {
        case .assetSettled:
            let settled = try MessageCodec.decode(AssetSettledPayload.self, from: payload)
            guard settled.assetId == assetId else {
                throw TransferError.protocolError("settle assetId mismatch")
            }
            return settled
        case .fail:
            let fail = try MessageCodec.decode(FailPayload.self, from: payload)
            throw TransferError.rejected(fail.reason)
        default:
            throw TransferError.protocolError("expected ASSET_SETTLED")
        }
    }

    /// Stream archive verification progress (complete assetId deltas). Ends after final result frame.
    public func streamArchiveIndex(
        onProgress: @escaping @Sendable (ArchiveIndexProgressPayload) async -> Void
    ) async throws {
        guard let io else { throw TransferError.notConnected }
        try await io.send(type: .archiveIndex)
        while true {
            // Long verify: wait indefinitely between progress frames, but fail if the socket dies.
            let (type, payload) = try await io.receive(timeoutNanoseconds: nil)
            switch type {
            case .archiveIndexProgress:
                let progress = try MessageCodec.decode(ArchiveIndexProgressPayload.self, from: payload)
                await onProgress(progress)
                if progress.finished { continue } // wait for result ack
            case .archiveIndexResult:
                _ = try MessageCodec.decode(ArchiveIndexPayload.self, from: payload)
                return
            case .fail:
                let fail = try MessageCodec.decode(FailPayload.self, from: payload)
                throw TransferError.rejected(fail.reason)
            default:
                throw TransferError.protocolError("expected ARCHIVE_INDEX_PROGRESS/RESULT")
            }
        }
    }

    /// Protected assetIds already verified on the Mac (skip on re-import while still protected).
    public func fetchProtectedSeen() async throws -> Set<String> {
        guard let io else { throw TransferError.notConnected }
        try await io.send(type: .protectedSeenFetch)
        let (type, payload) = try await io.receive(timeoutNanoseconds: ArchieConstants.ioTimeoutNanoseconds)
        switch type {
        case .protectedSeenResult:
            let body = try MessageCodec.decode(ProtectedSeenPayload.self, from: payload)
            return Set(body.assetIds)
        case .fail:
            let fail = try MessageCodec.decode(FailPayload.self, from: payload)
            throw TransferError.rejected(fail.reason)
        default:
            throw TransferError.protocolError("expected PROTECTED_SEEN_RESULT")
        }
    }

    /// Record a protected asset that just verified + settled (Mac appends to `.protected_seen_log`).
    public func markProtectedSeen(assetId: String) async throws {
        guard let io else { throw TransferError.notConnected }
        try await io.sendJSON(type: .protectedSeenMark, value: ProtectedSeenMarkPayload(assetId: assetId))
        let (type, payload) = try await io.receive(timeoutNanoseconds: ArchieConstants.ioTimeoutNanoseconds)
        switch type {
        case .protectedSeenResult:
            _ = try MessageCodec.decode(ProtectedSeenPayload.self, from: payload)
        case .fail:
            let fail = try MessageCodec.decode(FailPayload.self, from: payload)
            throw TransferError.rejected(fail.reason)
        default:
            throw TransferError.protocolError("expected PROTECTED_SEEN_RESULT")
        }
    }

    public func endSession() async throws {
        try await io?.send(type: .sessionEnd)
        disconnect()
    }

    private func startBrowser() {
        let browser = NWBrowser(
            for: .bonjour(type: ArchieConstants.bonjourType, domain: nil),
            using: .tcp
        )
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, let target = results.first else { return }
            self.browser?.cancel()
            self.connect(to: target.endpoint)
        }
        browser.start(queue: queue)
    }

    private func connect(to endpoint: NWEndpoint) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, _, complete in complete(true) },
            queue
        )
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: params)
        self.connection = connection
        let io = ClientIO(connection: connection, queue: queue)
        self.io = io
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.alive = true
                io.start()
                self.readyCont?.resume()
                self.readyCont = nil
            case .failed(let error):
                self.alive = false
                io.noteClosed(TransferError.connectionLost(error.localizedDescription))
                self.readyCont?.resume(throwing: TransferError.connectionLost(error.localizedDescription))
                self.readyCont = nil
            case .cancelled:
                self.alive = false
                io.noteClosed(TransferError.connectionLost("cancelled"))
                self.readyCont?.resume(throwing: TransferError.connectionLost("cancelled"))
                self.readyCont = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}

public enum TransferError: Error, LocalizedError {
    case notConnected
    case connectionLost(String)
    case rejected(String)
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "not connected"
        case .connectionLost(let m): return "connection lost: \(m)"
        case .rejected(let r): return r
        case .protocolError(let m): return m
        }
    }

    public var isConnectionLost: Bool {
        switch self {
        case .notConnected, .connectionLost: return true
        default: return false
        }
    }
}

/// One receive waiter — `finish` is idempotent so timeout vs frame cannot double-resume.
private final class FrameWaiter: @unchecked Sendable {
    private var cont: CheckedContinuation<(FrameType, Data), Error>?
    private var finished = false

    init(_ cont: CheckedContinuation<(FrameType, Data), Error>) {
        self.cont = cont
    }

    func finish(_ result: Result<(FrameType, Data), Error>) {
        guard !finished else { return }
        finished = true
        let c = cont
        cont = nil
        switch result {
        case .success(let value): c?.resume(returning: value)
        case .failure(let error): c?.resume(throwing: error)
        }
    }
}

final class ClientIO: @unchecked Sendable {
    private let connection: NWConnection
    private let parser = FrameParser()
    private let queue: DispatchQueue
    private var pending: [(FrameType, Data)] = []
    private var waiters: [FrameWaiter] = []
    private var closed: Error?

    var isClosed: Bool { queue.sync { closed != nil } }

    /// Call only while already on `queue` (avoids nested `queue.sync` deadlock).
    var isClosedUnlocked: Bool { closed != nil }

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() { receiveLoop() }

    func noteClosed(_ error: Error) {
        queue.async { self.fail(error) }
    }

    func send(type: FrameType, payload: Data = Data()) async throws {
        if let closed = queue.sync(execute: { self.closed }) {
            throw closed
        }
        let frame = FrameCodec.encode(type: type, payload: payload)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: TransferError.connectionLost(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    func sendJSON<T: Encodable>(type: FrameType, value: T) async throws {
        try await send(type: type, payload: MessageCodec.encode(value))
    }

    /// `timeoutNanoseconds` nil = wait until frame or connection failure.
    func receive(timeoutNanoseconds: UInt64?) async throws -> (FrameType, Data) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(FrameType, Data), Error>) in
            self.queue.async {
                if let closed = self.closed {
                    cont.resume(throwing: closed)
                    return
                }
                if !self.pending.isEmpty {
                    cont.resume(returning: self.pending.removeFirst())
                    return
                }
                let waiter = FrameWaiter(cont)
                self.waiters.append(waiter)
                if let timeoutNanoseconds {
                    self.queue.asyncAfter(
                        deadline: .now() + .nanoseconds(Int(timeoutNanoseconds))
                    ) {
                        // Idempotent: no-op if a frame already finished this waiter.
                        self.waiters.removeAll { $0 === waiter }
                        waiter.finish(.failure(
                            TransferError.connectionLost("timed out waiting for reply")
                        ))
                    }
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
                    self.fail(TransferError.connectionLost(error.localizedDescription))
                    return
                }
                if let content {
                    self.parser.append(content)
                    while let frame = self.parser.nextFrame() {
                        if !self.waiters.isEmpty {
                            let waiter = self.waiters.removeFirst()
                            waiter.finish(.success(frame))
                        } else {
                            self.pending.append(frame)
                        }
                    }
                }
                if isComplete {
                    self.fail(TransferError.connectionLost("connection closed"))
                    return
                }
                self.receiveLoop()
            }
        }
    }

    private func fail(_ error: Error) {
        guard closed == nil else { return }
        closed = error
        let w = waiters
        waiters.removeAll()
        w.forEach { $0.finish(.failure(error)) }
    }
}
