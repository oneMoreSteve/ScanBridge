import CoreVideo
import ScanBridgeCore
import Vision

/// Decodes barcodes with Vision. Not thread safe: use from a single serial queue.
final class BarcodeDetector {
    private let request = VNDetectBarcodesRequest()

    init() {
        let supported = (try? request.supportedSymbologies()) ?? []
        request.symbologies = supported.filter { Symbology(vision: $0) != nil }
    }

    func detect(in pixelBuffer: CVPixelBuffer) -> [DetectedCode] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        // Vision can report the same code several times in one frame.
        var seen = Set<DetectedCode>()
        return (request.results ?? []).compactMap { observation in
            guard let payload = observation.payloadStringValue,
                  let symbology = Symbology(vision: observation.symbology)
            else { return nil }
            let code = DetectedCode(payload: payload, symbology: symbology)
            return seen.insert(code).inserted ? code : nil
        }
    }
}

extension Symbology {
    init?(vision symbology: VNBarcodeSymbology) {
        switch symbology {
        case .qr: self = .qr
        case .microQR: self = .microQR
        case .aztec: self = .aztec
        case .dataMatrix: self = .dataMatrix
        case .pdf417: self = .pdf417
        case .microPDF417: self = .microPDF417
        case .ean8: self = .ean8
        case .ean13: self = .ean13
        case .upce: self = .upce
        case .code39, .code39Checksum, .code39FullASCII, .code39FullASCIIChecksum: self = .code39
        case .code93, .code93i: self = .code93
        case .code128: self = .code128
        case .itf14: self = .itf14
        case .i2of5, .i2of5Checksum: self = .interleaved2of5
        case .codabar: self = .codabar
        case .gs1DataBar: self = .gs1DataBar
        case .gs1DataBarExpanded: self = .gs1DataBarExpanded
        case .gs1DataBarLimited: self = .gs1DataBarLimited
        default: return nil
        }
    }
}
