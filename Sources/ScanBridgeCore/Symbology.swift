/// A barcode symbology supported by ScanBridge.
///
/// The raw value is part of the wire protocol between the iOS client and the Mac host:
/// never rename an existing case's raw value.
public enum Symbology: String, Sendable, Hashable, CaseIterable, Codable {
    // 2D
    case qr
    case microQR
    case aztec
    case dataMatrix
    case pdf417
    case microPDF417

    // 1D
    case ean8
    case ean13
    case upce
    case code39
    case code93
    case code128
    case itf14
    case interleaved2of5
    case codabar
    case gs1DataBar
    case gs1DataBarExpanded
    case gs1DataBarLimited

    /// Matrix and stacked codes (QR, Data Matrix, PDF417…).
    public static let twoDimensional: Set<Symbology> = [
        .qr, .microQR, .aztec, .dataMatrix, .pdf417, .microPDF417,
    ]

    /// Linear barcodes (EAN, UPC, Code 128…).
    public static let oneDimensional: Set<Symbology> = Set(allCases).subtracting(twoDimensional)

    public var isTwoDimensional: Bool {
        Self.twoDimensional.contains(self)
    }
}
