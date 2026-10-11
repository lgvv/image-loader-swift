import Foundation

enum ImageHeaderScanner {
    static func pixelSize(of data: Data) -> ImageHeader.PixelSize? {
        data.withUnsafeBytes { buffer -> ImageHeader.PixelSize? in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard bytes.count >= 12 else {
                return nil
            }
            if matches(bytes, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
                return png(bytes)
            }
            if bytes[0] == 0xFF, bytes[1] == 0xD8 {
                return jpeg(bytes)
            }
            if matches(bytes, [0x47, 0x49, 0x46, 0x38]) {
                return gif(bytes)
            }
            if matches(bytes, [0x52, 0x49, 0x46, 0x46]), matches(bytes, [0x57, 0x45, 0x42, 0x50], at: 8) {
                return webp(bytes)
            }
            return nil
        }
    }

    private static func png(_ bytes: UnsafeBufferPointer<UInt8>) -> ImageHeader.PixelSize? {
        guard bytes.count >= 24, matches(bytes, [0x49, 0x48, 0x44, 0x52], at: 12) else {
            return nil
        }
        return size(width: bigEndian32(bytes, at: 16), height: bigEndian32(bytes, at: 20))
    }

    private static func gif(_ bytes: UnsafeBufferPointer<UInt8>) -> ImageHeader.PixelSize? {
        size(width: littleEndian(bytes, at: 6, count: 2), height: littleEndian(bytes, at: 8, count: 2))
    }

    private static func webp(_ bytes: UnsafeBufferPointer<UInt8>) -> ImageHeader.PixelSize? {
        guard bytes.count >= 30 else {
            return nil
        }
        if matches(bytes, [0x56, 0x50, 0x38, 0x58], at: 12) {
            return size(width: littleEndian(bytes, at: 24, count: 3) + 1, height: littleEndian(bytes, at: 27, count: 3) + 1)
        }
        if matches(bytes, [0x56, 0x50, 0x38, 0x20], at: 12) {
            guard matches(bytes, [0x9D, 0x01, 0x2A], at: 23) else {
                return nil
            }
            return size(width: littleEndian(bytes, at: 26, count: 2) & 0x3FFF, height: littleEndian(bytes, at: 28, count: 2) & 0x3FFF)
        }
        if matches(bytes, [0x56, 0x50, 0x38, 0x4C], at: 12) {
            guard bytes[20] == 0x2F else {
                return nil
            }
            let bits = littleEndian(bytes, at: 21, count: 4)
            return size(width: (bits & 0x3FFF) + 1, height: ((bits >> 14) & 0x3FFF) + 1)
        }
        return nil
    }

    private static func jpeg(_ bytes: UnsafeBufferPointer<UInt8>) -> ImageHeader.PixelSize? {
        var offset = 2
        while offset + 1 < bytes.count {
            guard bytes[offset] == 0xFF else {
                return nil
            }
            let marker = bytes[offset + 1]
            switch marker {
            case 0xFF:
                offset += 1
                continue
            case 0x01, 0xD0...0xD8:
                offset += 2
                continue
            case 0xD9, 0xDA:
                return nil
            default:
                break
            }
            guard offset + 4 <= bytes.count else {
                return nil
            }
            let length = bigEndian16(bytes, at: offset + 2)
            guard length >= 2 else {
                return nil
            }
            if isStartOfFrame(marker) {
                guard length >= 7, offset + 9 <= bytes.count else {
                    return nil
                }
                return size(width: bigEndian16(bytes, at: offset + 7), height: bigEndian16(bytes, at: offset + 5))
            }
            offset += 2 + length
        }
        return nil
    }

    private static func isStartOfFrame(_ marker: UInt8) -> Bool {
        switch marker {
        case 0xC0...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
            true
        default:
            false
        }
    }

    private static func size(width: Int, height: Int) -> ImageHeader.PixelSize? {
        guard width > 0, height > 0 else {
            return nil
        }
        return ImageHeader.PixelSize(width: width, height: height)
    }

    private static func matches(_ bytes: UnsafeBufferPointer<UInt8>, _ expected: [UInt8], at offset: Int = 0) -> Bool {
        guard offset + expected.count <= bytes.count else {
            return false
        }
        for (index, byte) in expected.enumerated() where bytes[offset + index] != byte {
            return false
        }
        return true
    }

    private static func bigEndian16(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> Int {
        Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }

    private static func bigEndian32(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> Int {
        Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
    }

    private static func littleEndian(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int, count: Int) -> Int {
        var value = 0
        for index in 0..<count {
            value |= Int(bytes[offset + index]) << (8 * index)
        }
        return value
    }
}
