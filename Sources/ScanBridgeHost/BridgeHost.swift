import CoreMedia
import CoreVideo
import Foundation
import os
import ScanBridgeCore

/// Wires the camera, the barcode detector, the JPEG encoder and the server together.
final class BridgeHost: @unchecked Sendable {
    private let capture: CameraCapture
    private let server: BridgeServer
    private let detector = BarcodeDetector()
    private let encoder: FrameEncoder
    private let minimumFrameInterval: TimeInterval
    /// Decoding runs only while a connected client wants codes, and never with `--lite`.
    private let isDetectionEnabled = OSAllocatedUnfairLock(initialState: false)

    // Only touched from the capture output queue.
    private var sequence: UInt64 = 0
    private var lastFrameTime: TimeInterval = 0
    private var lastLoggedCodes: Set<DetectedCode> = []

    init(capture: CameraCapture, options: HostOptions) {
        self.capture = capture
        self.server = BridgeServer(port: options.port, cameraName: capture.device.localizedName)
        self.encoder = FrameEncoder(quality: options.jpegQuality, mirrors: options.mirrorsPreview)
        self.minimumFrameInterval = 1 / options.framesPerSecond

        capture.frameHandler = { [unowned self] pixelBuffer in
            process(pixelBuffer)
        }
        server.onDetectionRequestChange = { [isDetectionEnabled, lite = options.lite] requested in
            isDetectionEnabled.withLock { $0 = requested && !lite }
        }
        server.onReadyClientCountChange = { [capture] count in
            if count > 0 {
                capture.start()
            } else {
                capture.stop()
                Console.info("No client connected, camera stopped.")
            }
        }
    }

    func start(onFatalError: @escaping @Sendable (Error) -> Void) throws {
        server.onFatalError = onFatalError
        try server.start()
    }

    func stop() {
        server.stop()
        capture.stop()
    }

    private func process(_ pixelBuffer: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrameTime >= minimumFrameInterval else { return }
        lastFrameTime = now

        // Decode on the original (non mirrored) buffer: mirrored 1D barcodes would read backwards.
        let codes = isDetectionEnabled.withLock { $0 } ? detector.detect(in: pixelBuffer) : []
        logIfChanged(codes)

        guard let encoded = encoder.encode(pixelBuffer) else { return }
        sequence &+= 1
        server.broadcast(
            .frame(
                VideoFrame(
                    sequence: sequence,
                    width: encoded.width,
                    height: encoded.height,
                    codes: codes,
                    jpegData: encoded.jpegData
                )
            )
        )
    }

    private func logIfChanged(_ codes: [DetectedCode]) {
        let current = Set(codes)
        for code in current.subtracting(lastLoggedCodes) {
            Console.info("Detected [\(code.symbology)] \(code.payload)")
        }
        lastLoggedCodes = current
    }
}
