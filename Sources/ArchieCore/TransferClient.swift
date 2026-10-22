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

    public init(pin: String, deviceName: String) {
        self.pin = pin
        self.deviceName = deviceName
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
        let (type, payload) = try await io.receive()
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
        let (type, payload) = try await io.receive()
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
        let (type, payload) = try await io.receive()
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
            let (type, payload) = try await io.receive()
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

    /// Favourite assetIds already verified on the Mac (skip on re-import).
    public func fetchFavouritesSeen() async throws -> Set<String> {
        guard let io else { throw TransferError.notConnected }
        try await io.send(type: .favouritesSeenFetch)
        let (type, payload) = try await io.receive()
        switch type {
        case .favouritesSeenResult:
            let body = try MessageCodec.decode(FavouritesSeenPayload.self, from: payload)
            return Set(body.assetIds)
        case .fail:
            let fail = try MessageCodec.decode(FailPayload.self, from: payload)
            throw TransferError.rejected(fail.reason)
        default:
            throw TransferError.protocolError("expected FAVOURITES_SEEN_RESULT")
        }
    }

    /// Record a favourite that just verified + settled (Mac appends to `.favourites_seen_log`).
    public func markFavouriteSeen(assetId: String) async throws {
        guard let io else { throw TransferError.notConnected }
        try await io.sendJSON(type: .favouriteSeenMark, value: FavouriteSeenPayload(assetId: assetId))
        let (type, payload) = try await io.receive()
        switch type {
        case .favouritesSeenResult:
            _ = try MessageCodec.decode(FavouritesSeenPayload.self, from: payload)
        case .fail:
            let fail = try MessageCodec.decode(FailPayload.self, from: payload)
            throw TransferError.rejected(fail.reason)
        default:
            throw TransferError.protocolError("expected FAVOURITES_SEEN_RESULT")
        }
    }

    public func endSession() async throws {
        try await io?.send(type: .sessionEnd)
        connection?.cancel()
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
                io.start()
                self.readyCont?.resume()
                self.readyCont = nil
            case .failed(let error):
                self.readyCont?.resume(throwing: error)
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
    case rejected(String)
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "not connected"
        case .rejected(let r): return r
        case .protocolError(let m): return m
        }
    }
}

final class ClientIO: @unchecked Sendable {
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

    func start() { receiveLoop() }

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
                    self.fail(TransferError.protocolError("connection closed"))
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
