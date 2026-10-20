import ArchieCore
import Foundation
import Network
import Security

final class ReceiverServer {
    private let archiveRoot: URL
    private let pin: String
    private let identity: SecIdentity
    private let manifest: ManifestStore
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "archie.receiver")

    init(archiveRoot: URL, pin: String, identity: SecIdentity, manifest: ManifestStore) {
        self.archiveRoot = archiveRoot
        self.pin = pin
        self.identity = identity
        self.manifest = manifest
    }

    func start() throws {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        let secIdentity = sec_identity_create(identity)!
        sec_protocol_options_set_local_identity(sec, secIdentity)
        sec_protocol_options_set_peer_authentication_required(sec, false)

        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.includePeerToPeer = true

        let listener = try NWListener(using: params)
        listener.service = NWListener.Service(name: "Archie", type: ArchieConstants.bonjourType)
        self.listener = listener

        listener.stateUpdateHandler = { state in
            fputs("listener \(state)\n", stderr)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        let io = ConnectionIO(connection: connection, queue: queue)
        let handler = SessionHandler(
            io: io,
            archiveRoot: archiveRoot,
            pin: pin,
            manifest: manifest
        )
        connection.stateUpdateHandler = { state in
            fputs("conn \(state)\n", stderr)
            guard case .ready = state else { return }
            io.start()
            Task {
                await handler.run()
                connection.cancel()
            }
        }
        connection.start(queue: queue)
    }
}
