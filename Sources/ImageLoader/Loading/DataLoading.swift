import Foundation

/// 이미지 데이터를 내려받는 객체가 따르는 프로토콜입니다. 기본 구현은 ``DataLoader``입니다.
///
/// `URLSession`이 아닌 네트워크 라이브러리를 쓰거나 테스트에서 응답을 흉내 낼 때 구현합니다.
public protocol DataLoading: Sendable {
    /// 데이터를 내려받기 시작합니다.
    ///
    /// - Parameters:
    ///   - request: 보낼 요청입니다. ``ImageSession/Delegate/willLoadData(for:urlRequest:session:)``를 거친 값입니다.
    ///   - didReceiveData: 데이터 조각을 받을 때마다 받은 조각과 응답을 넘겨 부릅니다. 받은 순서대로 불러 주세요.
    ///   - completion: 다운로드가 끝나면 한 번 부릅니다. 실패했으면 오류를, 성공했으면 `nil`을 넘깁니다.
    /// - Returns: 다운로드를 취소할 때 쓰는 값입니다. 취소한 뒤에는 `completion`을 부르지 않아도 됩니다.
    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable
}

/// 끝나지 않은 작업을 취소할 수 있는 값입니다.
public protocol Cancellable: Sendable {
    /// 작업을 취소합니다. 이미 끝났거나 취소한 작업에서 불러도 됩니다.
    func cancel()
}

struct AnonymousCancellable: Cancellable {
    let onCancel: @Sendable () -> Void

    func cancel() {
        onCancel()
    }
}
