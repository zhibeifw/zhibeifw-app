import Foundation

/// 下载过的课，封面另存一份到本机（资料库离线显示、锁屏封面用；清除封面缓存不影响它）。
/// 取图复用封面加载器：同样的线路、超时、并发去重和磁盘缓存。
struct CoverArchive {
    let files: AppFiles
    /// 正在另存的课：同一门课连着点几集下载时只存一次，不会几个任务抢同一个临时文件
    private static let saving = Saving()
    private final class Saving: @unchecked Sendable {
        private let lock = NSLock()
        private var ids = Set<String>()
        func begin(_ id: String) -> Bool { lock.withLock { ids.insert(id).inserted } }
        func end(_ id: String) { lock.withLock { _ = ids.remove(id) } }
    }

    func save(seriesId: String, coverPath: String?) {
        let dest = files.coverFile(seriesId: seriesId)
        guard let cover = coverPath, !cover.isEmpty, !FileManager.default.fileExists(atPath: dest.path),
            Self.saving.begin(seriesId)
        else { return }
        Task.detached(priority: .utility) {
            defer { Self.saving.end(seriesId) }
            guard let src = await ImageLoader.shared.originalFile(cover) else { return }
            // 先拷到临时文件再改名：中途被关掉不会留下半张图
            let tmp = dest.appendingPathExtension("tmp")
            try? FileManager.default.removeItem(at: tmp)
            guard (try? FileManager.default.copyItem(at: src, to: tmp)) != nil else { return }
            if (try? FileManager.default.moveItem(at: tmp, to: dest)) == nil { try? FileManager.default.removeItem(at: tmp) }
        }
    }
}
