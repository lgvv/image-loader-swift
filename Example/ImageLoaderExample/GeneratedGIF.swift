import Foundation
import ImageIO
import ImageLoader
import UIKit
import UniformTypeIdentifiers

enum GeneratedGIF {
    static let count = 300
    static let frameCount = 10
    static let side = 160

    static func request(index: Int) -> ImageRequest {
        ImageRequest(id: "demo-gif-\(index)") {
            try await Task.sleep(nanoseconds: UInt64.random(in: 30_000_000...250_000_000))
            return data(index: index)
        }
    }

    static func data(index: Int) -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, frameCount, nil) else {
            return Data()
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let hue = CGFloat(index % 36) / 36
        let label = "\(index)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 44), .foregroundColor: UIColor.white]
        for frame in 0..<frameCount {
            let image = renderer.image { context in
                UIColor(hue: hue, saturation: 0.6, brightness: 0.75, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                let angle = CGFloat(frame) / CGFloat(frameCount) * 2 * .pi
                let center = CGPoint(x: size.width / 2 + cos(angle) * 48, y: size.height / 2 + sin(angle) * 48)
                UIColor.white.withAlphaComponent(0.85).setFill()
                context.cgContext.fillEllipse(in: CGRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28))
                let textSize = label.size(withAttributes: attributes)
                label.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attributes)
            }
            guard let cgImage = image.cgImage else { continue }
            CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.08]] as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}
