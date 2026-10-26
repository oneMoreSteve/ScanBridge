import CoreGraphics
import Foundation
import ImageIO
import Network
@testable import ScanBridge
import ScanBridgeCore
import Testing
import UniformTypeIdentifiers

@Suite(.timeLimit(.minutes(1)))
struct HostConnectionTests {
    @Test func handshakesThenDeliversCodesAndFrames() async throws {
        let host = try await FakeHost.start { request in
            guard case .hello(let hello) = request else { return [] }
            #expect(hello.protocolVersion == BridgeProtocol.version)
            #expect(hello.detectsCodes == true)
            return [
                .hello(Hello(peerName: "Test Camera")),
                .frame(
                    VideoFrame(
                        sequence: 1, width: 4, height: 4,
                        codes: [DetectedCode(payload: "hello", symbology: .qr)],
                        jpegData: try makeJPEG()
                    )
                ),
            ]
        }
        defer { host.stop() }

        let (events, connection) = connect(to: host.port)
        defer { connection.stop() }

        var iterator = events.makeAsyncIterator()
        guard case .connected(let cameraName) = await iterator.next() else {
            Issue.record("Expected connection first")
            return
        }
        #expect(cameraName == "Test Camera")

        guard case .codes(let codes) = await iterator.next() else {
            Issue.record("Expected codes")
            return
        }
        #expect(codes == [DetectedCode(payload: "hello", symbology: .qr)])

        guard case .frame(let frame) = await iterator.next() else {
            Issue.record("Expected a frame")
            return
        }
        #expect(frame.image.width == 4)
    }

    @Test func liteClientAsksHostNotToDetect() async throws {
        let host = try await FakeHost.start { request in
            guard case .hello(let hello) = request else { return [] }
            #expect(hello.detectsCodes == false)
            return [.hello(Hello(peerName: "Camera"))]
        }
        defer { host.stop() }

        let (events, connection) = connect(to: host.port, detectsCodes: false)
        defer { connection.stop() }

        var iterator = events.makeAsyncIterator()
        guard case .connected = await iterator.next() else {
            Issue.record("Expected connection")
            return
        }
    }

    @Test func stopsRetryingWhenHostRejectsVersion() async throws {
        let host = try await FakeHost.start { _ in
            [.failure(BridgeFailure(code: .incompatibleVersion, message: "too old"))]
        }
        defer { host.stop() }

        let (events, connection) = connect(to: host.port)
        defer { connection.stop() }

        var iterator = events.makeAsyncIterator()
        guard case .rejected(let reason) = await iterator.next() else {
            Issue.record("Expected rejection")
            return
        }
        #expect(reason == "too old")
    }

    @Test func reportsDisconnectionWhenHostGoesAway() async throws {
        let host = try await FakeHost.start { _ in [.hello(Hello(peerName: "Camera"))] }
        let (events, connection) = connect(to: host.port)
        defer { connection.stop() }

        var iterator = events.makeAsyncIterator()
        guard case .connected = await iterator.next() else {
            Issue.record("Expected connection")
            return
        }
        host.stop()
        guard case .disconnected = await iterator.next() else {
            Issue.record("Expected disconnection")
            return
        }
    }

    private func connect(to port: UInt16, detectsCodes: Bool = true) -> (AsyncStream<HostConnection.Event>, HostConnection) {
        let (stream, continuation) = AsyncStream.makeStream(of: HostConnection.Event.self)
        let connection = HostConnection(
            endpoint: SimulatorHost(port: port),
            clientName: "tests",
            detectsCodes: detectsCodes
        ) { event in
            continuation.yield(event)
        }
        connection.start()
        return (stream, connection)
    }

    private func makeJPEG() throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())

        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

/// Minimal stand-in for `scanbridge-host`: answers each client message with scripted replies.
private final class FakeHost: @unchecked Sendable {
    typealias Script = @Sendable (BridgeMessage) throws -> [BridgeMessage]

    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeHost")
    private let script: Script
    private var connections: [NWConnection] = []
    let port: UInt16

    private init(listener: NWListener, port: UInt16, script: @escaping Script) {
        self.listener = listener
        self.port = port
        self.script = script
    }

    static func start(script: @escaping Script) async throws -> FakeHost {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "FakeHost.listener")

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: queue)
        }

        let host = FakeHost(listener: listener, port: port, script: script)
        listener.newConnectionHandler = { [weak host] connection in
            host?.accept(connection)
        }
        return host
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        queue.async { [self] in
            connections.append(connection)
            connection.start(queue: queue)
            receive(on: connection, decoder: MessageDecoder())
        }
    }

    private func receive(on connection: NWConnection, decoder: MessageDecoder) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil, !isComplete else { return }
            var decoder = decoder
            do {
                for message in try decoder.decode(data ?? Data()) {
                    for reply in try script(message) {
                        connection.send(content: try MessageEncoder.encode(reply), completion: .idempotent)
                    }
                }
            } catch {
                Issue.record(error)
                return
            }
            receive(on: connection, decoder: decoder)
        }
    }
}
