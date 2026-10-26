import CoreGraphics
import Foundation
import ImageIO
import Network
import os
import ScanBridgeCore

/// TCP client for `scanbridge-host`. Reconnects automatically until stopped.
///
/// All mutable state is confined to `queue`. Events are delivered on `queue`.
final class HostConnection: @unchecked Sendable {
    enum Event: Sendable {
        case connected(cameraName: String)
        case disconnected
        case codes([DetectedCode])
        case frame(DecodedFrame)
        /// The host refused this client; the connection will not retry.
        case rejected(reason: String)
    }

    /// A decoded preview image. `CGImage` is immutable, so sharing it across threads is safe.
    struct DecodedFrame: @unchecked Sendable {
        let image: CGImage
    }

    private let endpoint: SimulatorHost
    private let clientName: String
    private let detectsCodes: Bool
    private let eventHandler: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "ScanBridge.HostConnection", qos: .userInitiated)

    private var connection: NWConnection?
    private var decoder = MessageDecoder()
    private var isStopped = true
    private var isHandshakeComplete = false
    private var retryDelay = HostConnection.initialRetryDelay
    private var retryWorkItem: DispatchWorkItem?

    private static let initialRetryDelay: TimeInterval = 0.5
    private static let maximumRetryDelay: TimeInterval = 3

    /// - Parameter detectsCodes: `false` asks the host to only stream the camera (lite mode).
    init(
        endpoint: SimulatorHost,
        clientName: String,
        detectsCodes: Bool = true,
        eventHandler: @escaping @Sendable (Event) -> Void
    ) {
        self.endpoint = endpoint
        self.clientName = clientName
        self.detectsCodes = detectsCodes
        self.eventHandler = eventHandler
    }

    deinit {
        retryWorkItem?.cancel()
        connection?.cancel()
    }

    func start() {
        queue.async { [self] in
            guard isStopped else { return }
            isStopped = false
            retryDelay = Self.initialRetryDelay
            connect()
        }
    }

    func stop() {
        queue.async { [self] in
            isStopped = true
            tearDown(notify: false)
        }
    }

    // MARK: - Connection lifecycle

    private func connect() {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            eventHandler(.rejected(reason: "Invalid port \(endpoint.port)."))
            isStopped = true
            return
        }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: port,
            using: NWParameters(tls: nil, tcp: tcp)
        )
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, connection === self.connection else { return }
            self.handle(state, of: connection)
        }

        decoder = MessageDecoder()
        isHandshakeComplete = false
        self.connection = connection
        connection.start(queue: queue)
    }

    private func handle(_ state: NWConnection.State, of connection: NWConnection) {
        switch state {
        case .ready:
            sendHello(on: connection)
            receive(on: connection)
        case .waiting(let error), .failed(let error):
            // `.waiting` is what a refused connection looks like (host not running yet).
            Logger.simulatorHost.debug("Connection to \(self.endpoint.description, privacy: .public) unavailable: \(error.localizedDescription, privacy: .public)")
            scheduleReconnect()
        default:
            break
        }
    }

    private func sendHello(on connection: NWConnection) {
        do {
            let data = try MessageEncoder.encode(.hello(Hello(peerName: clientName, detectsCodes: detectsCodes)))
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, error != nil, connection === self.connection else { return }
                self.scheduleReconnect()
            })
        } catch {
            Logger.simulatorHost.fault("Cannot encode hello: \(error, privacy: .public)")
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, connection === self.connection else { return }

            if let data, !data.isEmpty {
                do {
                    for message in try self.decoder.decode(data) {
                        self.handle(message)
                        guard connection === self.connection else { return }
                    }
                } catch {
                    Logger.simulatorHost.error("Protocol error: \(String(describing: error), privacy: .public)")
                    self.scheduleReconnect()
                    return
                }
            }

            if isComplete || error != nil {
                self.scheduleReconnect()
            } else {
                self.receive(on: connection)
            }
        }
    }

    private func handle(_ message: BridgeMessage) {
        switch message {
        case .hello(let hello):
            guard hello.protocolVersion == BridgeProtocol.version else {
                reject(reason: "host speaks protocol v\(hello.protocolVersion), app speaks v\(BridgeProtocol.version)")
                return
            }
            isHandshakeComplete = true
            retryDelay = Self.initialRetryDelay
            eventHandler(.connected(cameraName: hello.peerName))

        case .frame(let frame):
            guard isHandshakeComplete else { return }
            if !frame.codes.isEmpty {
                eventHandler(.codes(frame.codes))
            }
            if let image = Self.decodeJPEG(frame.jpegData) {
                eventHandler(.frame(DecodedFrame(image: image)))
            }

        case .failure(let failure):
            reject(reason: failure.message)
        }
    }

    private func reject(reason: String) {
        isStopped = true
        tearDown(notify: false)
        eventHandler(.rejected(reason: reason))
    }

    private func scheduleReconnect() {
        tearDown(notify: true)
        guard !isStopped else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped, self.connection == nil else { return }
            self.connect()
        }
        retryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + retryDelay, execute: workItem)
        retryDelay = min(retryDelay * 2, Self.maximumRetryDelay)
    }

    private func tearDown(notify: Bool) {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil

        if isHandshakeComplete {
            isHandshakeComplete = false
            if notify { eventHandler(.disconnected) }
        }
    }

    /// Decodes eagerly so the main thread only has to composite the image.
    private static func decodeJPEG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }
}
