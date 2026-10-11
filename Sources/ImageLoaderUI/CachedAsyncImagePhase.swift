import Foundation
import SwiftUI

/// ``CachedAsyncImage``가 `content` 클로저에 넘기는 불러오기 상태입니다.
///
/// ``image``가 있으면 성공했거나 미리보기를 받은 상태이고, ``error``가 있으면 실패한 상태입니다. 둘 다 없으면 불러오는 중입니다.
@MainActor
public protocol CachedAsyncImagePhase {
    /// 요청의 결과입니다. 끝나기 전이면 `nil`입니다.
    var result: Result<ImageResponse, Error>? { get }

    /// 지금 보여 줄 이미지와 그 정보입니다.
    var imageContent: ImageContent? { get }

    /// 요청이 끝나지 않았으면 `true`입니다.
    var isLoading: Bool { get }

    /// 다운로드 진행률입니다. 읽으면 진행률이 바뀔 때마다 뷰를 다시 그립니다.
    var progress: AsyncImageModel.Progress { get }
}

extension CachedAsyncImagePhase {
    /// 실패했을 때의 오류입니다. 성공했거나 끝나기 전이면 `nil`입니다.
    public var error: Error? {
        guard case .failure(let error) = result else {
            return nil
        }
        return error
    }

    /// 보여 줄 이미지입니다. 크기를 맞추려면 `resizable()`을 붙여 주세요.
    public var image: Image? {
        imageContent.map { Image(uiImage: $0.image) }
    }

    /// 애니메이션 이미지면 재생하는 뷰를 돌려줍니다. 정지 이미지면 `nil`입니다.
    ///
    /// ```swift
    /// CachedAsyncImage(url: url) { phase in
    ///     if let animated = phase.animatedImage {
    ///         animated
    ///     } else {
    ///         phase.image?.resizable()
    ///     }
    /// }
    /// ```
    public var animatedImage: AnimatedImageRepresentable? {
        guard let imageContent, imageContent.animatedImageSource != nil else {
            return nil
        }
        return AnimatedImageRepresentable(imageContent)
    }
}

extension AsyncImageModel: CachedAsyncImagePhase {}

extension Error {
    /// 오류가 ``ImageSession/Error``면 그 값을, 아니면 `nil`을 돌려줍니다.
    public var imageSessionError: ImageSession.Error? {
        self as? ImageSession.Error
    }
}
