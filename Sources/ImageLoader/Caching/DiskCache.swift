import Foundation

/// 데이터를 파일로 보관하는 디스크 캐시입니다.
///
/// 쓴 데이터는 메모리에 모아 두었다가 1초 뒤에 한꺼번에 파일로 씁니다. 파일로 쓰기 전에도 바로 읽을 수 있습니다.
/// 전체 크기가 ``sizeLimit``를 넘으면 오래 읽지 않은 파일부터 지워 한도의 90%까지 줄입니다.
/// 앱이 백그라운드로 가면 남은 데이터를 파일로 쓰고 오래된 파일을 정리합니다.
///
/// 한 프로세스에서 같은 폴더를 쓰는 인스턴스는 하나만 만들 수 있습니다.
public final class DiskCache: DiskCaching, @unchecked Sendable {
    /// 키를 파일 이름으로 바꾸는 함수입니다. `nil`을 돌려주면 그 키는 저장하지 않습니다.
    public typealias FilenameGenerator = @Sendable (String) -> String?

    /// 디스크 캐시를 만들지 못한 이유입니다.
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        /// 같은 프로세스의 다른 ``DiskCache``가 이미 이 폴더를 쓰고 있습니다. 같은 폴더를 쓰려면 기존 인스턴스를 함께 써 주세요.
        case pathInUse(URL)

        public var description: String {
            switch self {
            case .pathInUse(let url):
                return "Another DiskCache instance is already using \(url.path)"
            }
        }
    }

    struct EntryTooLargeError: Swift.Error, Equatable, CustomStringConvertible {
        let size: Int
        let limit: Int

        var description: String {
            "Data of \(size) bytes exceeds maximumEntrySize of \(limit) bytes"
        }
    }

    /// 캐시 파일을 두는 폴더입니다.
    public let path: URL

    /// 파일을 읽고 쓰는 직렬 큐입니다. 같은 폴더를 쓰는 작업은 모두 이 큐에서 차례로 일어납니다.
    public let queue: DispatchQueue

    /// 캐시 파일 크기 합계의 한도입니다. 기본값은 150MB입니다.
    public var sizeLimit: Int {
        get { state.withLock { $0.settings.sizeLimit } }
        set { state.withLock { $0.settings.sizeLimit = max(0, newValue) } }
    }

    /// 마지막으로 읽은 뒤 이 초가 지난 파일은 정리할 때 지웁니다. 기본값은 `nil`이고, 시간으로는 지우지 않습니다.
    public var ageLimit: TimeInterval? {
        get { state.withLock { $0.settings.ageLimit } }
        set { state.withLock { $0.settings.ageLimit = newValue.map { max(0, $0) } } }
    }

    /// 오래된 파일을 정리하는 간격입니다. 기본값은 1,800초(30분)입니다.
    public var sweepInterval: TimeInterval {
        get { state.withLock { $0.settings.sweepInterval } }
        set { state.withLock { $0.settings.sweepInterval = newValue } }
    }

    /// 정해진 간격과 앱이 백그라운드로 갈 때 오래된 파일을 정리할지 정합니다. 기본값은 `true`입니다.
    public var isSweepEnabled: Bool {
        get { state.withLock { $0.settings.isSweepEnabled } }
        set { state.withLock { $0.settings.isSweepEnabled = newValue } }
    }

    /// 정리할 때 크기가 한도를 넘었으면 이 비율까지 줄입니다. 기본값은 0.7이고, ``sizeLimit``의 70%까지 줄입니다.
    public var trimRatio: Double {
        get { state.withLock { $0.settings.trimRatio } }
        set { state.withLock { $0.settings.trimRatio = newValue } }
    }

    /// 쓴 데이터를 파일로 옮기기까지 기다리는 초입니다. 기본값은 1초입니다.
    public var flushInterval: TimeInterval {
        get { state.withLock { $0.settings.flushInterval } }
        set { state.withLock { $0.settings.flushInterval = newValue } }
    }

    /// 파일 하나의 최대 바이트 수입니다. 넘는 데이터는 저장하지 않고 ``ImageSession/Diagnostic/diskCacheFailure(operation:error:)``로 알립니다. 기본값은 `nil`이고, 제한하지 않습니다.
    public var maximumEntrySize: Int? {
        get { state.withLock { $0.settings.maximumEntrySize } }
        set { state.withLock { $0.settings.maximumEntrySize = newValue } }
    }

    /// 파일로 쓰기 전에 메모리에 모아 둘 수 있는 최대 바이트 수입니다. 기본값은 32MB이고, 넘으면 ``flushInterval``을 기다리지 않고 바로 씁니다.
    public var maximumStagedBytes: Int {
        get { state.withLock { $0.settings.maximumStagedBytes } }
        set { state.withLock { $0.settings.maximumStagedBytes = max(0, newValue) } }
    }

    let filenameGenerator: FilenameGenerator
    let clock: any SessionClock
    let directoryPath: String
    let registryKey: String
    let state = LockIsolated(State())
    let indexScanHook: (@Sendable () -> Void)?
    let pathQueue: PathQueue
    let notificationCenter: NotificationCenter
    let observers = LockIsolated<[any NSObjectProtocol]>([])
    private let diagnosticHandlers = LockIsolated<[@Sendable (ImageSession.Diagnostic) -> Void]>([])

    static let pendingTouchLimit = 4096
    static let wallClock: any SessionClock = SystemClock()

    /// 캐시 폴더 아래에 이름을 붙인 폴더로 캐시를 만듭니다.
    ///
    /// - Parameters:
    ///   - name: 캐시 폴더 이름입니다.
    ///   - filenameGenerator: 키를 파일 이름으로 바꾸는 함수입니다. 기본값은 키의 SHA-256 값을 16진수로 씁니다.
    /// - Throws: 같은 폴더를 다른 인스턴스가 쓰고 있으면 ``Error/pathInUse(_:)``를, 폴더를 만들지 못하면 파일 시스템 오류를 일으킵니다.
    public convenience init(name: String, filenameGenerator: @escaping FilenameGenerator = DiskCache.filename(for:)) throws {
        try self.init(path: DiskCache.directory(named: name), filenameGenerator: filenameGenerator)
    }

    /// 정한 폴더로 캐시를 만듭니다. 폴더가 없으면 만듭니다.
    ///
    /// - Parameters:
    ///   - path: 캐시 파일을 둘 폴더입니다.
    ///   - filenameGenerator: 키를 파일 이름으로 바꾸는 함수입니다. 기본값은 키의 SHA-256 값을 16진수로 씁니다.
    /// - Throws: 같은 폴더를 다른 인스턴스가 쓰고 있으면 ``Error/pathInUse(_:)``를, 폴더를 만들지 못하면 파일 시스템 오류를 일으킵니다.
    public convenience init(path: URL, filenameGenerator: @escaping FilenameGenerator = DiskCache.filename(for:)) throws {
        try self.init(path: path, filenameGenerator: filenameGenerator, clock: DiskCache.wallClock, notificationCenter: .default)
    }

    init(
        path: URL,
        filenameGenerator: @escaping FilenameGenerator,
        clock: any SessionClock,
        notificationCenter: NotificationCenter,
        indexScanHook: (@Sendable () -> Void)? = nil,
        sizeLimit: Int? = nil
    ) throws {
        try DiskCacheFile.createDirectory(atPath: path.path)
        self.path = path
        self.filenameGenerator = filenameGenerator
        self.clock = clock
        self.notificationCenter = notificationCenter
        self.indexScanHook = indexScanHook
        directoryPath = path.path
        registryKey = DiskCache.registryKey(for: path)
        pathQueue = DiskCache.pathQueue(forRegistryKey: registryKey)
        queue = pathQueue.queue
        if let sizeLimit {
            state.withLock { $0.settings.sizeLimit = max(0, sizeLimit) }
        }
        try DiskCache.register(self)
        installObservers()
    }

    deinit {
        for observer in observers.value {
            notificationCenter.removeObserver(observer)
        }
        let staging = state.withLock { $0.staging }
        if !staging.isEmpty {
            let directoryPath = directoryPath
            let pathQueue = pathQueue
            let handlers = diagnosticHandlers.value
            let releaseId = pathQueue.beginRelease(staging)
            queue.async {
                var failures = Failures()
                _ = DiskCache.apply(staging, directoryPath: directoryPath, pathState: pathQueue.state, failures: &failures)
                pathQueue.endRelease(releaseId)
                for item in failures.items {
                    for handler in handlers {
                        handler(.diskCacheFailure(operation: item.operation, error: item.error))
                    }
                }
            }
        }
        DiskCache.unregister(self)
    }

    /// 데이터를 저장합니다. 메모리에 먼저 두고 ``flushInterval`` 뒤에 파일로 씁니다.
    public func storeData(_ data: Data, for key: String) {
        guard let name = filename(for: key) else { return }
        let (schedule, rejection) = access { state -> (FlushSchedule, EntryTooLargeError?) in
            if let limit = state.settings.maximumEntrySize, data.count > limit {
                state.staging.remove(name)
                return (state.scheduleFlush(isUrgent: false), EntryTooLargeError(size: data.count, limit: limit))
            }
            state.staging.add(data, for: name)
            return (state.scheduleFlush(isUrgent: false), nil)
        }
        perform(schedule)
        if let rejection {
            report(.write, rejection)
        }
    }

    /// 키의 데이터를 지웁니다. 파일은 ``flushInterval`` 뒤에 지웁니다.
    public func removeData(for key: String) {
        guard let name = filename(for: key) else { return }
        let schedule = access { state -> FlushSchedule in
            state.staging.remove(name)
            return state.scheduleFlush(isUrgent: false)
        }
        perform(schedule)
    }

    /// 모든 데이터를 지웁니다. 파일은 기다리지 않고 바로 지웁니다.
    public func removeAll() {
        let schedule = access { state -> FlushSchedule in
            state.staging.removeAll()
            return state.scheduleFlush(isUrgent: true)
        }
        perform(schedule)
    }

    /// 메모리에 모아 둔 데이터를 모두 파일로 씁니다. 다 쓸 때까지 기다립니다.
    public func flush() {
        performOnQueue {
            performFlush(.manual)
        }
    }

    /// 키 하나의 데이터만 파일로 씁니다. 다 쓸 때까지 기다립니다. ``url(for:)``로 파일을 바로 읽어야 할 때 먼저 불러 주세요.
    public func flush(for key: String) {
        guard let name = filename(for: key) else { return }
        performOnQueue {
            performFlush(.manual, name: name)
        }
    }

    /// 오래된 파일과 한도를 넘은 파일을 지금 정리합니다. 다 정리할 때까지 기다립니다.
    public func sweep() {
        performOnQueue {
            performSweep()
        }
    }

    /// 저장한 항목 수입니다. 처음 부르면 폴더를 훑어야 해서 오래 걸릴 수 있습니다.
    public var totalCount: Int {
        totals().count
    }

    /// 저장한 데이터의 바이트 수 합계입니다. 처음 부르면 폴더를 훑어야 해서 오래 걸릴 수 있습니다.
    public var totalSize: Int {
        totals().size
    }

    /// 캐시 파일이 디스크에서 실제로 차지하는 바이트 수입니다. 파일 시스템 블록 단위로 올림하므로 ``totalSize``보다 큽니다.
    public var totalAllocatedSize: Int {
        DiskCacheFile.allocatedSize(directoryPath: directoryPath)
    }

    func installDiagnosticHandlerIfNeeded(_ handler: @escaping @Sendable (ImageSession.Diagnostic) -> Void) {
        diagnosticHandlers.withLock { $0.append(handler) }
    }

    func raiseSizeLimit(to newValue: Int) {
        state.withLock { $0.settings.sizeLimit = max($0.settings.sizeLimit, newValue) }
    }

    func filePath(for name: String) -> String {
        DiskCacheFile.path(directoryPath, name)
    }

    func report(_ operation: ImageSession.DiskCacheOperation, _ error: any Swift.Error) {
        var failures = Failures()
        failures.record(operation, error)
        report(failures)
    }

    func report(_ failures: Failures) {
        guard !failures.isEmpty else { return }
        let handlers = diagnosticHandlers.value
        for item in failures.items {
            for handler in handlers {
                handler(.diskCacheFailure(operation: item.operation, error: item.error))
            }
        }
    }

    func performOnQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: pathQueue.key) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    func assertOnQueue() {
        #if DEBUG
            dispatchPrecondition(condition: .onQueue(queue))
        #endif
    }

    func access<T>(_ body: (inout State) -> T) -> T {
        let (result, isFirstUse) = state.withLock { state -> (T, Bool) in
            let isFirstUse = !state.isActivated
            state.isActivated = true
            return (body(&state), isFirstUse)
        }
        if isFirstUse {
            scheduleSweep()
        }
        return result
    }

    private func perform(_ schedule: FlushSchedule) {
        switch schedule {
        case .none:
            break
        case .immediate:
            queue.async { [weak self] in
                self?.performFlush(.immediate)
            }
        case .delayed(let interval):
            queue.asyncAfter(deadline: SystemClock.dispatchDeadline(after: DiskCache.dispatchInterval(interval))) { [weak self] in
                self?.performFlush(.timer)
            }
        }
    }

    private func totals() -> (count: Int, size: Int) {
        if state.withLock({ $0.index == nil }) {
            performOnQueue {
                var failures = Failures()
                loadIndexIfNeeded(&failures)
                report(failures)
            }
        }
        return state.withLock { $0.totals() }
    }

    static func dispatchInterval(_ interval: TimeInterval) -> DispatchTimeInterval {
        guard interval.isFinite, interval > 0 else { return .nanoseconds(0) }
        return .milliseconds(Int(min(interval, 365 * 24 * 60 * 60) * 1000))
    }
}
