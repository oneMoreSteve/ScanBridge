#if os(iOS)
import AVFoundation

extension Symbology {
    /// The AVFoundation metadata types that produce this symbology.
    var metadataObjectTypes: [AVMetadataObject.ObjectType] {
        switch self {
        case .qr: [.qr]
        case .microQR: [.microQR]
        case .aztec: [.aztec]
        case .dataMatrix: [.dataMatrix]
        case .pdf417: [.pdf417]
        case .microPDF417: [.microPDF417]
        case .ean8: [.ean8]
        case .ean13: [.ean13]
        case .upce: [.upce]
        case .code39: [.code39, .code39Mod43]
        case .code93: [.code93]
        case .code128: [.code128]
        case .itf14: [.itf14]
        case .interleaved2of5: [.interleaved2of5]
        case .codabar: [.codabar]
        case .gs1DataBar: [.gs1DataBar]
        case .gs1DataBarExpanded: [.gs1DataBarExpanded]
        case .gs1DataBarLimited: [.gs1DataBarLimited]
        }
    }

    init?(metadataObjectType type: AVMetadataObject.ObjectType) {
        guard let match = Self.allCases.first(where: { $0.metadataObjectTypes.contains(type) }) else {
            return nil
        }
        self = match
    }
}
#endif
