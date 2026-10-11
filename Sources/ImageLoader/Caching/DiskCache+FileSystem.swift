import Darwin
import Foundation

enum DiskCacheFile {
    struct ScannedFile {
        let name: String
        let size: Int
        let modified: TimeInterval
    }

    struct Scan {
        var files: [ScannedFile] = []
        var staleTemporaryNames: [String] = []
    }

    static let accessPersistInterval: TimeInterval = 60 * 60
    static let protection = FileProtectionType.completeUntilFirstUserAuthentication
    static let writeOptions: Data.WritingOptions = [.completeFileProtectionUntilFirstUserAuthentication]
    static let staleTemporaryAge: TimeInterval = 60

    static func path(_ directoryPath: String, _ name: String) -> String {
        directoryPath + "/" + name
    }

    static func isTemporary(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(".tmp")
    }

    static func temporaryName(for name: String) -> String {
        "." + name + "." + UUID().uuidString + ".tmp"
    }

    static func read(atPath path: String, now: TimeInterval) -> Result<Data, POSIXError> {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return .failure(error(errno)) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .failure(error(errno)) }
        let size = Int(info.st_size)
        var data = Data(count: size)
        if size > 0 {
            let code = data.withUnsafeMutableBytes { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return EIO }
                var offset = 0
                while offset < size {
                    let count = Darwin.read(descriptor, base + offset, size - offset)
                    if count > 0 {
                        offset += count
                    } else if count == 0 {
                        return EIO
                    } else if errno != EINTR {
                        return errno
                    }
                }
                return 0
            }
            guard code == 0 else { return .failure(error(code)) }
        }
        if now - referenceTime(info.st_mtimespec) >= accessPersistInterval {
            var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(referenceTime: now)]
            _ = futimens(descriptor, &times)
        }
        return .success(data)
    }

    static func exists(atPath path: String) -> Bool {
        access(path, F_OK) == 0
    }

    static func isDirectory(atPath path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR
    }

    static func createDirectory(atPath path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: protection]
        )
    }

    static func write(_ data: Data, toPath path: String, temporaryPath: String) throws {
        do {
            try data.write(to: URL(fileURLWithPath: temporaryPath, isDirectory: false), options: writeOptions)
        } catch {
            unlink(temporaryPath)
            throw error
        }
        guard rename(temporaryPath, path) == 0 else {
            let code = errno
            unlink(temporaryPath)
            throw error(code)
        }
    }

    static func remove(atPath path: String) -> POSIXError? {
        guard unlink(path) != 0 else { return nil }
        let code = errno
        return code == ENOENT ? nil : error(code)
    }

    static func scan(directoryPath: String, staleTemporaryBefore cutoff: TimeInterval) throws -> Scan {
        var scan = Scan()
        try enumerate(directoryPath: directoryPath) { name, info in
            let modified = referenceTime(info.st_mtimespec)
            if isTemporary(name) {
                if modified < cutoff {
                    scan.staleTemporaryNames.append(name)
                }
            } else if !name.hasPrefix(".") {
                scan.files.append(ScannedFile(name: name, size: Int(info.st_size), modified: modified))
            }
        }
        return scan
    }

    static func removeAllFiles(directoryPath: String, keeping survivors: Set<String>) throws {
        var names: [String] = []
        try enumerate(directoryPath: directoryPath) { name, _ in
            if isTemporary(name) || (!name.hasPrefix(".") && !survivors.contains(name)) {
                names.append(name)
            }
        }
        var firstError: POSIXError?
        for name in names {
            if let failure = remove(atPath: path(directoryPath, name)), firstError == nil {
                firstError = failure
            }
        }
        if let firstError {
            throw firstError
        }
    }

    static func allocatedSize(directoryPath: String) -> Int {
        var total = 0
        try? enumerate(directoryPath: directoryPath) { name, info in
            if !name.hasPrefix(".") {
                total += Int(info.st_blocks) * 512
            }
        }
        return total
    }

    private static func enumerate(directoryPath: String, _ body: (String, stat) -> Void) throws {
        guard let directory = opendir(directoryPath) else {
            let code = errno
            if code == ENOENT {
                return
            }
            throw error(code)
        }
        defer { closedir(directory) }
        let descriptor = dirfd(directory)
        while let entry = readdir(directory) {
            let length = Int(entry.pointee.d_namlen)
            let decoded = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(bytes: raw.prefix(length), encoding: .utf8)
            }
            guard let name = decoded else {
                continue
            }
            if name == "." || name == ".." {
                continue
            }
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG else {
                continue
            }
            body(name, info)
        }
    }

    static func referenceTime(_ time: timespec) -> TimeInterval {
        TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000 - kCFAbsoluteTimeIntervalSince1970
    }

    static func error(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}

extension timespec {
    fileprivate init(referenceTime: TimeInterval) {
        let unixTime = referenceTime + kCFAbsoluteTimeIntervalSince1970
        let seconds = unixTime.rounded(.down)
        self.init(tv_sec: Int(seconds), tv_nsec: Int((unixTime - seconds) * 1_000_000_000))
    }
}
