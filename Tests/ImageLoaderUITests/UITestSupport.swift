import Darwin
import Foundation
import ImageIO
import ImageLoaderTesting
@_spi(Testing) @testable import ImageLoaderUI
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import ImageLoader

let uiIsThreadSanitizerEnabled = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") != nil
let uiEnforcesTimingBudgets = ProcessInfo.processInfo.environment["CI"] == nil

enum UIFixtures {
    typealias RGB = (red: UInt8, green: UInt8, blue: UInt8)

    static let red: RGB = (230, 25, 25)
    static let green: RGB = (25, 230, 25)
    static let blue: RGB = (25, 25, 230)

    static func url(_ name: String) -> URL {
        URL(string: "https://example.com/ui/\(name)")!
    }

    static func solid(_ color: RGB, width: Int = 40, height: Int = 40) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(red: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func png(_ color: RGB = red, width: Int = 8, height: Int = 8) -> Data {
        encode(type: .png, frames: [solid(color, width: width, height: height)])
    }

    static func gif(_ colors: [RGB], delay: Double = 0.1, loopCount: Int = 0, width: Int = 40, height: Int = 40) -> Data {
        encode(
            type: .gif,
            frames: colors.map { solid($0, width: width, height: height) },
            containerProperties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]],
            frameProperties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]]
        )
    }

    static func image(_ color: RGB = red) -> UIImage {
        UIImage(cgImage: solid(color, width: 8, height: 8))
    }

    private static func encode(
        type: UTType,
        frames: [CGImage],
        containerProperties: [CFString: Any]? = nil,
        frameProperties: [CFString: Any]? = nil
    ) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, frames.count, nil)!
        if let containerProperties {
            CGImageDestinationSetProperties(destination, containerProperties as CFDictionary)
        }
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, frameProperties.map { $0 as CFDictionary })
        }
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

func makeUISession(loader: MockDataLoader) -> ImageSession {
    var configuration = ImageSession.Configuration(dataLoader: loader)
    configuration.memoryCache = MemoryCache(costLimit: 64 * 1024 * 1024)
    configuration.diskCache = nil
    configuration.isRateLimiterEnabled = false
    return ImageSession(configuration: configuration)
}

func makeUIOptions(_ session: ImageSession, _ configure: (inout ImageLoadingOptions) -> Void = { _ in }) -> ImageLoadingOptions {
    var options = ImageLoadingOptions()
    options.session = session
    configure(&options)
    return options
}

@MainActor
@discardableResult
func uiWaitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}

@MainActor
func uiExpectEventually(
    timeout: TimeInterval = 5,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async {
    let satisfied = await uiWaitUntil(timeout: timeout, condition)
    #expect(satisfied, comment, sourceLocation: sourceLocation)
}

@discardableResult
func uiSpinUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() {
            return true
        }
        usleep(200)
    }
    return condition()
}

func uiDrainSessionQueue() {
    SessionQueue.sync {}
}

@MainActor
func uiDrainMainQueue() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

@MainActor
func uiDrainSessionAndMain() async {
    uiDrainSessionQueue()
    await uiDrainMainQueue()
}

@MainActor
final class UIResultRecorder {
    private(set) var results: [Result<ImageResponse, ImageSession.Error>] = []
    private(set) var progressEvents: [(ImageResponse?, Int64, Int64)] = []

    var count: Int {
        results.count
    }

    var lastResponse: ImageResponse? {
        guard case .success(let response)? = results.last else {
            return nil
        }
        return response
    }

    func record(_ result: Result<ImageResponse, ImageSession.Error>) {
        results.append(result)
    }

    func recordProgress(_ response: ImageResponse?, _ completed: Int64, _ total: Int64) {
        progressEvents.append((response, completed, total))
    }
}

struct UITestFilter: ImageFilter, Hashable {
    let name: String

    func process(_ image: UIImage) -> UIImage? {
        image
    }

    var identifier: String {
        "ui-test/\(name)"
    }
}

final class UIDecodeGate: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var isOpen = false
    private var blockedIndices: [Int] = []

    init() {
        group.enter()
    }

    var blocked: [Int] {
        lock.withLock { blockedIndices }
    }

    func block(_ index: Int) {
        lock.withLock { blockedIndices.append(index) }
        group.wait()
    }

    func open() {
        let shouldLeave = lock.withLock { () -> Bool in
            guard !isOpen else { return false }
            isOpen = true
            return true
        }
        if shouldLeave {
            group.leave()
        }
    }
}

@MainActor
func uiCenterColor(of view: UIView) -> UIFixtures.RGB {
    let width = max(1, Int(view.bounds.width))
    let height = max(1, Int(view.bounds.height))
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    view.layer.render(in: context)
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    let offset = (height / 2) * width * 4 + (width / 2) * 4
    return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
}

func uiColorMatches(_ actual: UIFixtures.RGB, _ expected: UIFixtures.RGB, tolerance: Int = 40) -> Bool {
    abs(Int(actual.red) - Int(expected.red)) <= tolerance
        && abs(Int(actual.green) - Int(expected.green)) <= tolerance
        && abs(Int(actual.blue) - Int(expected.blue)) <= tolerance
}

func uiThreadCPUTimeNanoseconds() -> UInt64 {
    var time = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
    return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
}
