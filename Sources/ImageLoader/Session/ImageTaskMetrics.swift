import Foundation

/// 작업 하나가 끝났을 때의 기록입니다. ``ImageSession/Configuration/isMetricsCollectionEnabled``를 켜면 ``ImageSession/Diagnostic/taskMetrics(_:)``로 받습니다.
public struct ImageTaskMetrics: Sendable {
    /// ``ImageTask/taskId``와 같은 값입니다.
    public let taskId: UInt64
    /// 작업을 시작한 때부터 끝날 때까지 걸린 초입니다. 기기가 잠든 시간도 들어갑니다.
    public let duration: TimeInterval
    /// 이미지를 찾은 캐시입니다. 네트워크에서 받았거나 실패했으면 `nil`입니다.
    public let cacheType: ImageResponse.CacheType?
    /// 실패했을 때의 ``ImageSession/Error/diagnosticCode``입니다. 성공했으면 `nil`입니다.
    public let errorCode: String?
    /// 디코딩 없이 데이터만 받은 작업이면 `true`입니다.
    public let isDataTask: Bool
}
