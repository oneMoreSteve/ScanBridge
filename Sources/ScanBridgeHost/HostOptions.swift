import Foundation
import ScanBridgeCore

struct HostOptions: Equatable {
    var port: UInt16 = BridgeProtocol.defaultPort
    var cameraName: String?
    var framesPerSecond: Double = 20
    var jpegQuality: Double = 0.6
    var mirrorsPreview = true
    /// Stream only: never decode codes, whatever the clients ask for.
    var lite = false
    var listCameras = false
    var showHelp = false

    static let usage = """
    USAGE: scanbridge-host [options]

    Streams this Mac's camera to apps running in the iOS Simulator that use ScanBridge.

    OPTIONS:
      -p, --port <port>        TCP port to listen on, loopback only (default: \(BridgeProtocol.defaultPort))
      -c, --camera <name>      Use the first camera whose name contains <name> (case insensitive)
          --fps <n>            Maximum frames per second sent to the simulator, 1-60 (default: 20)
          --quality <q>        JPEG quality of the preview stream, 0.1-1.0 (default: 0.6)
          --no-mirror          Do not mirror the preview (mirroring only affects the preview, not decoding)
      --lite               Stream the camera only, without barcode/QR code detection
      -l, --list-cameras       List available cameras and exit
      -h, --help               Show this help and exit
    """

    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ arguments: some Sequence<String>) throws(ParseError) -> HostOptions {
        var options = HostOptions()
        var iterator = arguments.makeIterator()

        func value(for flag: String) throws(ParseError) -> String {
            guard let value = iterator.next(), !value.hasPrefix("-") else {
                throw ParseError(description: "Missing value for \(flag).")
            }
            return value
        }

        while let argument = iterator.next() {
            switch argument {
            case "-p", "--port":
                let raw = try value(for: argument)
                guard let port = UInt16(raw), port > 0 else {
                    throw ParseError(description: "Invalid port '\(raw)'.")
                }
                options.port = port
            case "-c", "--camera":
                options.cameraName = try value(for: argument)
            case "--fps":
                let raw = try value(for: argument)
                guard let fps = Double(raw), (1 ... 60).contains(fps) else {
                    throw ParseError(description: "Invalid frame rate '\(raw)', expected 1-60.")
                }
                options.framesPerSecond = fps
            case "--quality":
                let raw = try value(for: argument)
                guard let quality = Double(raw), (0.1 ... 1).contains(quality) else {
                    throw ParseError(description: "Invalid JPEG quality '\(raw)', expected 0.1-1.0.")
                }
                options.jpegQuality = quality
            case "--no-mirror":
                options.mirrorsPreview = false
            case "--lite":
                options.lite = true
            case "-l", "--list-cameras":
                options.listCameras = true
            case "-h", "--help":
                options.showHelp = true
            default:
                throw ParseError(description: "Unknown option '\(argument)'.")
            }
        }
        return options
    }
}
