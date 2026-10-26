#if os(iOS)
import AVFoundation
import CoreGraphics

/// Raw sighting reported by a backend, before symbology and duplicate filtering.
struct CodeSighting: Sendable, Equatable {
    let payload: String
    let symbology: Symbology
}

enum BackendEvent {
    case stateChanged(ScannerState)
    case codesDetected([CodeSighting])
    /// Simulator only: a preview frame streamed from the Mac.
    case previewFrame(CGImage)
}

/// What the preview view should render.
enum PreviewSource {
    case captureSession(AVCaptureSession, device: AVCaptureDevice?)
    case streamedFrames
}

/// A source of camera frames and decoded codes.
///
/// `start` and `stop` may be called repeatedly; implementations must be idempotent.
@MainActor
protocol ScannerBackend: AnyObject {
    var eventHandler: (@MainActor (BackendEvent) -> Void)? { get set }
    var previewSource: PreviewSource { get }

    /// Returns once the backend is running, or waiting for its source (simulator).
    /// An empty `symbologies` set means preview only: nothing is decoded.
    func start(symbologies: Set<Symbology>) async throws(ScannerError)
    func stop()
}
#endif
