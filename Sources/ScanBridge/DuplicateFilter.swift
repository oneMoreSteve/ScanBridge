import ScanBridgeCore

/// Suppresses a code while it stays in view.
///
/// The window slides: each sighting refreshes it, so a code held in front of the camera is
/// reported once, and again only after it has been out of sight for `interval`.
struct DuplicateFilter {
    private struct Key: Hashable {
        let payload: String
        let symbology: Symbology
    }

    let interval: Duration?
    private var lastSeen: [Key: ContinuousClock.Instant] = [:]

    init(interval: Duration?) {
        self.interval = interval
    }

    mutating func shouldReport(payload: String, symbology: Symbology, at now: ContinuousClock.Instant) -> Bool {
        guard let interval else { return true }

        let key = Key(payload: payload, symbology: symbology)
        let previous = lastSeen.updateValue(now, forKey: key)

        if lastSeen.count > 64 {
            lastSeen = lastSeen.filter { now - $0.value < interval }
        }

        guard let previous else { return true }
        return now - previous >= interval
    }

    mutating func reset() {
        lastSeen.removeAll()
    }
}
