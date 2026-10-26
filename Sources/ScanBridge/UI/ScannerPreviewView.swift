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
    /// `AVCaptureDevice.RotationCoordinator` on iOS 17+. Typed loosely because stored
    /// properties cannot have a type newer than the deployment target.
    private var rotationCoordinator: NSObject?
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
            if #available(iOS 17, *), let device {
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

        // iOS 16: the rotation coordinator does not exist; follow the interface orientation,
        // which changes are always followed by a layout pass.
        if #unavailable(iOS 17) {
            matchInterfaceOrientation()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if #unavailable(iOS 17) {
            matchInterfaceOrientation()
        }
    }

    private func matchInterfaceOrientation() {
        guard let connection = videoPreviewLayer?.connection,
              connection.isVideoOrientationSupported,
              let interfaceOrientation = window?.windowScene?.interfaceOrientation,
              let videoOrientation = AVCaptureVideoOrientation(interfaceOrientation)
        else { return }
        connection.videoOrientation = videoOrientation
    }

    private func display(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.contents = image
        CATransaction.commit()
    }

    /// Rotates the preview with the interface so the image is never sideways.
    @available(iOS 17, *)
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

    @available(iOS 17, *)
    private func applyRotation(_ angle: CGFloat) {
        guard let connection = videoPreviewLayer?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }
}
private extension AVCaptureVideoOrientation {
    init?(_ interfaceOrientation: UIInterfaceOrientation) {
        switch interfaceOrientation {
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        default: return nil
        }
    }
}
#endif
