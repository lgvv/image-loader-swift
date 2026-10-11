import CryptoKit
import Foundation

extension DiskCache {
    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// 키의 SHA-256 값을 16진수 64자로 돌려줍니다. 빈 문자열이면 `nil`입니다. 기본 ``FilenameGenerator``입니다.
    public static func filename(for key: String) -> String? {
        guard !key.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8))
        return String(unsafeUninitializedCapacity: SHA256.byteCount * 2) { buffer in
            var index = 0
            for byte in digest {
                buffer[index] = hexDigits[Int(byte >> 4)]
                buffer[index + 1] = hexDigits[Int(byte & 0x0F)]
                index += 2
            }
            return index
        }
    }

    /// 이 캐시가 키에 쓰는 파일 이름입니다. `/`가 들어가거나 `.`으로 시작하는 이름이면 `nil`을 돌려줍니다.
    public func filename(for key: String) -> String? {
        guard let name = filenameGenerator(key), Self.isSafeFilename(name) else { return nil }
        return name
    }

    static func isSafeFilename(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\0")
    }

    /// 키의 파일 경로입니다. 파일로 쓰기 전이면 파일이 아직 없을 수 있습니다.
    public func url(for key: String) -> URL? {
        filename(for: key).map { path.appendingPathComponent($0, isDirectory: false) }
    }

    /// 키의 데이터를 읽거나 씁니다. `nil`을 넣으면 지웁니다.
    public subscript(key: String) -> Data? {
        get { cachedData(for: key) }
        set {
            if let newValue {
                storeData(newValue, for: key)
            } else {
                removeData(for: key)
            }
        }
    }
}
