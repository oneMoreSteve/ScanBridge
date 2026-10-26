#if os(iOS)
@preconcurrency import AVFoundation
import os

/// Scans with the device camera through `AVCaptureMetadataOutput`, which decodes in hardware.
@MainActor
final class CameraBackend: NSObject, ScannerBackend {
    var eventHandler: (@MainActor (BackendEvent) -> Void)?

    private let controller = CaptureSessionController()
    // Only mutated on the main actor; `nonisolated(unsafe)` so `deinit` can unregister them.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    var previewSource: PreviewSource {
        .captureSession(controller.session, device: controller.device)
    }

    override init() {
        super.init()
        observeSessionNotifications()
    }

    func start(symbologies: Set<Symbology>) async throws(ScannerError) {
        try await Self.requestAuthorization()
        try await controller.configure(symbologies: symbologies, delegate: self)
        await controller.startRunning()
        eventHandler?(.stateChanged(.running(.device)))
    }

    func stop() {
        controller.stopRunning()
    }

    private static func requestAuthorization() async throws(ScannerError) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw .cameraAccessDenied
            }
        default:
            throw .cameraAccessDenied
        }
    }

    private func observeSessionNotifications() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: controller.session,
                queue: .main
            ) { [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
                MainActor.assumeIsolated {
                    self?.handleRuntimeError(error)
                }
            }
        )
    }

    private func handleRuntimeError(_ error: AVError?) {
        Logger.scanner.error("Capture session runtime error: \(String(describing: error), privacy: .public)")
        if error?.code == .mediaServicesWereReset {
            // Documented recovery path: simply restart the session.
            Task { await controller.startRunning() }
        } else {
            eventHandler?(.stateChanged(.failed(.captureFailed(reason: error?.localizedDescription ?? "Unknown error"))))
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

extension CameraBackend: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let sightings = metadataObjects.compactMap { object -> CodeSighting? in
            guard let code = object as? AVMetadataMachineReadableCodeObject,
                  let payload = code.stringValue,
                  let symbology = Symbology(metadataObjectType: code.type)
            else { return nil }
            return CodeSighting(payload: payload, symbology: symbology)
        }
        guard !sightings.isEmpty else { return }

        // The delegate queue is `.main`, see `CaptureSessionController.configure`.
        MainActor.assumeIsolated {
            eventHandler?(.codesDetected(sightings))
        }
    }
}

/// Owns the `AVCaptureSession`. Every session mutation happens on `queue`, as
/// `startRunning()` blocks and Apple requires it to be called off the main thread.
private final class CaptureSessionController: @unchecked Sendable {
    let session = AVCaptureSession()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let queue = DispatchQueue(label: "ScanBridge.CaptureSession")

    /// Written once on `queue` during the first configuration; read on the main actor afterwards.
    private(set) var device: AVCaptureDevice?
    private var isConfigured = false

    /// Smallest code width we want to read, in millimetres. Drives the automatic zoom.
    private let minimumCodeSize: Float = 20

    func configure(
        symbologies: Set<Symbology>,
        delegate: any AVCaptureMetadataOutputObjectsDelegate & Sendable
    ) async throws(ScannerError) {
        let result: Result<Void, ScannerError> = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Result { () throws(ScannerError) in
                    try self.configureOnQueue(symbologies: symbologies, delegate: delegate)
                })
            }
        }
        try result.get()
    }

    func startRunning() async {
        await withCheckedContinuation { continuation in
            queue.async { [session] in
                if !session.isRunning { session.startRunning() }
                continuation.resume()
            }
        }
    }

    func stopRunning() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureOnQueue(
        symbologies: Set<Symbology>,
        delegate: any AVCaptureMetadataOutputObjectsDelegate
    ) throws(ScannerError) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if !isConfigured {
            try addInputAndOutput()
            metadataOutput.setMetadataObjectsDelegate(delegate, queue: .main)
            isConfigured = true
        }

        // Only available once the output is attached to a session with an input.
        let available = Set(metadataOutput.availableMetadataObjectTypes)
        metadataOutput.metadataObjectTypes = symbologies
            .flatMap(\.metadataObjectTypes)
            .filter(available.contains)
    }

    private func addInputAndOutput() throws(ScannerError) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
        else {
            throw .cameraUnavailable
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw .configurationFailed(reason: error.localizedDescription)
        }
        guard session.canAddInput(input) else {
            throw .configurationFailed(reason: "The camera input cannot be added to the session.")
        }
        session.addInput(input)

        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        }

        guard session.canAddOutput(metadataOutput) else {
            throw .configurationFailed(reason: "The metadata output cannot be added to the session.")
        }
        session.addOutput(metadataOutput)

        configureFocus(of: device)
        self.device = device
    }

    /// Tunes focus for close-range scanning and zooms in when the lens cannot focus close enough
    /// to read small codes (approach from Apple's AVCamBarcode sample).
    private func configureFocus(of device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
        } catch {
            Logger.scanner.warning("Cannot lock camera for configuration: \(error.localizedDescription, privacy: .public)")
            return
        }
        defer { device.unlockForConfiguration() }

        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = .near
        }

        let minimumFocusDistance = Float(device.minimumFocusDistance)
        guard minimumFocusDistance > 0 else { return }

        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard dimensions.width > 0 else { return }
        let fillRatio = Float(dimensions.height) / Float(dimensions.width)
        let halfFieldOfView = device.activeFormat.videoFieldOfView / 2 * .pi / 180
        let minimumSubjectDistance = (minimumCodeSize / fillRatio) / tan(halfFieldOfView)

        if minimumSubjectDistance < minimumFocusDistance {
            let zoom = CGFloat(minimumFocusDistance / minimumSubjectDistance)
            device.videoZoomFactor = min(zoom, device.activeFormat.videoMaxZoomFactor)
        }
    }
}
#endif
