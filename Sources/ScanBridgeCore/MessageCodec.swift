import Foundation

// Wire format, all integers big endian:
//
//   ┌───────────┬──────────┬────────────────┬─────────────┐
//   │ "SB" (2)  │ type (1) │ length (4)     │ payload     │
//   └───────────┴──────────┴────────────────┴─────────────┘
//
// hello / failure payload: JSON.
// frame payload: metadata length (4) │ metadata JSON │ JPEG bytes.

private enum MessageType: UInt8 {
    case hello = 0x01
    case frame = 0x02
    case failure = 0x03
}

private struct FrameMetadata: Codable {
    var sequence: UInt64
    var width: Int
    var height: Int
    var codes: [DetectedCode]
}

public enum MessageEncoder {
    public static func encode(_ message: BridgeMessage) throws -> Data {
        let type: MessageType
        let payload: Data

        switch message {
        case .hello(let hello):
            type = .hello
            payload = try JSONEncoder().encode(hello)
        case .failure(let failure):
            type = .failure
            payload = try JSONEncoder().encode(failure)
        case .frame(let frame):
            type = .frame
            let metadata = try JSONEncoder().encode(
                FrameMetadata(sequence: frame.sequence, width: frame.width, height: frame.height, codes: frame.codes)
            )
            var body = Data(capacity: 4 + metadata.count + frame.jpegData.count)
            body.appendBigEndian(UInt32(metadata.count))
            body.append(metadata)
            body.append(frame.jpegData)
            payload = body
        }

        guard payload.count <= BridgeProtocol.maximumPayloadSize else {
            throw BridgeProtocolError.payloadTooLarge(payload.count)
        }

        var data = Data(capacity: BridgeProtocol.headerSize + payload.count)
        data.append(contentsOf: BridgeProtocol.magic)
        data.append(type.rawValue)
        data.appendBigEndian(UInt32(payload.count))
        data.append(payload)
        return data
    }
}

/// Incremental decoder: feed it bytes as they arrive from the socket, in chunks of any size.
///
/// Once `decode(_:)` throws, the stream is unrecoverable and the connection must be closed.
public struct MessageDecoder: Sendable {
    private var buffer = Data()
    private let maximumPayloadSize: Int

    public init(maximumPayloadSize: Int = BridgeProtocol.maximumPayloadSize) {
        self.maximumPayloadSize = maximumPayloadSize
    }

    /// Number of bytes received but not yet forming a complete message.
    public var bufferedByteCount: Int { buffer.count }

    public mutating func decode(_ chunk: Data) throws -> [BridgeMessage] {
        buffer.append(chunk)

        var messages: [BridgeMessage] = []
        var offset = 0

        while buffer.count - offset >= BridgeProtocol.headerSize {
            let start = buffer.startIndex + offset
            guard buffer[start] == BridgeProtocol.magic[0], buffer[start + 1] == BridgeProtocol.magic[1] else {
                throw BridgeProtocolError.invalidMagic
            }
            let rawType = buffer[start + 2]
            let length = Int(buffer.readBigEndianUInt32(at: start + 3))
            guard length <= maximumPayloadSize else {
                throw BridgeProtocolError.payloadTooLarge(length)
            }

            let messageSize = BridgeProtocol.headerSize + length
            guard buffer.count - offset >= messageSize else { break }

            let payloadStart = start + BridgeProtocol.headerSize
            let payload = buffer[payloadStart ..< payloadStart + length]
            messages.append(try Self.decodeMessage(type: rawType, payload: payload))
            offset += messageSize
        }

        if offset > 0 {
            buffer = Data(buffer.dropFirst(offset))
        }
        return messages
    }

    private static func decodeMessage(type rawType: UInt8, payload: Data) throws -> BridgeMessage {
        guard let type = MessageType(rawValue: rawType) else {
            throw BridgeProtocolError.unknownMessageType(rawType)
        }

        do {
            switch type {
            case .hello:
                return .hello(try JSONDecoder().decode(Hello.self, from: payload))
            case .failure:
                return .failure(try JSONDecoder().decode(BridgeFailure.self, from: payload))
            case .frame:
                guard payload.count >= 4 else {
                    throw BridgeProtocolError.malformedPayload("frame shorter than its metadata header")
                }
                let metadataLength = Int(payload.readBigEndianUInt32(at: payload.startIndex))
                let metadataStart = payload.startIndex + 4
                guard metadataLength <= payload.count - 4 else {
                    throw BridgeProtocolError.malformedPayload("frame metadata length out of bounds")
                }
                let metadataEnd = metadataStart + metadataLength
                let metadata = try JSONDecoder().decode(FrameMetadata.self, from: payload[metadataStart ..< metadataEnd])
                return .frame(
                    VideoFrame(
                        sequence: metadata.sequence,
                        width: metadata.width,
                        height: metadata.height,
                        codes: metadata.codes,
                        jpegData: Data(payload[metadataEnd...])
                    )
                )
            }
        } catch let error as BridgeProtocolError {
            throw error
        } catch {
            throw BridgeProtocolError.malformedPayload(String(describing: error))
        }
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    /// Reads 4 bytes at an absolute index (not an offset from `startIndex`).
    func readBigEndianUInt32(at index: Index) -> UInt32 {
        self[index ..< index + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
