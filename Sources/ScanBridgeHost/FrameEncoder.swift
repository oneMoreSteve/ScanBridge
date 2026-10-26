import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// Encodes camera frames to JPEG for the preview stream. Not thread safe: use from a single serial queue.
final class FrameEncoder {
    struct EncodedFrame {
        let jpegData: Data
        let width: Int
        let height: Int
    }

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let quality: Double
    private let mirrors: Bool

    init(quality: Double, mirrors: Bool) {
        self.quality = quality
        self.mirrors = mirrors
    }

    func encode(_ pixelBuffer: CVPixelBuffer) -> EncodedFrame? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if mirrors {
            image = image.oriented(.upMirrored)
        }
        let options = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        guard let data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else {
            return nil
        }
        return EncodedFrame(jpegData: data, width: Int(image.extent.width), height: Int(image.extent.height))
    }
}
