#if os(iOS)
@testable import ScanBridge
import Testing

@MainActor
struct CodeScannerTests {
    @Test func startReflectsBackendState() async {
        let backend = FakeBackend()
        let scanner = CodeScanner(configuration: ScannerConfiguration(), backend: backend)

        await scanner.start()
        #expect(scanner.state == .running(.device))
        #expect(backend.startCount == 1)

        await scanner.start()
        #expect(backend.startCount == 1, "start() must be idempotent")

        scanner.stop()
        #expect(scanner.state == .idle)
        #expect(backend.stopCount == 1)
    }

    @Test func startFailureIsExposedAsState() async {
        let backend = FakeBackend()
        backend.startError = .cameraAccessDenied
        let scanner = CodeScanner(configuration: ScannerConfiguration(), backend: backend)

        await scanner.start()
        #expect(scanner.state == .failed(.cameraAccessDenied))

        backend.startError = nil
        await scanner.start()
        #expect(scanner.state == .running(.device), "start() retries after a failure")
    }

    @Test func reportsCodesToEverySubscriberWithoutDuplicates() async {
        let backend = FakeBackend()
        let scanner = CodeScanner(configuration: ScannerConfiguration(), backend: backend)
        let first = scanner.codes()
        let second = scanner.codes()
        await scanner.start()

        backend.detect([CodeSighting(payload: "A", symbology: .qr)])
        backend.detect([CodeSighting(payload: "A", symbology: .qr)])
        backend.detect([CodeSighting(payload: "B", symbology: .qr)])
        scanner.stop()

        #expect(await payloads(of: first, count: 2) == ["A", "B"])
        #expect(await payloads(of: second, count: 2) == ["A", "B"])
        #expect(scanner.lastScannedCode?.payload == "B")
    }

    @Test func ignoresCodesWhilePausedOrOfUnwantedSymbology() async {
        let backend = FakeBackend()
        let scanner = CodeScanner(configuration: ScannerConfiguration(symbologies: [.ean13]), backend: backend)
        await scanner.start()

        backend.detect([CodeSighting(payload: "qr", symbology: .qr)])
        scanner.isPaused = true
        backend.detect([CodeSighting(payload: "paused", symbology: .ean13)])
        #expect(scanner.lastScannedCode == nil)

        scanner.isPaused = false
        backend.detect([CodeSighting(payload: "4006381333931", symbology: .ean13)])
        #expect(scanner.lastScannedCode?.payload == "4006381333931")
    }

    @Test func liteModeOnlyStreamsTheCamera() async {
        let backend = FakeBackend()
        let scanner = CodeScanner(configuration: .lite(), backend: backend)
        await scanner.start()

        #expect(backend.requestedSymbologies == [])
        #expect(scanner.state == .running(.device))
        backend.detect([CodeSighting(payload: "ignored", symbology: .qr)])
        #expect(scanner.lastScannedCode == nil)
    }

    @Test func ignoresLateBackendEventsAfterStop() async {
        let backend = FakeBackend()
        let scanner = CodeScanner(configuration: ScannerConfiguration(), backend: backend)
        await scanner.start()
        scanner.stop()

        backend.eventHandler?(.stateChanged(.running(.device)))
        backend.detect([CodeSighting(payload: "late", symbology: .qr)])
        #expect(scanner.state == .idle)
        #expect(scanner.lastScannedCode == nil)
    }

    private func payloads(of stream: AsyncStream<ScannedCode>, count: Int) async -> [String] {
        var payloads: [String] = []
        for await code in stream {
            payloads.append(code.payload)
            if payloads.count == count { break }
        }
        return payloads
    }

    @Test func symbologiesMapToAndFromMetadataTypes() {
        for symbology in Symbology.allCases {
            #expect(!symbology.metadataObjectTypes.isEmpty)
            for type in symbology.metadataObjectTypes {
                #expect(Symbology(metadataObjectType: type) == symbology)
            }
        }
    }
}

@MainActor
private final class FakeBackend: ScannerBackend {
    var eventHandler: (@MainActor (BackendEvent) -> Void)?
    let previewSource = PreviewSource.streamedFrames
    var startError: ScannerError?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var requestedSymbologies: Set<Symbology>?

    func start(symbologies: Set<Symbology>) async throws(ScannerError) {
        startCount += 1
        requestedSymbologies = symbologies
        if let startError { throw startError }
        eventHandler?(.stateChanged(.running(.device)))
    }

    func stop() {
        stopCount += 1
    }

    func detect(_ sightings: [CodeSighting]) {
        eventHandler?(.codesDetected(sightings))
    }
}
#endif
