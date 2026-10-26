#if os(iOS)
import SwiftUI

/// Camera preview that starts the scanner when it appears and stops it when it disappears.
///
/// ```swift
/// @State private var scanner = CodeScanner(configuration: .init(symbologies: [.qr]))
///
/// var body: some View {
///     CodeScannerView(scanner: scanner) { code in
///         print(code.payload)
///     }
/// }
/// ```
///
/// For the camera stream alone, without code detection:
/// `CodeScannerView(scanner: CodeScanner(configuration: .lite()))`.
public struct CodeScannerView: View {
    private let scanner: CodeScanner
    private let showsStatus: Bool
    private let onScan: (@MainActor (ScannedCode) -> Void)?

    /// - Parameters:
    ///   - scanner: The scanner to display and drive.
    ///   - showsStatus: Overlays a message when the camera is unavailable or, in the simulator,
    ///     when `scanbridge-host` is not running.
    ///   - onScan: Called on the main actor for every scanned code.
    public init(
        scanner: CodeScanner,
        showsStatus: Bool = true,
        onScan: (@MainActor (ScannedCode) -> Void)? = nil
    ) {
        self.scanner = scanner
        self.showsStatus = showsStatus
        self.onScan = onScan
    }

    public var body: some View {
        ScannerPreviewView(scanner: scanner)
            .ignoresSafeArea()
            .overlay {
                if showsStatus {
                    ScannerStatusOverlay(state: scanner.state)
                }
            }
            .task(id: ObjectIdentifier(scanner)) {
                // Subscribe before starting so no code is missed.
                let codes = scanner.codes()
                await scanner.start()
                guard let onScan else { return }
                for await code in codes {
                    onScan(code)
                }
            }
            .onDisappear {
                scanner.stop()
            }
    }
}

private struct ScannerStatusOverlay: View {
    let state: ScannerState

    var body: some View {
        switch state {
        case .idle, .starting, .running:
            EmptyView()
        case .waitingForHost(let endpoint):
            message(
                title: "Waiting for the Mac camera",
                systemImage: "web.camera",
                detail: "The iOS Simulator has no camera. In the ScanBridge package folder, run:\n\nswift run scanbridge-host\n\nExpected at \(endpoint)."
            )
        case .failed(let error):
            message(
                title: "Camera unavailable",
                systemImage: "exclamationmark.triangle",
                detail: error.localizedDescription
            )
        }
    }

    private func message(title: String, systemImage: String, detail: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        }
        .foregroundStyle(.white)
        .background(.black.opacity(0.7))
    }
}
#endif
