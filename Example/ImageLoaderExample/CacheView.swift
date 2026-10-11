import ImageLoader
import SwiftUI

struct CacheView: View {
    @State private var memoryCount = 0
    @State private var memoryCost = 0
    @State private var diskCount = 0
    @State private var diskSize = 0

    var body: some View {
        NavigationStack {
            List {
                Section("메모리 캐시") {
                    LabeledContent("이미지 수", value: "\(memoryCount)")
                    LabeledContent("비용", value: format(memoryCost))
                    Button("메모리 캐시 비우기") {
                        ImageSession.shared.cache.removeAll(caches: .memory)
                        refresh()
                    }
                    .accessibilityIdentifier("캐시_메모리비우기")
                }
                Section("디스크 캐시") {
                    LabeledContent("파일 수", value: "\(diskCount)")
                    LabeledContent("크기", value: format(diskSize))
                    Button("디스크 캐시 비우기", role: .destructive) {
                        ImageSession.shared.cache.removeAll(caches: .disk)
                        refresh()
                    }
                    .accessibilityIdentifier("캐시_디스크비우기")
                }
            }
            .navigationTitle("캐시")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("새로고침", action: refresh).accessibilityIdentifier("캐시_새로고침")
            }
            .onAppear(perform: refresh)
        }
    }

    private func refresh() {
        let memoryCache = ImageSession.shared.configuration.memoryCache as? MemoryCache
        memoryCount = memoryCache?.totalCount ?? 0
        memoryCost = memoryCache?.totalCost ?? 0
        let diskCache = ImageSession.shared.configuration.diskCache as? DiskCache
        diskCount = diskCache?.totalCount ?? 0
        diskSize = diskCache?.totalSize ?? 0
    }

    private func format(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
