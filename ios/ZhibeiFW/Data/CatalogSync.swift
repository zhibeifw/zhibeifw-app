import Foundation

// ETag 同步。只有一个文件 index.json。
// 没变（304）什么都不做；变了才下载、校验、写库。解析失败丢弃、沿用本机旧数据、不记 ETag。

enum FileStatus: Equatable { case updated, unchanged, invalid, failed, missing }

struct SyncSummary: Equatable {
    var index: FileStatus
    var failed: Bool { index == .failed }
    var changed: Bool { index == .updated }
}

enum CatalogSync {
    static func syncIndex(store: Store, net: Network) async -> FileStatus {
        let etag = store.etag(INDEX_PATH)
        let r = await net.request(INDEX_PATH, etag: etag, maxBytes: FileKind.index.limit)
        switch r {
        case .notModified: return .unchanged
        case .notFound: return .missing
        case .error: return .failed
        case .ok(let data, let newEtag):
            guard let parsed = parseIndex(data) else { return .invalid }
            do {
                try store.replaceIndex(parsed)
                try store.setEtag(INDEX_PATH, newEtag)
                return .updated
            } catch {
                NSLog("写目录失败：\(error)")
                return .failed
            }
        }
    }

    static func sync(store: Store, net: Network) async -> SyncSummary {
        SyncSummary(index: await syncIndex(store: store, net: net))
    }

    /// 首次初始化：同步一次，index.json 成功（更新到了或没变化）才算完成并记下。
    static func initialize(store: Store, net: Network) async -> Bool {
        let s = await syncIndex(store: store, net: net)
        if s == .updated || s == .unchanged {
            try? store.markInitialized()
            return true
        }
        return false
    }

    static let initAttempts = 3
    static let initDelaysMs: [UInt64] = [2000, 4000]

    /// 首次初始化的自动重试：最多 3 次，间隔 2 秒、4 秒。
    static func initializeWithRetry(
        store: Store, net: Network, sleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0 * 1_000_000) },
        onAttempt: (Int) -> Void = { _ in }
    ) async -> Bool {
        for n in 1...initAttempts {
            onAttempt(n)
            if await initialize(store: store, net: net) { return true }
            if n < initAttempts { await sleep(initDelaysMs[min(n - 1, initDelaysMs.count - 1)]) }
        }
        return false
    }
}
