import Foundation

/// Constants shared by the iOS client and the Mac host.
public enum BridgeProtocol {
    /// Bumped on any incompatible change to the wire format.
    public static let version: UInt16 = 1

    /// TCP port the host listens on by default (loopback only).
    public static let defaultPort: UInt16 = 9876

    /// Upper bound for a single message payload. Protects both peers from
    /// allocating unbounded memory when fed garbage.
    public static let maximumPayloadSize = 8 * 1024 * 1024

    /// "SB" — lets a peer detect immediately that it is not talking to ScanBridge.
    static let magic: [UInt8] = [0x53, 0x42]

    /// magic (2) + message type (1) + payload length (4, big endian).
    static let headerSize = 7
}

/// First message sent by each peer after the TCP connection opens.
public struct Hello: Codable, Sendable, Equatable {
    public var protocolVersion: UInt16
    /// Human readable name: the camera name for the host, the device/app for the client.
    public var peerName: String
    /// Client only: `false` asks the host to stream frames without decoding codes (lite mode).
    /// Optional so hello messages without this field still decode; `nil` means `true`.
    public var detectsCodes: Bool?

    public init(protocolVersion: UInt16 = BridgeProtocol.version, peerName: String, detectsCodes: Bool? = nil) {
        self.protocolVersion = protocolVersion
        self.peerName = peerName
        self.detectsCodes = detectsCodes
    }
}

/// A code decoded by the host in a given frame.
public struct DetectedCode: Codable, Sendable, Hashable {
    public var payload: String
    /// Raw `Symbology` value. Kept as a string so that a newer host can send
    /// symbologies an older client does not know about without breaking decoding.
    public var symbology: String

    public init(payload: String, symbology: Symbology) {
        self.payload = payload
        self.symbology = symbology.rawValue
    }

    /// The symbology, or `nil` when the host sent one this client does not know.
    public var knownSymbology: Symbology? {
        Symbology(rawValue: symbology)
    }
}

/// A camera frame streamed from the host, with the codes detected in it.
public struct VideoFrame: Sendable, Equatable {
    public var sequence: UInt64
    public var width: Int
    public var height: Int
    public var codes: [DetectedCode]
    public var jpegData: Data

    public init(sequence: UInt64, width: Int, height: Int, codes: [DetectedCode], jpegData: Data) {
        self.sequence = sequence
        self.width = width
        self.height = height
        self.codes = codes
        self.jpegData = jpegData
    }
}

/// Sent by the host right before it closes a connection it refuses.
public struct BridgeFailure: Codable, Sendable, Equatable {
    public enum Code: String, Codable, Sendable {
        case incompatibleVersion
        case cameraUnavailable
        case internalError
    }

    public var code: Code
    public var message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }
}

public enum BridgeMessage: Sendable, Equatable {
    case hello(Hello)
    case frame(VideoFrame)
    case failure(BridgeFailure)
}

public enum BridgeProtocolError: Error, Equatable, CustomStringConvertible {
    case invalidMagic
    case unknownMessageType(UInt8)
    case payloadTooLarge(Int)
    case malformedPayload(String)

    public var description: String {
        switch self {
        case .invalidMagic:
            "The peer is not speaking the ScanBridge protocol."
        case .unknownMessageType(let type):
            "Unknown message type 0x\(String(type, radix: 16))."
        case .payloadTooLarge(let size):
            "Message payload of \(size) bytes exceeds the \(BridgeProtocol.maximumPayloadSize) bytes limit."
        case .malformedPayload(let reason):
            "Malformed message payload: \(reason)."
        }
    }
}
