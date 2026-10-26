#if os(iOS)
import Foundation
import os
import ScanBridgeCore

/// Receives the Mac camera stream from `scanbridge-host`. Used in the iOS Simulator, which has no camera.
@MainActor
final class SimulatorHostBackend: ScannerBackend {
    var eventHandler: (@MainActor (BackendEvent) -> Void)?
    let previewSource = PreviewSource.streamedFrames

    private let endpoint: SimulatorHost
    private var connection: HostConnection?
    private var symbologies: Set<Symbology> = []

    /// Latest frame not yet shown. Frames are coalesced so a busy main thread
    /// drops stale frames instead of queueing them.
    private let pendingFrame = OSAllocatedUnfairLock<HostConnection.DecodedFrame?>(initialState: nil)

    init(endpoint: SimulatorHost) {
        self.endpoint = endpoint
    }

    func start(symbologies: Set<Symbology>) async throws(ScannerError) {
        self.symbologies = symbologies
        guard connection == nil else { return }

        let connection = HostConnection(
            endpoint: endpoint,
            clientName: Self.clientName,
            detectsCodes: !symbologies.isEmpty
        ) { [weak self, pendingFrame] event in
            if case .frame(let frame) = event {
                let wasEmpty = pendingFrame.withLock { pending in
                    defer { pending = frame }
                    return pending == nil
                }
                guard wasEmpty else { return }
            }
            // `DispatchQueue.main` keeps events in order, unlike unstructured tasks.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handle(event)
                }
            }
        }
        self.connection = connection
        eventHandler?(.stateChanged(.waitingForHost(endpoint: endpoint.description)))
        connection.start()
    }

    func stop() {
        connection?.stop()
        connection = nil
        pendingFrame.withLock { $0 = nil }
    }

    private func handle(_ event: HostConnection.Event) {
        // Events can still arrive for a connection stopped meanwhile.
        guard connection != nil else { return }

        switch event {
        case .connected(let cameraName):
            Logger.simulatorHost.info("Connected to scanbridge-host, camera: \(cameraName, privacy: .public)")
            eventHandler?(.stateChanged(.running(.macHost(cameraName: cameraName))))

        case .disconnected:
            eventHandler?(.stateChanged(.waitingForHost(endpoint: endpoint.description)))

        case .codes(let codes):
            let sightings = codes.compactMap { code -> CodeSighting? in
                guard let symbology = code.knownSymbology, symbologies.contains(symbology) else { return nil }
                return CodeSighting(payload: code.payload, symbology: symbology)
            }
            if !sightings.isEmpty {
                eventHandler?(.codesDetected(sightings))
            }

        case .frame:
            if let frame = pendingFrame.withLock({ $0.take() }) {
                eventHandler?(.previewFrame(frame.image))
            }

        case .rejected(let reason):
            connection = nil
            eventHandler?(.stateChanged(.failed(.incompatibleHost(reason: reason))))
        }
    }

    private static var clientName: String {
        let environment = ProcessInfo.processInfo.environment
        let device = environment["SIMULATOR_DEVICE_NAME"] ?? "iOS Simulator"
        let app = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        return "\(app) on \(device)"
    }
}
#endif
