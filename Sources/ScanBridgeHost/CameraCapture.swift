@preconcurrency import AVFoundation
import Foundation

/// Captures frames from a Mac camera. Capture only runs between `start()` and `stop()`,
/// so the camera LED is off while no simulator is connected.
final class CameraCapture: NSObject, @unchecked Sendable {
    // `session` is only touched on `sessionQueue`; `frameHandler` is set once before the first start.
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "ScanBridgeHost.CameraCapture.session")
    private let outputQueue = DispatchQueue(label: "ScanBridgeHost.CameraCapture.output", qos: .userInitiated)

    let device: AVCaptureDevice

    /// Called on a private serial queue for every captured frame.
    var frameHandler: ((CVPixelBuffer) -> Void)?

    struct ConfigurationError: Error, CustomStringConvertible {
        let description: String
    }

    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    /// Picks the camera whose name contains `name`, or the system default camera.
    static func device(matching name: String?) -> AVCaptureDevice? {
        guard let name else {
            return AVCaptureDevice.default(for: .video) ?? availableDevices().first
        }
        return availableDevices().first { $0.localizedName.localizedCaseInsensitiveContains(name) }
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .video)
        default:
            false
        }
    }

    init(device: AVCaptureDevice) throws(ConfigurationError) {
        self.device = device
        super.init()

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw ConfigurationError(description: "Cannot open \(device.localizedName): \(error.localizedDescription)")
        }
        guard session.canAddInput(input) else {
            throw ConfigurationError(description: "Cannot use \(device.localizedName) as a capture input.")
        }
        session.addInput(input)

        // 720p is plenty for decoding and keeps JPEG encoding cheap.
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else {
            throw ConfigurationError(description: "Cannot attach a video output to \(device.localizedName).")
        }
        session.addOutput(output)
    }

    func start() {
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }
}

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameHandler?(pixelBuffer)
    }
}
