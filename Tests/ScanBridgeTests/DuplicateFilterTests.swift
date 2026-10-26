@testable import ScanBridge
import Testing

struct DuplicateFilterTests {
    private let start = ContinuousClock.now

    @Test func reportsCodeOnceWhileItStaysInView() {
        let filter = FilterBox(interval: .seconds(2))
        #expect(filter.shouldReport(payload: "A", symbology: .qr, at: start))
        // Seen continuously for 10 s: each sighting extends the window.
        for tenth in 1 ... 100 {
            #expect(!filter.shouldReport(payload: "A", symbology: .qr, at: start + .milliseconds(tenth * 100)))
        }
    }

    @Test func reportsAgainAfterCodeLeftView() {
        let filter = FilterBox(interval: .seconds(2))
        #expect(filter.shouldReport(payload: "A", symbology: .qr, at: start))
        #expect(filter.shouldReport(payload: "A", symbology: .qr, at: start + .seconds(2)))
    }

    @Test func distinguishesPayloadsAndSymbologies() {
        let filter = FilterBox(interval: .seconds(2))
        #expect(filter.shouldReport(payload: "A", symbology: .qr, at: start))
        #expect(filter.shouldReport(payload: "B", symbology: .qr, at: start))
        #expect(filter.shouldReport(payload: "A", symbology: .code128, at: start))
    }

    @Test func nilIntervalReportsEverySighting() {
        let filter = FilterBox(interval: nil)
        #expect(filter.shouldReport(payload: "A", symbology: .qr, at: start))
        #expect(filter.shouldReport(payload: "A", symbology: .qr, at: start))
    }

    @Test func resetForgetsCodes() {
        let filter = FilterBox(interval: .seconds(2))
        #expect(filter.shouldReport(payload: "A", symbology: .qr, at: start))
        filter.reset()
        #expect(filter.shouldReport(payload: "A", symbology: .qr, at: start))
    }

    @Test func pruningKeepsRecentCodes() {
        let filter = FilterBox(interval: .seconds(2))
        #expect(filter.shouldReport(payload: "recent", symbology: .qr, at: start + .seconds(9)))
        for index in 0 ..< 100 {
            _ = filter.shouldReport(payload: "\(index)", symbology: .qr, at: start + .seconds(10))
        }
        #expect(!filter.shouldReport(payload: "recent", symbology: .qr, at: start + .seconds(10)))
    }
}

/// `#expect` cannot call mutating methods, so tests drive the filter through a reference.
private final class FilterBox {
    private var filter: DuplicateFilter

    init(interval: Duration?) {
        filter = DuplicateFilter(interval: interval)
    }

    func shouldReport(payload: String, symbology: Symbology, at now: ContinuousClock.Instant) -> Bool {
        filter.shouldReport(payload: payload, symbology: symbology, at: now)
    }

    func reset() {
        filter.reset()
    }
}
