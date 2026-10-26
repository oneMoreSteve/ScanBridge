import Foundation
import Network
import ScanBridgeCore

/// Loopback TCP server the simulator apps connect to.
///
/// All mutable state is confined to `queue`.
final class BridgeServer: @unchecked Sendable {
    /// Confined to the server queue, like the rest of the server state.
    private final class Client: @unchecked Sendable {
        let connection: NWConnection
        var decoder = MessageDecoder()
        var name = "unknown client"
        var detectsCodes = true
        var isReady = false
        var isSending = false

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private let queue = DispatchQueue(label: "ScanBridgeHost.BridgeServer")
    private let port: UInt16
    private let cameraName: String
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var readyClientCount = 0
    private var isDetectionRequested = false

    /// Called on the server queue when the number of clients that completed the handshake changes.
    var onReadyClientCountChange: (@Sendable (Int) -> Void)?
    /// Called on the server queue when whether any ready client wants codes decoded changes.
    var onDetectionRequestChange: (@Sendable (Bool) -> Void)?
    /// Called on the server queue when the listener cannot run (port in use…).
    var onFatalError: (@Sendable (Error) -> Void)?

    init(port: UInt16, cameraName: String) {
        self.port = port
        self.cameraName = cameraName
    }

    struct InvalidPortError: Error, CustomStringConvertible {
        let port: UInt16
        var description: String { "Invalid port \(port)." }
    }

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw InvalidPortError(port: port)
        }
        let parameters = NWParameters.tcp
        // Loopback only: the stream is never exposed to the network.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.allowLocalEndpointReuse = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }

        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self, port] state in
            switch state {
            case .ready:
                Console.info("Listening on 127.0.0.1:\(port). Waiting for the iOS Simulator…")
            case .failed(let error):
                self?.onFatalError?(error)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for client in clients.values {
                client.connection.cancel()
            }
            clients.removeAll()
            updateReadyClientCount()
        }
    }

    /// Sends `message` to every connected client. A client still busy sending the previous
    /// frame skips this one, so a slow client never builds up latency or memory.
    func broadcast(_ message: BridgeMessage) {
        let data: Data
        do {
            data = try MessageEncoder.encode(message)
        } catch {
            Console.error("Cannot encode message: \(error)")
            return
        }

        queue.async { [self] in
            for client in clients.values where client.isReady && !client.isSending {
                client.isSending = true
                client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] error in
                    guard let self, let client else { return }
                    client.isSending = false
                    if let error {
                        self.disconnect(client, reason: error.localizedDescription)
                    }
                })
            }
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let client = Client(connection: connection)
        clients[ObjectIdentifier(connection)] = client

        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .ready:
                self.receive(from: client)
            case .failed(let error), .waiting(let error):
                self.disconnect(client, reason: error.localizedDescription)
            case .cancelled:
                self.disconnect(client, reason: nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(from client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak client] data, _, isComplete, error in
            guard let self, let client else { return }

            if let data, !data.isEmpty {
                do {
                    for message in try client.decoder.decode(data) {
                        self.handle(message, from: client)
                    }
                } catch {
                    self.disconnect(client, reason: "\(error)")
                    return
                }
            }

            if let error {
                self.disconnect(client, reason: error.localizedDescription)
            } else if isComplete {
                self.disconnect(client, reason: nil)
            } else {
                self.receive(from: client)
            }
        }
    }

    private func handle(_ message: BridgeMessage, from client: Client) {
        guard case .hello(let hello) = message, !client.isReady else {
            // Clients only ever send a single hello.
            return
        }

        guard hello.protocolVersion == BridgeProtocol.version else {
            let failure = BridgeFailure(
                code: .incompatibleVersion,
                message: "Host speaks protocol v\(BridgeProtocol.version), client speaks v\(hello.protocolVersion). Update ScanBridge on both sides."
            )
            Console.error("Rejected \(hello.peerName): \(failure.message)")
            let data = try? MessageEncoder.encode(.failure(failure))
            client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] _ in
                guard let self, let client else { return }
                self.disconnect(client, reason: nil)
            })
            return
        }

        client.name = hello.peerName
        client.detectsCodes = hello.detectsCodes ?? true
        guard let data = try? MessageEncoder.encode(.hello(Hello(peerName: cameraName))) else { return }
        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] error in
            guard let self, let client else { return }
            if let error {
                self.disconnect(client, reason: error.localizedDescription)
                return
            }
            client.isReady = true
            Console.info("Connected: \(client.name)" + (client.detectsCodes ? "" : " (lite: stream only)"))
            self.updateReadyClientCount()
        })
    }

    private func disconnect(_ client: Client, reason: String?) {
        guard clients.removeValue(forKey: ObjectIdentifier(client.connection)) != nil else { return }
        client.connection.cancel()
        if client.isReady {
            Console.info("Disconnected: \(client.name)" + (reason.map { " (\($0))" } ?? ""))
        }
        updateReadyClientCount()
    }

    private func updateReadyClientCount() {
        let readyClients = clients.values.filter(\.isReady)

        let detectionRequested = readyClients.contains(where: \.detectsCodes)
        if detectionRequested != isDetectionRequested {
            isDetectionRequested = detectionRequested
            onDetectionRequestChange?(detectionRequested)
        }

        guard readyClients.count != readyClientCount else { return }
        readyClientCount = readyClients.count
        onReadyClientCountChange?(readyClients.count)
    }
}
