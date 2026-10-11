import Foundation

extension FetchDataStage {
    func loadLocalResource(_ url: URL) {
        isLocalResource = true
        let limit = session.configuration.maximumResponseDataSize
        perform(
            on: session.diskCacheReadingQueue, worker: SessionWorkers.io,
            work: {
                Self.readLocalResource(url, limit: limit)
            },
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let data):
                    guard !data.isEmpty else {
                        self.send(error: .dataIsEmpty)
                        return
                    }
                    self.send(value: (data, nil), isCompleted: true)
                case .failure(let error):
                    self.send(error: error)
                }
            })
    }

    static func readLocalResource(_ url: URL, limit: Int?) -> Result<Data, ImageSession.Error> {
        do {
            let url = url.isFileURL ? url.resolvingSymlinksInPath() : url
            if url.isFileURL {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else {
                    return .failure(.dataLoadingFailed(error: URLError(.cannotOpenFile)))
                }
                if let limit, let size = values.fileSize, size > limit {
                    return .failure(.dataDownloadExceededMaximumSize)
                }
            }
            let data = try Data(contentsOf: url)
            if let limit, data.count > limit {
                return .failure(.dataDownloadExceededMaximumSize)
            }
            return .success(data)
        } catch {
            return .failure(.dataLoadingFailed(error: error))
        }
    }
}

extension URL {
    var isLocalResource: Bool {
        scheme == "file" || scheme == "data"
    }
}
