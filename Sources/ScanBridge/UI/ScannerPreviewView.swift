#if os(iOS)
@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// Live camera preview for a `CodeScanner`: the capture session on a device,
/// the streamed Mac camera in the simulator.
struct ScannerPreviewView: UIViewRepresentable {
    let scanner: CodeScanner

    func makeUIView(context: Context) -> ScannerPreviewUIView {
        let view = ScannerPreviewUIView()
        view.attach(to: scanner)
        return view
    }

    func updateUIView(_ view: ScannerPreviewUIView, context: Context) {
        view.attach(to: scanner)
    }

    static func dismantleUIView(_ view: ScannerPreviewUIView, coordinator: ()) {
        view.detach()
    }
}

final class ScannerPreviewUIView: UIView {
    private weak var scanner: CodeScanner?
    private var videoPreviewLayer: AVCaptureVideoPreviewLayer?
    private let frameLayer = CALayer()
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        frameLayer.contentsGravity = .resizeAspectFill
        frameLayer.masksToBounds = true
        layer.addSublayer(frameLayer)
        isAccessibilityElement = true
        accessibilityLabel = "Camera preview"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func attach(to scanner: CodeScanner) {
        guard self.scanner !== scanner else { return }
        detach()
        self.scanner = scanner

        switch scanner.previewSource {
        case .captureSession(let session, let device):
            let previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer.videoGravity = .resizeAspectFill
            layer.insertSublayer(previewLayer, below: frameLayer)
            videoPreviewLayer = previewLayer
            if let device {
                keepUpright(previewLayer, device: device)
            }
            setNeedsLayout()

        case .streamedFrames:
            scanner.previewFrameHandler = { [weak self] image in
                self?.display(image)
            }
        }
    }

    func detach() {
        if let scanner, scanner.previewFrameHandler != nil {
            scanner.previewFrameHandler = nil
        }
        scanner = nil
        rotationObservation = nil
        rotationCoordinator = nil
        videoPreviewLayer?.removeFromSuperlayer()
        videoPreviewLayer = nil
        frameLayer.contents = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoPreviewLayer?.frame = bounds
        frameLayer.frame = bounds
        CATransaction.commit()
    }

    private func display(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.contents = image
        CATransaction.commit()
    }

    /// Rotates the preview with the interface so the image is never sideways.
    private func keepUpright(_ previewLayer: AVCaptureVideoPreviewLayer, device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: .new) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.applyRotation(angle)
                }
            }
        }
    }

    private func applyRotation(_ angle: CGFloat) {
        guard let connection = videoPreviewLayer?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }
}
#endif
