import Foundation

struct Photo: Identifiable, Hashable, Decodable, Sendable {
    let id: String
    let author: String
    let width: Int
    let height: Int

    var originalURL: URL {
        URL(string: "https://picsum.photos/id/\(id)/\(width)/\(height)")!
    }

    func thumbnailURL(pixelSize: Int) -> URL {
        let height = max(1, pixelSize * self.height / max(1, width))
        return URL(string: "https://picsum.photos/id/\(id)/\(pixelSize)/\(height)")!
    }
}

enum PhotoCatalog {
    static func load(page: Int, limit: Int = 100) async throws -> [Photo] {
        let url = URL(string: "https://picsum.photos/v2/list?page=\(page)&limit=\(limit)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([Photo].self, from: data)
    }
}
