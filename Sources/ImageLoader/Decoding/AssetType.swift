import Foundation
import UniformTypeIdentifiers

/// 이미지와 동영상의 파일 형식입니다. 값은 UTI 문자열입니다.
///
/// ``init(_:)-(Data)``는 확장자나 MIME 타입이 아니라 데이터 앞부분의 시그니처로 형식을 알아냅니다.
public struct AssetType: ExpressibleByStringLiteral, Hashable, Sendable {
    /// 형식의 UTI 문자열입니다. 예를 들어 JPEG은 `public.jpeg`입니다.
    public let rawValue: String

    /// UTI 문자열로 형식을 만듭니다.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// UTI 문자열 리터럴로 형식을 만듭니다.
    public init(stringLiteral value: String) {
        rawValue = value
    }

    /// `UTType`으로 형식을 만듭니다.
    public init(_ type: UTType) {
        rawValue = type.identifier
    }

    /// 형식에 해당하는 `UTType`입니다. 시스템이 모르는 UTI면 `nil`입니다.
    public var utType: UTType? {
        UTType(rawValue)
    }

    /// PNG입니다. APNG도 이 형식입니다.
    public static let png: AssetType = "public.png"
    /// JPEG입니다.
    public static let jpeg: AssetType = "public.jpeg"
    /// GIF입니다.
    public static let gif: AssetType = "com.compuserve.gif"
    /// HEIC와 HEIF입니다.
    public static let heic: AssetType = "public.heic"
    /// WebP입니다.
    public static let webp: AssetType = "org.webmproject.webp"
    /// AVIF입니다.
    public static let avif: AssetType = "public.avif"
    /// MP4 동영상입니다.
    public static let mp4: AssetType = "public.mpeg4"
    /// M4V 동영상입니다.
    public static let m4v: AssetType = "com.apple.m4v-video"
    /// QuickTime 동영상입니다.
    public static let mov: AssetType = "com.apple.quicktime-movie"
    /// ICO 아이콘입니다.
    public static let ico: AssetType = "com.microsoft.ico"
    /// BMP입니다.
    public static let bmp: AssetType = "com.microsoft.bmp"
    /// TIFF입니다.
    public static let tiff: AssetType = "public.tiff"
    /// JPEG 2000입니다.
    public static let jpeg2000: AssetType = "public.jpeg-2000"

    /// MP4, M4V, QuickTime 동영상이면 `true`입니다.
    public var isVideo: Bool {
        self == .mp4 || self == .m4v || self == .mov
    }

    /// 데이터 앞부분의 시그니처로 형식을 알아냅니다. 알 수 없으면 `nil`입니다.
    ///
    /// 라이브러리가 아는 형식을 먼저 확인하고, 없으면 ``registerSignature(for:matching:)``로 등록한 순서대로 확인합니다.
    public init?(_ data: Data) {
        guard let type = Self.detect(data) ?? Self.detectRegistered(data) else { return nil }
        self = type
    }

    /// 라이브러리가 모르는 형식을 알아낼 수 있게 시그니처 확인 함수를 등록합니다.
    ///
    /// - Parameters:
    ///   - type: 확인에 성공했을 때 돌려줄 형식입니다.
    ///   - detect: 데이터가 이 형식이면 `true`를 돌려줍니다. 데이터마다 부르므로 앞부분 몇 바이트만 보고 판단해 주세요.
    public static func registerSignature(for type: AssetType, matching detect: @escaping @Sendable (Data) -> Bool) {
        registeredSignatures.withLock { $0.append(RegisteredSignature(type: type, detect: detect)) }
    }

    private struct RegisteredSignature: Sendable {
        let type: AssetType
        let detect: @Sendable (Data) -> Bool
    }

    private static let registeredSignatures = LockIsolated<[RegisteredSignature]>([])

    private static func detectRegistered(_ data: Data) -> AssetType? {
        let signatures = registeredSignatures.value
        return signatures.first { $0.detect(data) }?.type
    }

    private static let leadingSignatures: [(type: AssetType, patterns: [[UInt8?]])] = [
        (.jpeg, [[0xFF, 0xD8, 0xFF]]),
        (.png, [[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]]),
        (.gif, [[0x47, 0x49, 0x46, 0x38, 0x37, 0x61], [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]]),
        (.webp, [[0x52, 0x49, 0x46, 0x46, nil, nil, nil, nil, 0x57, 0x45, 0x42, 0x50]]),
    ]

    private static let trailingSignatures: [(type: AssetType, patterns: [[UInt8?]])] = [
        (.ico, [[0x00, 0x00, 0x01, 0x00]]),
        (.jpeg2000, [[0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20], [0xFF, 0x4F, 0xFF, 0x51]]),
        (.tiff, [[0x49, 0x49, 0x2A, 0x00], [0x4D, 0x4D, 0x00, 0x2A]]),
        (.bmp, [[0x42, 0x4D]]),
    ]

    private static let isoBaseMediaBrands: [String: AssetType] = [
        "heic": .heic, "heix": .heic, "heim": .heic, "heis": .heic, "hevc": .heic,
        "hevx": .heic, "hevm": .heic, "hevs": .heic, "mif1": .heic, "msf1": .heic,
        "avif": .avif, "avis": .avif,
        "isom": .mp4, "iso2": .mp4, "iso4": .mp4, "iso5": .mp4, "iso6": .mp4,
        "mp41": .mp4, "mp42": .mp4, "mmp4": .mp4, "avc1": .mp4, "dash": .mp4,
        "M4V ": .m4v, "M4VH": .m4v, "M4VP": .m4v,
        "qt  ": .mov,
    ]

    private static func detect(_ data: Data) -> AssetType? {
        if let type = firstMatch(in: leadingSignatures, data) {
            return type
        }
        if matches(data, [0x66, 0x74, 0x79, 0x70], offset: 4) {
            return isoBaseMediaBrand(of: data).flatMap { isoBaseMediaBrands[$0] }
        }
        return firstMatch(in: trailingSignatures, data)
    }

    private static func firstMatch(in signatures: [(type: AssetType, patterns: [[UInt8?]])], _ data: Data) -> AssetType? {
        signatures.first { signature in signature.patterns.contains { matches(data, $0) } }?.type
    }

    private static func matches(_ data: Data, _ bytes: [UInt8?], offset: Int = 0) -> Bool {
        guard data.count >= bytes.count + offset else { return false }
        let start = data.startIndex + offset
        for (index, byte) in bytes.enumerated() {
            if let byte, data[start + index] != byte {
                return false
            }
        }
        return true
    }

    private static func isoBaseMediaBrand(of data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        return String(bytes: data[(data.startIndex + 8)..<(data.startIndex + 12)], encoding: .ascii)
    }
}
