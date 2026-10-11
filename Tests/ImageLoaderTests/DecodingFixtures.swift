import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

@testable import ImageLoader

enum DecodingFixtures {
    typealias RGB = (red: Int, green: Int, blue: Int)

    static let palette: [RGB] = [
        (230, 25, 25), (25, 230, 25), (25, 25, 230), (230, 230, 25),
        (25, 230, 230), (230, 25, 230), (128, 51, 25), (51, 128, 76),
    ]

    static func color(for index: Int) -> RGB {
        palette[index % palette.count]
    }

    static func frame(index: Int, width: Int, height: Int, colorSpace: CGColorSpace? = nil, opaque: Bool = true) -> CGImage {
        let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let alphaInfo: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: alphaInfo.rawValue)!
        let color = color(for: index)
        context.setFillColor(red: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: (index * 7) % max(1, width / 4), y: 0, width: max(1, width / 10), height: height))
        return context.makeImage()!
    }

    static func encode(
        type: UTType,
        images: [CGImage],
        containerProperties: [CFString: Any]? = nil,
        frameProperties: (Int) -> [CFString: Any]? = { _ in nil }
    ) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil)!
        if let containerProperties {
            CGImageDestinationSetProperties(destination, containerProperties as CFDictionary)
        }
        for (index, image) in images.enumerated() {
            CGImageDestinationAddImage(destination, image, frameProperties(index).map { $0 as CFDictionary })
        }
        precondition(CGImageDestinationFinalize(destination), "Failed to encode \(type.identifier)")
        return data as Data
    }

    static func gif(frameCount: Int, width: Int = 40, height: Int = 40, delay: Double = 0.05, loopCount: Int? = 0) -> Data {
        gif(delays: Array(repeating: delay, count: frameCount), width: width, height: height, loopCount: loopCount)
    }

    static func gif(delays: [Double], width: Int = 20, height: Int = 20, loopCount: Int? = 0) -> Data {
        let images = delays.indices.map { frame(index: $0, width: width, height: height) }
        let content: [CFString: Any]? = loopCount.map { [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: $0]] }
        return encode(type: .gif, images: images, containerProperties: content) { index in
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delays[index], kCGImagePropertyGIFUnclampedDelayTime: delays[index]]]
        }
    }

    static func apng(frameCount: Int, width: Int = 40, height: Int = 40, delay: Double = 0.04, loopCount: Int = 2) -> Data {
        let images = (0..<frameCount).map { frame(index: $0, width: width, height: height) }
        return encode(type: .png, images: images, containerProperties: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: loopCount]]) { _ in
            [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay, kCGImagePropertyAPNGUnclampedDelayTime: delay]]
        }
    }

    static func tiff(pageCount: Int) -> Data {
        encode(type: .tiff, images: (0..<pageCount).map { frame(index: $0, width: 30, height: 20) })
    }

    static func ico(sizes: [Int]) -> Data {
        encode(type: UTType("com.microsoft.ico")!, images: sizes.enumerated().map { frame(index: $0.offset, width: $0.element, height: $0.element, opaque: false) })
    }

    static func jpeg(width: Int, height: Int, orientation: CGImagePropertyOrientation = .up, quality: Double = 0.8) -> Data {
        encode(type: .jpeg, images: [frame(index: 0, width: width, height: height)]) { _ in
            [kCGImagePropertyOrientation: orientation.rawValue, kCGImageDestinationLossyCompressionQuality: quality]
        }
    }

    static func progressiveJPEG(width: Int, height: Int, orientation: CGImagePropertyOrientation = .up) -> Data {
        encode(type: .jpeg, images: [frame(index: 2, width: width, height: height)]) { _ in
            [
                kCGImagePropertyOrientation: orientation.rawValue,
                kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true],
                kCGImageDestinationLossyCompressionQuality: 0.8,
            ]
        }
    }

    static func lossyWebPHeader(width: Int, height: Int) -> Data {
        let payload: [UInt8] = [0x50, 0x01, 0x00, 0x9D, 0x01, 0x2A] + littleEndian(width | 0x4000, 2) + littleEndian(height | 0x8000, 2) + Array(repeating: 0, count: 16)
        let body = Array("WEBP".utf8) + riffChunk("VP8 ", payload)
        return Data(Array("RIFF".utf8) + littleEndian(body.count, 4) + body)
    }

    enum Texture {
        case noise
        case photo
    }

    static func texturedFrame(_ texture: Texture, index: Int, width: Int, height: Int, generator: inout SeededGenerator) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let random = generator.next()
                switch texture {
                case .noise:
                    bytes[offset] = UInt8(truncatingIfNeeded: random)
                    bytes[offset + 1] = UInt8(truncatingIfNeeded: random >> 8)
                    bytes[offset + 2] = UInt8(truncatingIfNeeded: random >> 16)
                case .photo:
                    let base = (red: (x * 255) / max(1, width - 1), green: (y * 255) / max(1, height - 1), blue: ((x + y + index * 16) * 255) / max(1, width + height))
                    let jitter = { (shift: UInt64) in Int((random >> shift) & 0x1F) - 16 }
                    bytes[offset] = UInt8(clamping: base.red + jitter(0))
                    bytes[offset + 1] = UInt8(clamping: base.green + jitter(8))
                    bytes[offset + 2] = UInt8(clamping: base.blue + jitter(16))
                }
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    static func texturedGIF(_ texture: Texture, frameCount: Int, width: Int, height: Int, seed: UInt64, delay: Double = 0.04) -> Data {
        var generator = SeededGenerator(seed: seed)
        let images = (0..<frameCount).map { texturedFrame(texture, index: $0, width: width, height: height, generator: &generator) }
        let content: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        return encode(type: .gif, images: images, containerProperties: content) { _ in
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]]
        }
    }

    static func png(width: Int, height: Int, colorSpace: CGColorSpace? = nil, opaque: Bool = true) -> Data {
        encode(type: .png, images: [frame(index: 1, width: width, height: height, colorSpace: colorSpace, opaque: opaque)])
    }

    static func zeroFilledPNG(width: UInt32, height: UInt32) -> Data {
        let rowBytes = Int((width + 7) / 8) + 1
        let raw = Data(count: rowBytes * Int(height))
        let deflated = try! (raw as NSData).compressed(using: .zlib) as Data
        let adler = (UInt32(raw.count % 65521) << 16) | 1
        let zlib: [UInt8] = [0x78, 0x9C] + [UInt8](deflated) + bigEndian(adler)
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += pngChunk("IHDR", bigEndian(width) + bigEndian(height) + [1, 0, 0, 0, 0])
        bytes += pngChunk("IDAT", zlib)
        bytes += pngChunk("IEND", [])
        return Data(bytes)
    }

    static func webp(frameCount: Int, width: Int = 16, height: Int = 8, durationMilliseconds: Int = 70, loopCount: Int = 0) -> Data {
        var body = Array("WEBP".utf8)
        body += riffChunk("VP8X", [0x02, 0, 0, 0] + littleEndian(width - 1, 3) + littleEndian(height - 1, 3))
        body += riffChunk("ANIM", [255, 255, 255, 255] + littleEndian(loopCount, 2))
        for index in 0..<frameCount {
            let bitstream = riffChunk("VP8L", losslessBitstream(width: width, height: height, color: color(for: index)))
            var header: [UInt8] = littleEndian(0, 3)
            header += littleEndian(0, 3)
            header += littleEndian(width - 1, 3)
            header += littleEndian(height - 1, 3)
            header += littleEndian(durationMilliseconds, 3)
            header.append(0x02)
            body += riffChunk("ANMF", header + bitstream)
        }
        return Data(Array("RIFF".utf8) + littleEndian(body.count, 4) + body)
    }

    static func staticWebP(width: Int = 10, height: Int = 6) -> Data {
        let body = Array("WEBP".utf8) + riffChunk("VP8L", losslessBitstream(width: width, height: height, color: color(for: 0)))
        return Data(Array("RIFF".utf8) + littleEndian(body.count, 4) + body)
    }

    static func gifFrameDescriptorOffsets(_ data: Data) -> [Int] {
        let bytes = [UInt8](data)
        var offsets: [Int] = []
        var index = 13
        if bytes[10] & 0x80 != 0 {
            index += 3 * (1 << (Int(bytes[10] & 0x07) + 1))
        }
        while index < bytes.count {
            switch bytes[index] {
            case 0x21:
                index += 2
                while index < bytes.count, bytes[index] != 0 {
                    index += Int(bytes[index]) + 1
                }
                index += 1
            case 0x2C:
                offsets.append(index)
                let packed = bytes[index + 9]
                index += 10
                if packed & 0x80 != 0 {
                    index += 3 * (1 << (Int(packed & 0x07) + 1))
                }
                index += 1
                while index < bytes.count, bytes[index] != 0 {
                    index += Int(bytes[index]) + 1
                }
                index += 1
            default:
                return offsets
            }
        }
        return offsets
    }

    static func centerColor(of image: CGImage) -> RGB {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .none
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        context.draw(image, in: CGRect(x: -(width * 0.75).rounded(.down), y: -(height / 2).rounded(.down), width: width, height: height))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        return (Int(pixels[0]), Int(pixels[1]), Int(pixels[2]))
    }

    static func isClose(_ lhs: RGB, _ rhs: RGB, tolerance: Int = 40) -> Bool {
        abs(lhs.red - rhs.red) <= tolerance && abs(lhs.green - rhs.green) <= tolerance && abs(lhs.blue - rhs.blue) <= tolerance
    }

    static func displaySize(of image: UIImage) -> CGSize {
        CGSize(width: (image.size.width * image.scale).rounded(), height: (image.size.height * image.scale).rounded())
    }

    static func context(for data: Data, request: ImageRequest = ImageRequest(url: Fixtures.url), limits: ImageDecodingLimits = .default) -> ImageDecodingContext {
        var context = ImageDecodingContext(request: request, data: data)
        context.decodingLimits = limits
        return context
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func littleEndian(_ value: Int, _ byteCount: Int) -> [UInt8] {
        (0..<byteCount).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }

    private static func pngChunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let typeBytes = Array(type.utf8)
        return bigEndian(UInt32(payload.count)) + typeBytes + payload + bigEndian(crc32(typeBytes + payload))
    }

    private static func riffChunk(_ fourCC: String, _ payload: [UInt8]) -> [UInt8] {
        var chunk = Array(fourCC.utf8) + littleEndian(payload.count, 4) + payload
        if payload.count % 2 == 1 {
            chunk.append(0)
        }
        return chunk
    }

    private static func losslessBitstream(width: Int, height: Int, color: RGB) -> [UInt8] {
        var writer = LSBBitWriter()
        writer.write(UInt32(width - 1), bitCount: 14)
        writer.write(UInt32(height - 1), bitCount: 14)
        writer.write(0, bitCount: 1)
        writer.write(0, bitCount: 3)
        writer.write(0, bitCount: 1)
        writer.write(0, bitCount: 1)
        writer.write(0, bitCount: 1)
        for symbol in [color.green, color.red, color.blue, 255, 0] {
            writer.write(1, bitCount: 1)
            writer.write(0, bitCount: 1)
            writer.write(1, bitCount: 1)
            writer.write(UInt32(symbol), bitCount: 8)
        }
        return [0x2F] + writer.bytes
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private struct LSBBitWriter {
        var bytes: [UInt8] = []
        var bitCount = 0

        mutating func write(_ value: UInt32, bitCount count: Int) {
            for bit in 0..<count {
                if bitCount % 8 == 0 {
                    bytes.append(0)
                }
                bytes[bytes.count - 1] |= UInt8((value >> UInt32(bit)) & 1) << UInt8(bitCount % 8)
                bitCount += 1
            }
        }
    }
}
