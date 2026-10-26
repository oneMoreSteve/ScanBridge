import Foundation
import ScanBridgeCore
import Testing

struct MessageCodecTests {
    private let frame = BridgeMessage.frame(
        VideoFrame(
            sequence: 42,
            width: 1280,
            height: 720,
            codes: [
                DetectedCode(payload: "https://example.com", symbology: .qr),
                DetectedCode(payload: "4006381333931", symbology: .ean13),
            ],
            jpegData: Data((0 ..< 5000).map { UInt8(truncatingIfNeeded: $0) })
        )
    )

    @Test(arguments: [
        BridgeMessage.hello(Hello(peerName: "FaceTime HD Camera")),
        BridgeMessage.hello(Hello(peerName: "App on iPhone", detectsCodes: false)),
        BridgeMessage.failure(BridgeFailure(code: .incompatibleVersion, message: "nope")),
    ])
    func roundTripsControlMessages(_ message: BridgeMessage) throws {
        var decoder = MessageDecoder()
        let decoded = try decoder.decode(MessageEncoder.encode(message))
        #expect(decoded == [message])
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func roundTripsFrames() throws {
        var decoder = MessageDecoder()
        let decoded = try decoder.decode(MessageEncoder.encode(frame))
        #expect(decoded == [frame])
    }

    @Test func decodesMessagesSplitAcrossChunks() throws {
        let hello = BridgeMessage.hello(Hello(peerName: "Camera"))
        let stream = try MessageEncoder.encode(hello) + MessageEncoder.encode(frame) + MessageEncoder.encode(hello)

        for chunkSize in [1, 3, 7, 100, 4096] {
            var decoder = MessageDecoder()
            var decoded: [BridgeMessage] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunkSize, stream.count)
                decoded += try decoder.decode(stream.subdata(in: offset ..< end))
                offset = end
            }
            #expect(decoded == [hello, frame, hello], "chunk size \(chunkSize)")
            #expect(decoder.bufferedByteCount == 0)
        }
    }

    @Test func decodesFromDataSlices() throws {
        // Data slices keep their parent's indices; the decoder must not assume `startIndex == 0`.
        let padded = Data([0xFF, 0xFF]) + (try MessageEncoder.encode(frame))
        var decoder = MessageDecoder()
        let decoded = try decoder.decode(padded[2...])
        #expect(decoded == [frame])
    }

    @Test func rejectsForeignProtocol() {
        #expect(throws: BridgeProtocolError.invalidMagic) {
            var decoder = MessageDecoder()
            _ = try decoder.decode(Data("GET / HTTP/1.1\r\n".utf8))
        }
    }

    @Test func rejectsOversizedPayloadBeforeBuffering() {
        let header = Data([0x53, 0x42, 0x02, 0x00, 0x10, 0x00, 0x00])
        #expect(throws: BridgeProtocolError.payloadTooLarge(0x0010_0000)) {
            var decoder = MessageDecoder(maximumPayloadSize: 1024)
            _ = try decoder.decode(header)
        }
    }

    @Test func rejectsUnknownMessageType() {
        #expect(throws: BridgeProtocolError.unknownMessageType(0x7F)) {
            var decoder = MessageDecoder()
            _ = try decoder.decode(Data([0x53, 0x42, 0x7F, 0, 0, 0, 0]))
        }
    }

    @Test func rejectsFrameWithOutOfBoundsMetadata() {
        let payload = Data([0xFF, 0xFF, 0xFF, 0xFF, 0x00])
        let message = Data([0x53, 0x42, 0x02, 0, 0, 0, UInt8(payload.count)]) + payload
        #expect(throws: BridgeProtocolError.self) {
            var decoder = MessageDecoder()
            _ = try decoder.decode(message)
        }
    }

    @Test func toleratesSymbologiesUnknownToThisVersion() throws {
        var code = DetectedCode(payload: "x", symbology: .qr)
        code.symbology = "symbologyFromTheFuture"
        let message = BridgeMessage.frame(VideoFrame(sequence: 1, width: 1, height: 1, codes: [code], jpegData: Data()))

        var decoder = MessageDecoder()
        let decoded = try decoder.decode(MessageEncoder.encode(message))
        guard case .frame(let frame) = decoded.first else {
            Issue.record("Expected a frame")
            return
        }
        #expect(frame.codes.first?.knownSymbology == nil)
    }

    @Test func decodesHelloWithoutDetectionField() throws {
        let json = Data(#"{"protocolVersion":1,"peerName":"older client"}"#.utf8)
        let hello = try JSONDecoder().decode(Hello.self, from: json)
        #expect(hello.detectsCodes == nil)
    }

    @Test func symbologyGroupsPartitionAllCases() {
        #expect(Symbology.oneDimensional.isDisjoint(with: Symbology.twoDimensional))
        #expect(Symbology.oneDimensional.union(Symbology.twoDimensional) == Set(Symbology.allCases))
    }
}
