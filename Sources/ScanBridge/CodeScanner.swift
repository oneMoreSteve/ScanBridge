#if os(iOS)
import CoreGraphics
import Foundation
import Observation
import os

/// Scans barcodes and QR codes, or only shows the camera with `ScannerConfiguration.lite()`.
///
/// On a device it uses the built-in camera. In the iOS Simulator, which has no camera, it receives
/// the Mac's camera from `scanbridge-host` (run `swift run scanbridge-host` in the package folder).
///
/// ```swift
/// let scanner = CodeScanner(configuration: .init(symbologies: [.qr, .ean13]))
/// await scanner.start()
/// for await code in scanner.codes() {
///     print(code.payload)
/// }
/// ```
@MainActor
@Observable
public final class CodeScanner {
    public let configuration: ScannerConfiguration

    public private(set) var state: ScannerState = .idle

    /// The most recent code reported (after duplicate suppression).
    public private(set) var lastScannedCode: ScannedCode?

    /// While paused the camera keeps running but no code is reported,
    /// e.g. while the app shows the result of the previous scan.
    public var isPaused = false

    @ObservationIgnored private let backend: any ScannerBackend
    @ObservationIgnored private var duplicateFilter: DuplicateFilter
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<ScannedCode>.Continuation] = [:]
    /// Incremented by `stop()` so an in-flight `start()` can tell it was cancelled.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored var previewFrameHandler: (@MainActor (CGImage) -> Void)?

    public convenience init(configuration: ScannerConfiguration = ScannerConfiguration()) {
        #if targetEnvironment(simulator)
        let backend = SimulatorHostBackend(endpoint: configuration.simulatorHost)
        #else
        let backend = CameraBackend()
        #endif
        self.init(configuration: configuration, backend: backend)
    }

    init(configuration: ScannerConfiguration, backend: any ScannerBackend) {
        self.configuration = configuration
        self.backend = backend
        self.duplicateFilter = DuplicateFilter(interval: configuration.duplicateSuppressionInterval)
        backend.eventHandler = { [weak self] event in
            self?.handle(event)
        }
    }

    var previewSource: PreviewSource {
        backend.previewSource
    }

    /// Requests camera access if needed and starts scanning. Safe to call when already running.
    ///
    /// Errors are reported through `state` (`.failed`), never thrown.
    public func start() async {
        switch state {
        case .starting, .running, .waitingForHost:
            return
        case .idle, .failed:
            break
        }

        generation += 1
        let startGeneration = generation
        state = .starting

        do {
            try await backend.start(symbologies: configuration.activeSymbologies)
        } catch {
            guard generation == startGeneration else { return }
            Logger.scanner.error("Cannot start scanner: \(error.localizedDescription, privacy: .public)")
            state = .failed(error)
            return
        }

        // `stop()` was called while we were waiting for authorization or configuration,
        // and no newer `start()` is using the backend.
        if generation != startGeneration, state == .idle {
            backend.stop()
        }
    }

    /// Stops the camera. Subscribers to `codes()` stay subscribed and resume receiving codes after `start()`.
    public func stop() {
        generation += 1
        backend.stop()
        state = .idle
    }

    /// A stream of scanned codes. Each call returns an independent stream; the stream
    /// finishes when the consuming task is cancelled.
    public func codes() -> AsyncStream<ScannedCode> {
        let (stream, continuation) = AsyncStream.makeStream(of: ScannedCode.self, bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.subscribers[id] = nil
            }
        }
        return stream
    }

    /// Forgets previously seen codes, so the code currently in view is reported again.
    public func resetDuplicateSuppression() {
        duplicateFilter.reset()
    }

    // MARK: - Backend events

    private func handle(_ event: BackendEvent) {
        switch event {
        case .stateChanged(let newState):
            // Ignore late events from a backend that was stopped.
            guard state != .idle else { return }
            state = newState

        case .codesDetected(let sightings):
            guard state.isRunning, !isPaused else { return }
            report(sightings)

        case .previewFrame(let image):
            previewFrameHandler?(image)
        }
    }

    private func report(_ sightings: [CodeSighting]) {
        let now = ContinuousClock.now
        for sighting in sightings where configuration.activeSymbologies.contains(sighting.symbology) {
            guard duplicateFilter.shouldReport(payload: sighting.payload, symbology: sighting.symbology, at: now) else {
                continue
            }
            let code = ScannedCode(payload: sighting.payload, symbology: sighting.symbology)
            lastScannedCode = code
            for continuation in subscribers.values {
                continuation.yield(code)
            }
        }
    }
}
#endif
