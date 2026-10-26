import Foundation
import ScanBridgeCore

public typealias Symbology = ScanBridgeCore.Symbology

/// A code read by the scanner.
public struct ScannedCode: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// The decoded string content of the code.
    public let payload: String
    public let symbology: Symbology
    public let scannedAt: Date

    public init(id: UUID = UUID(), payload: String, symbology: Symbology, scannedAt: Date = .now) {
        self.id = id
        self.payload = payload
        self.symbology = symbology
        self.scannedAt = scannedAt
    }
}

/// Where the frames come from.
public enum CameraSource: Sendable, Equatable {
    /// The device's own camera (iPhone, iPad, or a Mac running the app natively).
    case device
    /// A Mac camera streamed by `scanbridge-host` into the iOS Simulator.
    case macHost(cameraName: String)
}

public enum ScannerState: Sendable, Equatable {
    case idle
    case starting
    case running(CameraSource)
    /// Simulator only: `scanbridge-host` is not reachable yet. The scanner keeps retrying.
    case waitingForHost(endpoint: String)
    case failed(ScannerError)

    public var isRunning: Bool {
        if case .running = self { true } else { false }
    }
}

public enum ScannerError: Error, Sendable, Equatable, LocalizedError {
    /// The user denied camera access, or it is restricted (parental controls, MDM).
    case cameraAccessDenied
    /// No usable camera on this device.
    case cameraUnavailable
    case configurationFailed(reason: String)
    /// The capture session stopped because of a system error.
    case captureFailed(reason: String)
    /// Simulator only: `scanbridge-host` speaks another protocol version.
    case incompatibleHost(reason: String)

    public var errorDescription: String? {
        switch self {
        case .cameraAccessDenied:
            "Camera access is denied. Enable it in Settings to scan codes."
        case .cameraUnavailable:
            "No camera is available on this device."
        case .configurationFailed(let reason):
            "The camera could not be configured: \(reason)"
        case .captureFailed(let reason):
            "The camera stopped: \(reason)"
        case .incompatibleHost(let reason):
            "scanbridge-host is incompatible with this app: \(reason)"
        }
    }
}

/// Address of `scanbridge-host`, used only when running in the iOS Simulator.
public struct SimulatorHost: Sendable, Hashable {
    public var host: String
    public var port: UInt16

    public init(host: String = "127.0.0.1", port: UInt16 = BridgeProtocol.defaultPort) {
        self.host = host
        self.port = port
    }

    public static let localhost = SimulatorHost()

    var description: String { "\(host):\(port)" }
}

public struct ScannerConfiguration: Sendable {
    public enum Mode: Sendable, Hashable {
        /// Camera preview and code detection.
        case scan
        /// Camera preview only: no code is ever decoded or reported. In the simulator, the Mac
        /// host then only streams the camera, which saves its CPU.
        case lite
    }

    public var mode: Mode

    /// Symbologies to report. Ignored in `.lite` mode. Restricting this list makes detection faster and more reliable.
    public var symbologies: Set<Symbology>

    /// A code is reported again only once it has been out of sight for this long.
    /// `nil` reports the code on every frame it is visible in.
    public var duplicateSuppressionInterval: Duration?

    /// Where to find `scanbridge-host` when running in the iOS Simulator. Ignored on devices.
    public var simulatorHost: SimulatorHost

    public init(
        mode: Mode = .scan,
        symbologies: Set<Symbology> = Set(Symbology.allCases),
        duplicateSuppressionInterval: Duration? = .seconds(2),
        simulatorHost: SimulatorHost = .localhost
    ) {
        self.mode = mode
        self.symbologies = symbologies
        self.duplicateSuppressionInterval = duplicateSuppressionInterval
        self.simulatorHost = simulatorHost
    }

    /// Camera stream only, without code detection.
    public static func lite(simulatorHost: SimulatorHost = .localhost) -> ScannerConfiguration {
        ScannerConfiguration(mode: .lite, simulatorHost: simulatorHost)
    }

    /// Symbologies the backend must decode: none in lite mode.
    var activeSymbologies: Set<Symbology> {
        mode == .lite ? [] : symbologies
    }
}
