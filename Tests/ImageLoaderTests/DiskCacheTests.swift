import Foundation
@_spi(Testing) @testable import ImageLoader
import ImageLoaderTesting
import Testing
import UIKit

private func makeTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("DiskCacheTests-\(UUID().uuidString)", isDirectory: true)
}

private func removeTemporaryDirectory(_ url: URL) {
    chmod(url.path, 0o755)
    try? FileManager.default.removeItem(at: url)
}

private func storedFiles(at url: URL) -> [String: Int] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    var files: [String: Int] = [:]
    for name in names where !name.hasPrefix(".") {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(name).path)
        files[name] = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }
    return files
}

private func temporaryFiles(at url: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0.hasSuffix(".tmp") }
}

private func fileExists(_ cache: DiskCache, _ key: String) -> Bool {
    guard let url = cache.url(for: key) else { return false }
    return FileManager.default.fileExists(atPath: url.path)
}

private func modificationDate(_ url: URL) throws -> Date {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
}

private func setModificationDate(_ date: Date, _ url: URL) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

private func recordDiagnostics(of cache: DiskCache) -> Box<[ImageSession.Diagnostic]> {
    let diagnostics = Box<[ImageSession.Diagnostic]>([])
    cache.installDiagnosticHandlerIfNeeded { diagnostic in
        diagnostics.mutate { $0.append(diagnostic) }
    }
    return diagnostics
}

private func failureOperations(_ diagnostics: [ImageSession.Diagnostic]) -> [ImageSession.DiskCacheOperation] {
    diagnostics.compactMap { diagnostic in
        guard case .diskCacheFailure(let operation, _) = diagnostic else { return nil }
        return operation
    }
}

private func makeCache(at directory: URL, clock: Box<TimeInterval>? = nil, notificationCenter: NotificationCenter = NotificationCenter()) throws -> DiskCache {
    let sessionClock: any SessionClock = clock.map { DiskCacheTestClock(time: $0) } ?? DiskCache.wallClock
    let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
    while true {
        do {
            return try DiskCache(path: directory, filenameGenerator: DiskCache.filename(for:), clock: sessionClock, notificationCenter: notificationCenter)
        } catch DiskCache.Error.pathInUse where DispatchTime.now().uptimeNanoseconds < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
}

private func recordSizeLimitAtRegistration(of path: URL) throws -> (observed: Box<[Int]>, key: String) {
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    let key = DiskCache.registryKey(for: path)
    let observed = Box<[Int]>([])
    DiskCache.setRegistrationHook(
        {
            if let cache = try? DiskCache.registered(at: path) {
                observed.mutate { $0.append(cache.sizeLimit) }
            }
        }, forRegistryKey: key)
    return (observed, key)
}

@Suite struct DiskCacheTests {
    @Test func filenameIsStableLowercaseSHA256Hex() throws {
        #expect(DiskCache.filename(for: "") == nil)
        #expect(DiskCache.filename(for: "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let name = try #require(DiskCache.filename(for: "https://example.com/image.png"))
        #expect(name.count == 64)
        #expect(name.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(DiskCache.filename(for: "https://example.com/image.png") == name)
        #expect(DiskCache.filename(for: "https://example.com/image.jpg") != name)
    }

    @Test func customFilenameGeneratorNamesFilesAndNilSkipsStorage() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let cache = try DiskCache(path: directory) { key in key == "skip" ? nil : "file-" + key }
        cache.storeData(Data([1, 2, 3]), for: "a")
        cache.storeData(Data([4]), for: "skip")
        #expect(cache.cachedData(for: "skip") == nil)
        #expect(!cache.containsData(for: "skip"))
        cache.flush()
        #expect(storedFiles(at: directory) == ["file-a": 3])
        #expect(cache.filename(for: "a") == "file-a")
        #expect(cache.url(for: "a")?.lastPathComponent == "file-a")
        #expect(cache.totalCount == 1)
    }

    @Test func stagedChangesAreVisibleBeforeFlush() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let cache = try makeCache(at: directory)
        cache.flushInterval = 3600
        let data = Data(repeating: 3, count: 120)

        cache.storeData(data, for: "a")
        #expect(cache.cachedData(for: "a") == data)
        #expect(cache.containsData(for: "a"))
        #expect(cache.totalCount == 1)
        #expect(cache.totalSize == 120)
        #expect(!fileExists(cache, "a"))

        cache.removeData(for: "a")
        #expect(cache.cachedData(for: "a") == nil)
        #expect(!cache.containsData(for: "a"))
        #expect(cache.totalCount == 0)

        cache["b"] = data
        #expect(cache["b"] == data)
        cache.flush()
        #expect(fileExists(cache, "b"))
        #expect(try Data(contentsOf: #require(cache.url(for: "b"))) == data)
        cache["b"] = nil
        #expect(cache["b"] == nil)
        cache.flush()
        #expect(!fileExists(cache, "b"))
    }

    @Test func flushForKeyPersistsOnlyThatKey() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let cache = try makeCache(at: directory)
        cache.flushInterval = 3600
        cache.storeData(Data([1]), for: "a")
        cache.storeData(Data([2]), for: "b")
        cache.flush(for: "a")
        #expect(fileExists(cache, "a"))
        #expect(!fileExists(cache, "b"))
        #expect(cache.cachedData(for: "b") == Data([2]))
        #expect(cache.totalCount == 2)
    }

    @Test func timerFlushPersistsWithoutExplicitFlush() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let cache = try makeCache(at: directory)
        cache.flushInterval = 0.02
        cache.storeData(Data([1, 2]), for: "a")
        #expect(await waitUntil(timeout: 30) { fileExists(cache, "a") })
    }

    @Test func exceedingMaximumStagedBytesFlushesImmediately() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let cache = try makeCache(at: directory)
        cache.flushInterval = 3600
        cache.maximumStagedBytes = 1000
        cache.storeData(Data(count: 600), for: "a")
        cache.storeData(Data(count: 600), for: "b")
        #expect(await waitUntil(timeout: 30) { fileExists(cache, "a") && fileExists(cache, "b") })
    }

    @Test func flushedDataIsRestoredByNewInstance() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let values = (0..<20).map { Data(repeating: UInt8($0), count: 100 + $0 * 7) }
        try writeValues(values, directory: directory)

        let reopened = try makeCache(at: directory)
        for (index, value) in values.enumerated() {
            #expect(reopened.cachedData(for: "key-\(index)") == value)
        }
        #expect(reopened.totalCount == values.count)
        #expect(reopened.totalSize == values.reduce(0) { $0 + $1.count })
    }

    private func writeValues(_ values: [Data], directory: URL) throws {
        let cache = try makeCache(at: directory)
        for (index, value) in values.enumerated() {
            cache.storeData(value, for: "key-\(index)")
        }
        cache.flush()
        #expect(cache.totalCount == values.count)
    }

    @Test func removeAllThenWritesPersistOnlyLaterWrites() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        do {
            let cache = try makeCache(at: directory)
            cache.storeData(Data([1]), for: "a")
            cache.flush()
            cache.storeData(Data([2]), for: "staged")
            cache.removeAll()
            cache.storeData(Data([3]), for: "b")
            #expect(cache.cachedData(for: "a") == nil)
            #expect(cache.cachedData(for: "staged") == nil)
            #expect(cache.cachedData(for: "b") == Data([3]))
            #expect(cache.totalCount == 1)
            cache.flush()
        }
        let reopened = try makeCache(at: directory)
        #expect(reopened.cachedData(for: "a") == nil)
        #expect(reopened.cachedData(for: "staged") == nil)
        #expect(reopened.cachedData(for: "b") == Data([3]))
        #expect(reopened.totalCount == 1)
    }

    @Test(arguments: 0..<5)
    func removeAllNeverResurrectsEarlierWrites(iteration: Int) throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let afterNames = Set((0..<50).compactMap { DiskCache.filename(for: "after-\($0)") })
        try runRemoveAllRace(directory: directory, afterNames: afterNames)

        let reopened = try makeCache(at: directory)
        #expect((0..<300).filter { reopened.cachedData(for: "before-\($0)") != nil }.isEmpty)
        #expect((0..<50).filter { reopened.cachedData(for: "after-\($0)") == nil }.isEmpty)
        #expect(reopened.totalCount == 50)
    }

    private func runRemoveAllRace(directory: URL, afterNames: Set<String>) throws {
        let cache = try makeCache(at: directory)
        cache.flushInterval = 0.001
        cache.maximumStagedBytes = 64 * 1024
        let payload = Data(repeating: 7, count: 2048)
        DispatchQueue.concurrentPerform(iterations: 6) { worker in
            for index in stride(from: worker, to: 300, by: 6) {
                cache.storeData(payload, for: "before-\(index)")
                if index % 37 == 0 {
                    cache.flush()
                }
            }
        }
        let started = DispatchSemaphore(value: 0)
        cache.queue.async {
            started.signal()
            cache.flush()
        }
        started.wait()
        cache.removeAll()
        #expect((0..<300).filter { cache.cachedData(for: "before-\($0)") != nil }.isEmpty)
        #expect(cache.totalCount == 0)
        for index in 0..<50 {
            cache.storeData(payload, for: "after-\(index)")
        }
        cache.flush()
        #expect((0..<300).filter { cache.containsData(for: "before-\($0)") }.isEmpty)
        #expect(Set(storedFiles(at: directory).keys) == afterNames)
        #expect(cache.totalCount == 50)
        #expect(cache.totalSize == 50 * payload.count)
    }

    @Test func evictsLeastRecentlyUsedAfterReadPromotion() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let cache = try makeCache(at: directory)
        cache.sizeLimit = 1000
        for key in ["a", "b", "c"] {
            cache.storeData(Data(repeating: 1, count: 300), for: key)
            cache.flush()
        }
        #expect(cache.cachedData(for: "a") != nil)
        cache.storeData(Data(repeating: 2, count: 300), for: "d")
        cache.flush()

        #expect(cache.cachedData(for: "b") == nil)
        #expect(!fileExists(cache, "b"))
        for key in ["a", "c", "d"] {
            #expect(cache.cachedData(for: key) != nil)
        }
        #expect(cache.totalSize == 900)
        #expect(cache.totalCount == 3)
    }

    @Test func evictionStopsAtNinetyPercentOfSizeLimit() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let cache = try makeCache(at: directory)
        cache.sizeLimit = 1000
        for index in 0..<10 {
            cache.storeData(Data(repeating: 1, count: 100), for: "key-\(index)")
            cache.flush()
        }
        #expect(cache.totalSize == 1000)
        cache.storeData(Data(repeating: 1, count: 100), for: "key-10")
        cache.flush()
        #expect(cache.totalSize == 900)
        #expect(!fileExists(cache, "key-0"))
        #expect(!fileExists(cache, "key-1"))
        #expect(fileExists(cache, "key-2"))
        #expect(storedFiles(at: directory).count == 9)
    }

    @Test func readsBeforeIndexBuildArePromotedWhenIndexIsBuilt() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let urls = try writeThreeEntries(directory: directory)
        try setModificationDate(Date(timeIntervalSinceNow: -300), urls[0])
        try setModificationDate(Date(timeIntervalSinceNow: -200), urls[1])
        try setModificationDate(Date(timeIntervalSinceNow: -100), urls[2])

        let cache = try makeCache(at: directory)
        cache.sizeLimit = 1000
        #expect(cache.state.withLock { $0.index == nil })
        #expect(cache.cachedData(for: "a") != nil)
        cache.storeData(Data(repeating: 2, count: 300), for: "d")
        cache.flush()

        #expect(!fileExists(cache, "b"))
        #expect(fileExists(cache, "a"))
        #expect(fileExists(cache, "c"))
        #expect(fileExists(cache, "d"))
        #expect(cache.totalSize == 900)
    }

    private func writeThreeEntries(directory: URL) throws -> [URL] {
        let cache = try makeCache(at: directory)
        for key in ["a", "b", "c"] {
            cache.storeData(Data(repeating: 1, count: 300), for: key)
        }
        cache.flush()
        return try ["a", "b", "c"].map { try #require(cache.url(for: $0)) }
    }

    @Test func sweepRemovesEntriesOlderThanAgeLimit() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let urls = try writeThreeEntries(directory: directory)
        try setModificationDate(Date(timeIntervalSinceNow: -10 * 24 * 60 * 60), urls[0])
        try setModificationDate(Date(timeIntervalSinceNow: -6 * 24 * 60 * 60), urls[1])

        let cache = try makeCache(at: directory)
        cache.ageLimit = 7 * 24 * 60 * 60
        cache.sweep()

        #expect(!fileExists(cache, "a"))
        #expect(cache.cachedData(for: "a") == nil)
        #expect(fileExists(cache, "b"))
        #expect(fileExists(cache, "c"))
        #expect(cache.totalCount == 2)
        #expect(cache.totalSize == 600)
    }

    @Test func sweepWithoutAgeLimitKeepsOldEntries() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let urls = try writeThreeEntries(directory: directory)
        try setModificationDate(Date(timeIntervalSinceNow: -100 * 24 * 60 * 60), urls[0])
        let cache = try makeCache(at: directory)
        cache.sweep()
        #expect(fileExists(cache, "a"))
        #expect(cache.totalCount == 3)
    }

    @Test func sweepTrimsToTrimRatioWhenOverSizeLimit() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let cache = try makeCache(at: directory)
        for index in 0..<10 {
            cache.storeData(Data(repeating: 1, count: 100), for: "key-\(index)")
            cache.flush()
        }
        cache.sizeLimit = 500
        cache.sweep()
        #expect(cache.totalSize == 300)
        #expect(Set(storedFiles(at: directory).keys) == Set((7..<10).compactMap { DiskCache.filename(for: "key-\($0)") }))
    }

    @Test func readRefreshesModificationDateAtMostOncePerHour() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let urls = try writeThreeEntries(directory: directory)
        let stale = Date(timeIntervalSinceNow: -2 * 60 * 60)
        let recent = Date(timeIntervalSinceNow: -30 * 60)
        try setModificationDate(stale, urls[0])
        try setModificationDate(recent, urls[1])

        let cache = try makeCache(at: directory)
        #expect(cache.cachedData(for: "a") != nil)
        #expect(cache.cachedData(for: "b") != nil)
        #expect(abs(try modificationDate(urls[0]).timeIntervalSinceNow) < 60)
        #expect(abs(try modificationDate(urls[1]).timeIntervalSince(recent)) < 1)
    }

    @Test func maximumEntrySizeRejectsLargeDataAndReportsDiagnostic() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let cache = try makeCache(at: directory)
        let diagnostics = recordDiagnostics(of: cache)
        cache.maximumEntrySize = 100
        cache.storeData(Data(count: 100), for: "a")
        cache.flush()
        #expect(fileExists(cache, "a"))

        cache.storeData(Data(count: 101), for: "a")
        cache.storeData(Data(count: 500), for: "b")
        #expect(cache.cachedData(for: "a") == nil)
        #expect(cache.cachedData(for: "b") == nil)
        cache.flush()
        #expect(!fileExists(cache, "a"))
        #expect(!fileExists(cache, "b"))
        #expect(cache.totalCount == 0)

        let errors = diagnostics.value.compactMap { diagnostic -> DiskCache.EntryTooLargeError? in
            guard case .diskCacheFailure(.write, let error) = diagnostic else { return nil }
            return error as? DiskCache.EntryTooLargeError
        }
        #expect(errors == [DiskCache.EntryTooLargeError(size: 101, limit: 100), DiskCache.EntryTooLargeError(size: 500, limit: 100)])
    }

    @Test(arguments: 0..<3)
    func concurrentSameKeyWritesLeaveOneValidValue(run: Int) throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let values = (0..<50).map { Data(repeating: UInt8($0), count: 4000 + $0) }
        let stored = try writeSameKeyConcurrently(values, directory: directory)

        #expect(values.contains(stored))
        #expect(storedFiles(at: directory).count == 1)
        #expect(temporaryFiles(at: directory).isEmpty)
        let reopened = try makeCache(at: directory)
        #expect(reopened.cachedData(for: "same") == stored)
        #expect(reopened.totalCount == 1)
        #expect(reopened.totalSize == stored.count)
    }

    private func writeSameKeyConcurrently(_ values: [Data], directory: URL) throws -> Data {
        let cache = try makeCache(at: directory)
        let diagnostics = recordDiagnostics(of: cache)
        cache.flushInterval = 0.001
        DispatchQueue.concurrentPerform(iterations: values.count) { index in
            cache.storeData(values[index], for: "same")
            if index % 5 == 0 {
                cache.flush()
            }
        }
        cache.flush()
        #expect(diagnostics.value.isEmpty)
        #expect(cache.totalCount == 1)
        let stored = try #require(cache.cachedData(for: "same"))
        #expect(cache.totalSize == stored.count)
        return stored
    }

    @Test func mixedConcurrentOperationsKeepIndexConsistentWithDisk() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let totals = try runMixedOperations(directory: directory)
        let files = storedFiles(at: directory)
        #expect(totals.size == files.values.reduce(0, +))
        #expect(totals.count == files.count)

        let reopened = try makeCache(at: directory)
        #expect(reopened.totalSize == totals.size)
        #expect(reopened.totalCount == totals.count)
    }

    private func runMixedOperations(directory: URL) throws -> (count: Int, size: Int) {
        let cache = try makeCache(at: directory)
        let diagnostics = recordDiagnostics(of: cache)
        cache.sizeLimit = 400 * 1024
        cache.flushInterval = 0.005
        cache.maximumStagedBytes = 64 * 1024
        let workers = 8
        let operationsPerWorker = 625
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            var generator = SeededGenerator(seed: UInt64(worker + 1))
            for _ in 0..<operationsPerWorker {
                let key = "key-\(Int.random(in: 0 ..< 300, using: &generator))"
                let roll = Int.random(in: 0..<100, using: &generator)
                switch roll {
                case 0..<50:
                    let size = Int.random(in: 1...6000, using: &generator)
                    cache.storeData(Data(repeating: UInt8(truncatingIfNeeded: roll), count: size), for: key)
                case 50..<70:
                    _ = cache.cachedData(for: key)
                case 70..<80:
                    cache.removeData(for: key)
                case 80..<90:
                    _ = cache.containsData(for: key)
                case 90..<95:
                    cache.flush(for: key)
                case 95..<99:
                    cache.flush()
                default:
                    cache.removeAll()
                }
            }
        }
        cache.flush()
        #expect(temporaryFiles(at: directory).isEmpty)
        #expect(cache.totalSize <= cache.sizeLimit)
        #expect(failureOperations(diagnostics.value).isEmpty)
        return (cache.totalCount, cache.totalSize)
    }

    @Test func secondInstanceForSamePathThrowsPathInUse() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        var first: DiskCache? = try DiskCache(path: directory)
        #expect(first != nil)
        #expect(throws: DiskCache.Error.pathInUse(directory)) {
            try DiskCache(path: directory)
        }
        let variant = URL(fileURLWithPath: directory.path + "/./", isDirectory: true)
        #expect(throws: DiskCache.Error.self) {
            try DiskCache(path: variant)
        }
        #expect(try DiskCache.registered(at: variant) === first)

        first = nil
        let second = try DiskCache(path: directory)
        #expect(try DiskCache.registered(at: directory) === second)
    }

    @Test func registrySurvivesConcurrentCreationAndRelease() throws {
        let directories = (0..<3).map { _ in makeTemporaryDirectory() }
        defer { directories.forEach(removeTemporaryDirectory) }
        let mismatches = Box(0)
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for iteration in 0..<40 {
                let directory = directories[(worker + iteration) % directories.count]
                let created = try? makeCache(at: directory)
                if let shared = try? DiskCache.registered(at: directory), let created, shared !== created {
                    mismatches.mutate { $0 += 1 }
                }
            }
        }
        #expect(mismatches.value == 0)
        for directory in directories {
            #expect(throws: Never.self) { try makeCache(at: directory) }
        }
    }

    @Test func withDiskCacheSharesOneInstancePerName() throws {
        let name = "ImageLoader.Tests.\(UUID().uuidString)"
        let first = ImageSession.Configuration.withDiskCache(name: name, sizeLimit: 1234)
        let second = ImageSession.Configuration.withDiskCache(name: name)
        let cache = try #require(first.diskCache as? DiskCache)
        defer { removeTemporaryDirectory(cache.path) }
        #expect(cache === second.diskCache as? DiskCache)
        #expect(cache.sizeLimit == 1234)
        #expect(throws: DiskCache.Error.pathInUse(cache.path)) {
            try DiskCache(name: name)
        }
    }

    @Test func withDiskCacheNeverShrinksSharedSizeLimit() throws {
        let name = "ImageLoader.Tests.\(UUID().uuidString)"
        let first = ImageSession.Configuration.withDiskCache(name: name, sizeLimit: 10)
        let cache = try #require(first.diskCache as? DiskCache)
        defer { removeTemporaryDirectory(cache.path) }
        #expect(cache.sizeLimit == 10)

        _ = ImageSession.Configuration.withDiskCache(name: name, sizeLimit: 5000)
        #expect(cache.sizeLimit == 5000)
        _ = ImageSession.Configuration.withDiskCache(name: name, sizeLimit: 100)
        #expect(cache.sizeLimit == 5000)
        _ = ImageSession.Configuration.withDiskCache(name: name)
        #expect(cache.sizeLimit == 5000)

        cache.sizeLimit = 200
        #expect(cache.sizeLimit == 200)
    }

    @Test func initialSizeLimitIsAppliedBeforeRegistration() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let probe = try recordSizeLimitAtRegistration(of: directory)
        defer { DiskCache.setRegistrationHook(nil, forRegistryKey: probe.key) }
        let cache = try DiskCache(
            path: directory,
            filenameGenerator: DiskCache.filename(for:),
            clock: DiskCache.wallClock,
            notificationCenter: NotificationCenter(),
            sizeLimit: 4321
        )
        #expect(probe.observed.value == [4321])
        #expect(cache.sizeLimit == 4321)
    }

    @Test func sharedCreationRegistersWithRequestedSizeLimit() throws {
        let name = "ImageLoader.Tests.\(UUID().uuidString)"
        let path = try DiskCache.directory(named: name)
        defer { removeTemporaryDirectory(path) }
        let probe = try recordSizeLimitAtRegistration(of: path)
        defer { DiskCache.setRegistrationHook(nil, forRegistryKey: probe.key) }
        let cache = try DiskCache.shared(name: name, sizeLimit: 4321)
        #expect(probe.observed.value == [4321])
        #expect(cache.sizeLimit == 4321)
        _ = try DiskCache.shared(name: name, sizeLimit: 5000)
        #expect(probe.observed.value == [4321])
        #expect(cache.sizeLimit == 5000)
    }

    @Test func concurrentSharedCreationKeepsLargestRequestedSizeLimit() throws {
        let requested = [700, 100, 900, 300, 500, 200, 800, 400]
        for _ in 0..<100 {
            let name = "ImageLoader.Tests.\(UUID().uuidString)"
            let instances = Box<[DiskCache]>([])
            DispatchQueue.concurrentPerform(iterations: requested.count) { worker in
                if let cache = try? DiskCache.shared(name: name, sizeLimit: requested[worker]) {
                    instances.mutate { $0.append(cache) }
                }
            }
            let cache = try #require(instances.value.first)
            defer { removeTemporaryDirectory(cache.path) }
            #expect(instances.value.count == requested.count)
            #expect(instances.value.allSatisfy { $0 === cache })
            #expect(cache.sizeLimit == 900)
        }
    }

    @Test func externallyDeletedFileIsTreatedAsMiss() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let cache = try makeCache(at: directory)
        let diagnostics = recordDiagnostics(of: cache)
        cache.storeData(Data([1, 2, 3]), for: "a")
        cache.storeData(Data([4, 5]), for: "b")
        cache.flush()
        try FileManager.default.removeItem(at: #require(cache.url(for: "a")))
        try FileManager.default.removeItem(at: #require(cache.url(for: "b")))

        #expect(!cache.containsData(for: "a"))
        #expect(cache.cachedData(for: "b") == nil)
        #expect(cache.totalCount == 0)
        #expect(cache.totalSize == 0)
        #expect(failureOperations(diagnostics.value) == [.read])
    }

    @Test func unreadableFileIsMissAndReportsReadFailure() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let cache = try makeCache(at: directory)
        let diagnostics = recordDiagnostics(of: cache)
        cache.storeData(Data([1, 2, 3]), for: "a")
        cache.flush()
        let path = try #require(cache.url(for: "a")).path
        chmod(path, 0)
        defer { chmod(path, 0o644) }

        #expect(cache.cachedData(for: "a") == nil)
        #expect(failureOperations(diagnostics.value) == [.read])
    }

    @Test func removedDirectoryIsRecreatedOnNextWrite() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let cache = try makeCache(at: directory)
        let diagnostics = recordDiagnostics(of: cache)
        cache.storeData(Data([1, 2, 3]), for: "a")
        cache.flush()
        try FileManager.default.removeItem(at: directory)

        cache.storeData(Data([4, 5]), for: "b")
        cache.flush()

        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(fileExists(cache, "b"))
        #expect(cache.cachedData(for: "b") == Data([4, 5]))
        #expect(cache.cachedData(for: "a") == nil)
        #expect(cache.totalCount == 1)
        #expect(cache.totalSize == 2)
        #expect(failureOperations(diagnostics.value).contains(.write))
    }

    @Test func readOnlyDirectoryReportsWriteFailureWithoutCrashing() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let cache = try makeCache(at: directory)
        let diagnostics = recordDiagnostics(of: cache)
        chmod(directory.path, 0o555)
        defer { chmod(directory.path, 0o755) }

        cache.storeData(Data([1, 2, 3]), for: "a")
        cache.flush()

        #expect(cache.cachedData(for: "a") == nil)
        #expect(cache.totalCount == 0)
        #expect(temporaryFiles(at: directory).isEmpty)
        #expect(failureOperations(diagnostics.value).contains(.write))
    }

    @Test func staleTemporaryFilesAreRemovedWhenIndexIsBuilt() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = directory.appendingPathComponent(".stale.\(UUID().uuidString).tmp")
        let fresh = directory.appendingPathComponent(".fresh.\(UUID().uuidString).tmp")
        let entry = directory.appendingPathComponent("entry")
        try Data(count: 10).write(to: stale)
        try Data(count: 10).write(to: fresh)
        try Data(count: 5).write(to: entry)
        try setModificationDate(Date(timeIntervalSinceNow: -120), stale)

        let cache = try makeCache(at: directory)
        #expect(cache.totalCount == 1)
        #expect(cache.totalSize == 5)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func scheduledSweepIsRescheduledAfterEachRun() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let now = Box<TimeInterval>(800_000_000)
        let cache = try makeCache(at: directory, clock: now)
        cache.sweepInterval = 0.02
        cache.ageLimit = 60

        cache.storeData(Data(count: 10), for: "a")
        cache.flush()
        #expect(fileExists(cache, "a"))
        now.value += 120
        #expect(await waitUntil(timeout: 30) { !fileExists(cache, "a") })

        cache.storeData(Data(count: 10), for: "b")
        cache.flush()
        #expect(fileExists(cache, "b"))
        now.value += 120
        #expect(await waitUntil(timeout: 30) { !fileExists(cache, "b") })
        #expect(cache.totalCount == 0)
    }

    @Test func enteringBackgroundSweepsAgedEntries() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let now = Box<TimeInterval>(800_000_000)
        let center = NotificationCenter()
        let cache = try makeCache(at: directory, clock: now, notificationCenter: center)
        cache.sweepInterval = 3600
        cache.ageLimit = 60
        cache.storeData(Data(count: 10), for: "a")
        cache.flush()
        now.value += 120
        cache.flushInterval = 3600
        cache.storeData(Data(count: 20), for: "b")

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        #expect(await waitUntil(timeout: 30) { !fileExists(cache, "a") && fileExists(cache, "b") })
        #expect(cache.totalCount == 1)
    }

    @Test func enteringBackgroundOnlyFlushesWhenSweepIsDisabled() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let now = Box<TimeInterval>(800_000_000)
        let center = NotificationCenter()
        let cache = try makeCache(at: directory, clock: now, notificationCenter: center)
        cache.sweepInterval = 3600
        cache.ageLimit = 60
        cache.isSweepEnabled = false
        cache.storeData(Data(count: 10), for: "a")
        cache.flush()
        now.value += 120
        cache.flushInterval = 3600
        cache.storeData(Data(count: 20), for: "b")

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        #expect(await waitUntil(timeout: 30) { fileExists(cache, "b") })
        cache.queue.sync {}
        #expect(fileExists(cache, "a"))
        #expect(cache.totalCount == 2)
    }

    @Test func sweepRemovesAgedEntriesBeforeTrimming() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let keys = ["a", "b", "c", "d", "e"]
        let ages: [TimeInterval] = [10 * 24 * 60 * 60, 400, 300, 200, 100]
        do {
            let writer = try makeCache(at: directory)
            for key in keys {
                writer.storeData(Data(repeating: 1, count: 200), for: key)
            }
            writer.flush()
            for (key, age) in zip(keys, ages) {
                try setModificationDate(Date(timeIntervalSinceNow: -age), #require(writer.url(for: key)))
            }
        }

        let cache = try makeCache(at: directory)
        cache.sizeLimit = 900
        cache.ageLimit = 24 * 60 * 60
        cache.sweep()

        #expect(Set(storedFiles(at: directory).keys) == Set(keys.dropFirst().compactMap { DiskCache.filename(for: $0) }))
        #expect(cache.totalSize == 800)
    }

    @Test func directoryHoldsExactlyOneFilePerKey() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let keys = ["a", "b", "c"]
        do {
            let cache = try makeCache(at: directory)
            cache.ageLimit = 24 * 60 * 60
            for key in keys {
                cache.storeData(Data(repeating: 1, count: 50), for: key)
                cache.storeData(Data(repeating: 2, count: 60), for: key)
            }
            cache.flush()
            try setModificationDate(Date(timeIntervalSinceNow: -2 * 60 * 60), #require(cache.url(for: "a")))
            #expect(cache.cachedData(for: "a") != nil)
            cache.sweep()
        }
        let reopened = try makeCache(at: directory)
        #expect(reopened.totalCount == keys.count)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(names) == Set(keys.compactMap { DiskCache.filename(for: $0) }))
    }

    @Test func writtenFilesUseCompleteUntilFirstUserAuthenticationProtection() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let cache = try makeCache(at: directory)
        cache.storeData(Data([1, 2, 3]), for: "a")
        cache.flush()
        let file = try FileManager.default.attributesOfItem(atPath: #require(cache.url(for: "a")).path)
        let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect(DiskCacheFile.writeOptions.contains(.completeFileProtectionUntilFirstUserAuthentication))
        #expect(DiskCacheFile.protection == .completeUntilFirstUserAuthentication)
        let recorded = [file[.protectionKey], folder[.protectionKey]].compactMap { $0 as? FileProtectionType }
        #expect(recorded.allSatisfy { $0 == .completeUntilFirstUserAuthentication })
    }

    @Test func releasingCacheWithStagedRemoveAllNeverResurrects() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let gate = DispatchSemaphore(value: 0)
        let queue = try stageRemoveAllAndRelease(directory: directory, gate: gate)
        #expect(storedFiles(at: directory).count == 20)
        gate.signal()

        let reopened = try makeCache(at: directory)
        #expect(reopened.queue === queue)
        #expect(reopened.totalCount == 1)
        #expect(reopened.cachedData(for: "after") == Data([1, 2]))
        #expect((0..<20).filter { reopened.cachedData(for: "before-\($0)") != nil }.isEmpty)
        #expect(reopened.cachedData(for: "staged-before") == nil)
        #expect(Set(storedFiles(at: directory).keys) == Set([DiskCache.filename(for: "after")].compactMap { $0 }))
    }

    private func stageRemoveAllAndRelease(directory: URL, gate: DispatchSemaphore) throws -> DispatchQueue {
        let cache = try makeCache(at: directory)
        for index in 0..<20 {
            cache.storeData(Data(repeating: 1, count: 100), for: "before-\(index)")
        }
        cache.flush()
        cache.flushInterval = 3600
        cache.queue.async {
            _ = gate.wait(timeout: .now() + 30)
        }
        cache.storeData(Data([9]), for: "staged-before")
        cache.removeAll()
        cache.storeData(Data([1, 2]), for: "after")
        return cache.queue
    }

    @Test func reopenedCacheHonorsReleasedRemoveAllBeforeItIsApplied() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        _ = try stageRemoveAllAndRelease(directory: directory, gate: gate)

        let reopened = try makeCache(at: directory)
        #expect((0..<20).filter { reopened.cachedData(for: "before-\($0)") != nil }.isEmpty)
        #expect((0..<20).filter { reopened.containsData(for: "before-\($0)") }.isEmpty)
        #expect(reopened.cachedData(for: "staged-before") == nil)
        #expect(!reopened.containsData(for: "staged-before"))
        #expect(reopened.cachedData(for: "after") == Data([1, 2]))
        #expect(reopened.containsData(for: "after"))
        #expect(storedFiles(at: directory).count == 20)

        gate.signal()
        #expect(reopened.totalCount == 1)
        #expect((0..<20).filter { reopened.cachedData(for: "before-\($0)") != nil }.isEmpty)
        #expect(reopened.cachedData(for: "after") == Data([1, 2]))
        #expect(Set(storedFiles(at: directory).keys) == Set([DiskCache.filename(for: "after")].compactMap { $0 }))
    }

    @Test func reopenedCacheSeesReleasedWritesAndRemovalsBeforeTheyAreApplied() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        try stageChangesAndRelease(directory: directory, gate: gate)

        let reopened = try makeCache(at: directory)
        #expect(reopened.cachedData(for: "removed") == nil)
        #expect(!reopened.containsData(for: "removed"))
        #expect(reopened.cachedData(for: "replaced") == Data([2]))
        #expect(reopened.cachedData(for: "added") == Data([3]))
        #expect(reopened.containsData(for: "added"))
        #expect(reopened.cachedData(for: "kept") == Data([4]))

        reopened.storeData(Data([5]), for: "added")
        #expect(reopened.cachedData(for: "added") == Data([5]))

        gate.signal()
        reopened.flush()
        #expect(reopened.cachedData(for: "removed") == nil)
        #expect(reopened.cachedData(for: "replaced") == Data([2]))
        #expect(reopened.cachedData(for: "added") == Data([5]))
        #expect(reopened.totalCount == 3)
    }

    private func stageChangesAndRelease(directory: URL, gate: DispatchSemaphore) throws {
        let cache = try makeCache(at: directory)
        cache.storeData(Data([0]), for: "removed")
        cache.storeData(Data([1]), for: "replaced")
        cache.storeData(Data([4]), for: "kept")
        cache.flush()
        cache.flushInterval = 3600
        cache.queue.async {
            _ = gate.wait(timeout: .now() + 30)
        }
        cache.removeData(for: "removed")
        cache.storeData(Data([2]), for: "replaced")
        cache.storeData(Data([3]), for: "added")
    }

    @Test func failedRemoveAllKeepsEarlierWritesInvisibleAndRetries() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let cache = try makeCache(at: directory)
        let diagnostics = recordDiagnostics(of: cache)
        cache.storeData(Data([1, 2, 3]), for: "secret")
        cache.flush()
        chmod(directory.path, 0o300)

        cache.removeAll()
        cache.storeData(Data([7]), for: "after")
        cache.flush()

        #expect(failureOperations(diagnostics.value).contains(.remove))
        #expect(fileExists(cache, "secret"))
        #expect(cache.cachedData(for: "secret") == nil)
        #expect(!cache.containsData(for: "secret"))
        #expect(cache.cachedData(for: "after") == Data([7]))
        #expect(cache.totalCount == 1)

        chmod(directory.path, 0o755)
        #expect(cache.cachedData(for: "secret") == nil)
        cache.flush()
        #expect(!fileExists(cache, "secret"))
        #expect(cache.cachedData(for: "secret") == nil)
        #expect(cache.cachedData(for: "after") == Data([7]))
        #expect(cache.totalCount == 1)
        #expect(cache.totalSize == 1)
    }

    @Test func failedRemoveAllStaysInvisibleToReopenedCache() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        try failRemoveAllAndRelease(directory: directory)

        let reopened = try makeCache(at: directory)
        let diagnostics = recordDiagnostics(of: reopened)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(try #require(DiskCache.filename(for: "secret"))).path))
        #expect(reopened.cachedData(for: "secret") == nil)
        #expect(!reopened.containsData(for: "secret"))
        #expect(reopened.cachedData(for: "after") == Data([7]))
        #expect(reopened.containsData(for: "after"))
        reopened.flush()
        #expect(failureOperations(diagnostics.value).contains(.remove))
        #expect(reopened.cachedData(for: "secret") == nil)

        chmod(directory.path, 0o755)
        reopened.flush()
        #expect(!fileExists(reopened, "secret"))
        #expect(reopened.cachedData(for: "secret") == nil)
        #expect(reopened.cachedData(for: "after") == Data([7]))
        #expect(reopened.totalCount == 1)
        #expect(Set(storedFiles(at: directory).keys) == Set([DiskCache.filename(for: "after")].compactMap { $0 }))
    }

    private func failRemoveAllAndRelease(directory: URL) throws {
        let cache = try makeCache(at: directory)
        cache.storeData(Data([1, 2, 3]), for: "secret")
        cache.flush()
        chmod(directory.path, 0o300)
        cache.removeAll()
        cache.storeData(Data([7]), for: "after")
        cache.flush()
    }

    @Test func indexEvictsInLeastRecentlyUsedOrderAfterTouchAndOverwrite() {
        var index = DiskCache.Index()
        index.set("a", size: 10, accessTime: 0)
        index.set("b", size: 10, accessTime: 0)
        index.set("c", size: 10, accessTime: 0)
        index.touch("a", at: 1)
        index.set("d", size: 10, accessTime: 1)
        index.set("b", size: 10, accessTime: 2)
        #expect(index.leastRecentlyUsedNames == ["c", "a", "d", "b"])

        let victims = index.removeLeastRecentlyUsed(untilSizeAtMost: 20, limit: .max)

        #expect(victims == ["c", "a"])
        #expect(Set(index.entries.keys) == ["d", "b"])
        #expect(index.totalSize == 20)
    }

    @Test func indexEvictionStopsAtBatchLimit() {
        var index = DiskCache.Index()
        for number in 0..<10 {
            index.set("key.\(number)", size: 1, accessTime: 0)
        }
        #expect(index.removeLeastRecentlyUsed(untilSizeAtMost: 0, limit: 3) == ["key.0", "key.1", "key.2"])
        #expect(index.removeLeastRecentlyUsed(untilSizeAtMost: 0, limit: 3) == ["key.3", "key.4", "key.5"])
        #expect(index.removeLeastRecentlyUsed(untilSizeAtMost: 5, limit: 3) == [])
        #expect(index.entries.count == 4)
        #expect(index.totalSize == 4)
    }

    @Test func indexMatchesReferenceRecencyModelUnderRandomOperations() {
        var generator = SeededGenerator(seed: 36671)
        var index = DiskCache.Index()
        var model: [(name: String, size: Int)] = []
        for _ in 0..<20000 {
            let name = "key.\(Int.random(in: 0 ..< 64, using: &generator))"
            switch Int.random(in: 0..<100, using: &generator) {
            case 0..<45:
                let size = Int.random(in: 1...9, using: &generator)
                index.set(name, size: size, accessTime: 0)
                model.removeAll { $0.name == name }
                model.append((name, size))
            case 45..<75:
                index.touch(name, at: 0)
                if let position = model.firstIndex(where: { $0.name == name }) {
                    model.append(model.remove(at: position))
                }
            case 75..<90:
                index.remove(name)
                model.removeAll { $0.name == name }
            default:
                let target = Int.random(in: 0...200, using: &generator)
                let limit = Int.random(in: 1...8, using: &generator)
                var expected: [String] = []
                var size = model.reduce(0) { $0 + $1.size }
                while size > target, expected.count < limit, let first = model.first {
                    model.removeFirst()
                    size -= first.size
                    expected.append(first.name)
                }
                #expect(index.removeLeastRecentlyUsed(untilSizeAtMost: target, limit: limit) == expected)
            }
            #expect(index.leastRecentlyUsedNames == model.map(\.name))
            #expect(index.totalSize == model.reduce(0) { $0 + $1.size })
            #expect(index.entries.count == model.count)
        }
    }

    @Test func evictionAcrossSeveralBatchesKeepsMostRecentEntries() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let cache = try makeCache(at: directory)
        cache.flushInterval = 3600
        let total = DiskCache.evictionBatchSize * 2 + 100
        for number in 0..<total {
            cache.storeData(Data([1]), for: "key.\(number)")
        }
        cache.flush()
        #expect(cache.totalCount == total)

        cache.sizeLimit = 100
        cache.storeData(Data([2]), for: "key.\(total)")
        cache.flush()

        #expect(cache.totalCount == 90)
        #expect(cache.totalSize == 90)
        #expect(storedFiles(at: directory).count == 90)
        let survivors = ((total + 1 - 90)...total).compactMap { DiskCache.filename(for: "key.\($0)") }
        #expect(Set(storedFiles(at: directory).keys) == Set(survivors))
    }

    @Test func evictionContinuesPastSizeLimitUntilTargetAfterFullBatch() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let cache = try makeCache(at: directory)
        cache.flushInterval = 3600
        let sizeLimit = 300
        let target = Int(Double(sizeLimit) * DiskCache.evictionTargetRatio)
        let total = sizeLimit + DiskCache.evictionBatchSize
        for number in 0..<total - 1 {
            cache.storeData(Data([1]), for: "key.\(number)")
        }
        cache.flush()
        #expect(cache.totalCount == total - 1)

        cache.sizeLimit = sizeLimit
        cache.storeData(Data([2]), for: "key.\(total - 1)")
        cache.flush()

        #expect(cache.totalCount == target)
        #expect(cache.totalSize == target)
        let survivors = ((total - target)..<total).compactMap { DiskCache.filename(for: "key.\($0)") }
        #expect(Set(storedFiles(at: directory).keys) == Set(survivors))
    }

    @Test func diagnosticsReachEveryInstalledHandler() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let cache = try makeCache(at: directory)
        let first = recordDiagnostics(of: cache)
        let second = recordDiagnostics(of: cache)
        cache.maximumEntrySize = 1
        cache.storeData(Data(count: 2), for: "a")
        #expect(failureOperations(first.value) == [.write])
        #expect(failureOperations(second.value) == [.write])
    }

    @Test func releasingCacheWithStagedWritesPersistsThem() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        do {
            let cache = try makeCache(at: directory)
            cache.flushInterval = 3600
            cache.storeData(Data([1, 2, 3]), for: "a")
            cache.storeData(Data([4]), for: "b")
            cache.removeData(for: "b")
        }
        let reopened = try makeCache(at: directory)
        #expect(reopened.totalCount == 1)
        #expect(reopened.cachedData(for: "a") == Data([1, 2, 3]))
        #expect(reopened.cachedData(for: "b") == nil)
    }

    @Test func indexIsBuiltOutsideTheStateLockAndKeepsTouchesMadeMeanwhile() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let urls = try writeThreeEntries(directory: directory)
        try setModificationDate(Date(timeIntervalSinceNow: -300), urls[0])
        try setModificationDate(Date(timeIntervalSinceNow: -200), urls[1])
        try setModificationDate(Date(timeIntervalSinceNow: -100), urls[2])
        let scanned = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let cache = try DiskCache(
            path: directory,
            filenameGenerator: DiskCache.filename(for:),
            clock: DiskCache.wallClock,
            notificationCenter: NotificationCenter(),
            indexScanHook: {
                scanned.signal()
                _ = resume.wait(timeout: .now() + 30)
            }
        )
        cache.sizeLimit = 1000
        let counted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = cache.totalCount
            counted.signal()
        }
        #expect(scanned.wait(timeout: .now() + 30) == .success)

        let observed = Box<(read: Bool, contains: Bool)?>(nil)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let read = cache.cachedData(for: "a") != nil
            cache.storeData(Data(repeating: 2, count: 300), for: "d")
            observed.value = (read, cache.containsData(for: "d"))
            finished.signal()
        }
        let finishedDuringScan = finished.wait(timeout: .now() + 10) == .success
        resume.signal()
        #expect(finishedDuringScan)
        #expect(observed.value?.read == true)
        #expect(observed.value?.contains == true)
        #expect(counted.wait(timeout: .now() + 30) == .success)

        cache.flush()
        #expect(!fileExists(cache, "b"))
        #expect(fileExists(cache, "a"))
        #expect(fileExists(cache, "c"))
        #expect(fileExists(cache, "d"))
        #expect(cache.totalSize == 900)
    }

    @Test func failedDirectoryListingReportsInitializeAndRetriesLater() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        do {
            let writer = try makeCache(at: directory)
            writer.storeData(Data([1, 2, 3]), for: "a")
            writer.flush()
        }
        let cache = try makeCache(at: directory)
        let diagnostics = recordDiagnostics(of: cache)
        chmod(directory.path, 0o300)

        #expect(cache.totalCount == 0)
        #expect(failureOperations(diagnostics.value).contains(.initialize))
        #expect(cache.cachedData(for: "a") == Data([1, 2, 3]))
        #expect(cache.containsData(for: "a"))

        chmod(directory.path, 0o755)
        #expect(cache.totalCount == 1)
        #expect(cache.totalSize == 3)
    }

    @Test func sweepRemovalFailureReportsSweepDiagnostic() throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let urls = try writeThreeEntries(directory: directory)
        try setModificationDate(Date(timeIntervalSinceNow: -10 * 24 * 60 * 60), urls[0])
        let cache = try makeCache(at: directory)
        let diagnostics = recordDiagnostics(of: cache)
        cache.ageLimit = 24 * 60 * 60
        #expect(cache.totalCount == 3)
        chmod(directory.path, 0o555)
        defer { chmod(directory.path, 0o755) }

        cache.sweep()

        #expect(failureOperations(diagnostics.value) == [.sweep])
        #expect(cache.cachedData(for: "b") != nil)
    }
}

private final class DiskCacheWeakSession: @unchecked Sendable {
    weak var value: ImageSession?
}

@Suite struct DiskCacheSessionFaultTests {
    private func makeFaultSession(cache: DiskCache) -> (ImageSession, MockDataLoader, RecordingDelegate) {
        let loader = MockDataLoader(defaultResponse: .data(Fixtures.pngData))
        let delegate = RecordingDelegate()
        let session = makeSession(loader: loader, delegate: delegate) { $0.diskCache = cache }
        return (session, loader, delegate)
    }

    private func hasFailure(_ delegate: RecordingDelegate, _ operation: ImageSession.DiskCacheOperation) -> Bool {
        failureOperations(delegate.diagnostics.value).contains(operation)
    }

    @Test func loadSucceedsFromNetworkWhenDiskReadFails() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let cache = try makeCache(at: directory)
        let (session, loader, delegate) = makeFaultSession(cache: cache)
        let request = ImageRequest(url: Fixtures.url)
        let key = session.cache.makeDiskCacheKey(for: request)
        cache.storeData(Fixtures.pngData, for: key)
        cache.flush()
        let path = try #require(cache.url(for: key)).path
        chmod(path, 0)
        defer { chmod(path, 0o644) }

        let image = try await session.image(for: request)

        #expect(image.size.width > 0)
        #expect(loader.counts.started == 1)
        #expect(await waitUntil(timeout: 30) { hasFailure(delegate, .read) })
    }

    @Test func diagnosticsReachLaterSessionAfterEarlierSessionIsReleased() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let cache = try makeCache(at: directory)
        let earlier = DiskCacheWeakSession()
        do {
            earlier.value = makeSession(loader: MockDataLoader(defaultResponse: .data(Fixtures.pngData))) { $0.diskCache = cache }
        }
        #expect(await waitUntil(timeout: 30) { earlier.value == nil })
        let (session, loader, delegate) = makeFaultSession(cache: cache)
        let request = ImageRequest(url: Fixtures.url)
        let key = session.cache.makeDiskCacheKey(for: request)
        cache.storeData(Fixtures.pngData, for: key)
        cache.flush()
        let path = try #require(cache.url(for: key)).path
        chmod(path, 0)
        defer { chmod(path, 0o644) }

        let image = try await session.image(for: request)

        #expect(image.size.width > 0)
        #expect(loader.counts.started == 1)
        #expect(await waitUntil(timeout: 30) { hasFailure(delegate, .read) })
    }

    @Test func loadSucceedsWhenDiskWriteFails() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let cache = try makeCache(at: directory)
        cache.flushInterval = 3600
        let (session, loader, delegate) = makeFaultSession(cache: cache)
        let request = ImageRequest(url: Fixtures.url)
        let key = session.cache.makeDiskCacheKey(for: request)
        chmod(directory.path, 0o555)
        defer { chmod(directory.path, 0o755) }

        let image = try await session.image(for: request)
        #expect(image.size.width > 0)
        #expect(loader.counts.started == 1)
        #expect(await waitUntil(timeout: 30) { cache.containsData(for: key) })
        cache.flush()

        #expect(!cache.containsData(for: key))
        #expect(await waitUntil(timeout: 30) { hasFailure(delegate, .write) })
    }

    @Test func loadSucceedsAndCacheRecoversWhenDirectoryIsRemoved() async throws {
        let directory = makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let cache = try makeCache(at: directory)
        cache.flushInterval = 3600
        let (session, loader, delegate) = makeFaultSession(cache: cache)
        let request = ImageRequest(url: Fixtures.url)
        let key = session.cache.makeDiskCacheKey(for: request)
        try FileManager.default.removeItem(at: directory)

        let image = try await session.image(for: request)
        #expect(image.size.width > 0)
        #expect(loader.counts.started == 1)
        #expect(await waitUntil(timeout: 30) { cache.containsData(for: key) })
        cache.flush()

        #expect(fileExists(cache, key))
        #expect(cache.cachedData(for: key) == Fixtures.pngData)
        #expect(await waitUntil(timeout: 30) { hasFailure(delegate, .write) })

        let second = makeSession(loader: loader) { $0.diskCache = cache }
        let reloaded = try await second.image(for: request)
        #expect(reloaded.size.width > 0)
        #expect(loader.counts.started == 1)
    }
}

private struct DiskCacheTestClock: SessionClock {
    let time: Box<TimeInterval>

    var now: Date {
        Date(timeIntervalSinceReferenceDate: time.value)
    }

    var monotonicIncludingSleep: TimeInterval {
        time.value
    }
}
