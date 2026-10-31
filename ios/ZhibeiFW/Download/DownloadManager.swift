import Foundation
import Observation

// 下载。
//  真正的下载、排队、同时下几个、断网重试、续传都交给系统（iOS URLSession 后台会话，Android 系统 DownloadManager），
//  这里只做系统不管的事：记下载记录、下完移入资料库、显示进度、失败时整批提示一次、对账。
//  - 有网就下，不分 Wi-Fi 还是流量，不提示；
//  - 暂停：iOS 交给系统生成续传数据，继续时从断点接着下（Android 系统没有暂停）；
//  - 系统报失败：系统给了续传数据的记为“已暂停”，没有的回到“未下载”；整批结束只提示一次；
//  - 存储空间不足：提示一次。

struct DiskFullError: Error {}

/// 系统交回来的下载事件（在主线程上处理）。
enum DownloadEvent {
    case progress(String, Int64, Int64)
    /// 下完：文件已挪到我们自己的临时位置
    case finished(String, URL)
    /// 失败：系统给了续传数据就带上
    case failed(String, Error, Data?)
}

/// 系统的下载服务（两端各一份；测试里换成假的）。
protocol SystemDownloads: AnyObject {
    func setHandler(_ h: @escaping @MainActor (DownloadEvent) -> Void)
    /// 交给系统下载；有续传数据就从断点接着下。
    func start(id: String, url: URL, resumeData: Data?)
    /// 暂停：停下这一集，返回系统给的续传数据（拿不到为 nil）。
    func pause(id: String) async -> Data?
    func cancel(id: String)
    /// 系统里还在下（含排队、等网络）的集。
    func activeIds() async -> Set<String>
}

/// 进度节流：变化够 1% 且距上次够 0.25 秒才放行（线程安全，在下载线程上调用）。
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastRatio = -1.0
    private var lastAt = Date.distantPast
    func pass(written: Int64, total: Int64, now: Date = Date()) -> Bool {
        lock.withLock {
            let ratio = total > 0 ? Double(written) / Double(total) : 0
            if lastRatio >= 0 && (abs(ratio - lastRatio) < 0.01 || now.timeIntervalSince(lastAt) < 0.25) { return false }
            lastRatio = ratio; lastAt = now
            return true
        }
    }
}

struct DlProgress: Equatable {
    var status: DlStatus; var written: Int64; var total: Int64; var seriesId: String
    var ratio: Double { total > 0 ? min(1, Double(written) / Double(total)) : 0 }
}

@MainActor
@Observable
final class DownloadManager {
    private(set) var items: [String: DlProgress] = [:]
    /// 整批结束有失败时 +1（界面据此弹一次“部分下载失败，请稍后重试”）。
    private(set) var failedBatch = 0
    private(set) var diskFull = 0

    @ObservationIgnored let system: SystemDownloads
    @ObservationIgnored let store: Store
    @ObservationIgnored let files: AppFiles
    @ObservationIgnored var origin: () async -> String? = { await Network.shared.ensureRoutes() }
    /// 正在交给系统（还在等线路）的集：对账时别把它们当成中断
    @ObservationIgnored private var starting = Set<String>()
    /// 我们自己停下的（暂停、取消）：系统随后报的“已取消”不算失败
    @ObservationIgnored private var stopping = Set<String>()
    @ObservationIgnored private var failedInBatch = 0
    @ObservationIgnored private var diskFullShown = false
    @ObservationIgnored var onChange: (() -> Void)?
    /// 整批结束有失败：“部分下载失败，请稍后重试”（整批只提示一次）。
    @ObservationIgnored var onBatchFailed: (() -> Void)?
    /// 存储空间不足：“手机存储空间不足，下载失败”。
    @ObservationIgnored var onDiskFull: (() -> Void)?

    init(system: SystemDownloads, store: Store, files: AppFiles) {
        self.system = system
        self.store = store
        self.files = files
        system.setHandler { [weak self] in self?.handle($0) }
    }

    /// notify：状态变了（排队、完成、暂停、删除……）才通知各页面重新读库；单纯的进度变化不通知（界面直接读 items）。
    private func set(_ id: String, _ v: DlProgress?, notify: Bool = true) {
        items[id] = v
        if notify { onChange?() }
    }

    /// 有没有排队或正在下的集
    var hasActive: Bool { items.values.contains { $0.status == .queued || $0.status == .downloading } }

    private func finishBatchIfIdle() {
        guard !hasActive else { return }
        if failedInBatch > 0 { failedInBatch = 0; failedBatch += 1; onBatchFailed?() }
        diskFullShown = false
    }

    // MARK: 开始

    /// 把一批集交给系统下载（已在下或已下载的忽略；已暂停的继续：有续传数据就从断点接着下）。
    func enqueue(_ list: [DlItem]) {
        var seen = Set<String>()
        var todo: [DlItem] = []
        for it in list where !seen.contains(it.episodeId) {
            seen.insert(it.episodeId)
            if let cur = items[it.episodeId], cur.status != .paused { continue }
            todo.append(it)
        }
        guard !todo.isEmpty else { return }
        let fresh = todo.filter { items[$0.episodeId]?.status != .paused }
        if !fresh.isEmpty { try? store.queuedMany(fresh) }  // 整批一个事务
        for it in todo {
            let cur = items[it.episodeId]
            try? store.setDlState(it.episodeId, .downloading)
            items[it.episodeId] = DlProgress(
                status: .downloading, written: cur?.written ?? 0, total: cur?.total ?? 0, seriesId: it.seriesId)
            starting.insert(it.episodeId)
        }
        onChange?()
        Task {
            let o = await origin()
            for it in todo {
                starting.remove(it.episodeId)
                guard items[it.episodeId]?.status == .downloading else { continue }  // 等线路期间被暂停或取消了
                guard let o, let url = buildUrl(o, it.audioPath) else { fail(it.episodeId, nil); continue }
                // 上一轮暂停、取消留下的“自己停的”记号：这一集重新开始了，不再适用
                stopping.remove(it.episodeId)
                let resume = try? Data(contentsOf: files.resumeDataFile(it.episodeId))
                try? FileManager.default.removeItem(at: files.resumeDataFile(it.episodeId))
                system.start(id: it.episodeId, url: url, resumeData: resume)
            }
            finishBatchIfIdle()
        }
    }

    // MARK: 系统交回来的事件

    private func handle(_ e: DownloadEvent) {
        switch e {
        case let .progress(id, w, t):
            guard let cur = items[id], cur.status == .downloading else { return }
            set(id, DlProgress(status: .downloading, written: w, total: t, seriesId: cur.seriesId), notify: false)
        case let .finished(id, tmp):
            finish(id, tmp)
        case let .failed(id, error, resume):
            if stopping.remove(id) != nil { return }  // 我们自己停的，已经处理过
            if error is DiskFullError {
                try? store.removeDownload(id)
                set(id, nil)
                if !diskFullShown { diskFullShown = true; diskFull += 1; onDiskFull?() }
            } else if (error as NSError).code == NSURLErrorCancelled, store.getDownload(id) != nil {
                // 用户从多任务界面划掉 App 时系统会取消后台下载（Apple 的规定）：记为已暂停，不算失败
                pauseRecord(id, resume)
            } else {
                fail(id, resume)
            }
        }
        finishBatchIfIdle()
    }

    private func finish(_ id: String, _ tmp: URL) {
        // 暂停、取消恰好赶上下完：系统不会再报“已取消”，记号要在这里清掉，否则这一集以后真的失败会被吞掉
        stopping.remove(id)
        guard let r = store.getDownload(id), r.state != .done else { try? FileManager.default.removeItem(at: tmp); return }
        let rel = files.finalRelative(id, audioPath: r.audioPath)
        let final = files.absolute(rel)
        try? FileManager.default.removeItem(at: final)
        do { try FileManager.default.moveItem(at: tmp, to: final) } catch {
            try? FileManager.default.removeItem(at: tmp)
            handle(.failed(id, DiskFullError(), nil)); return
        }
        try? store.setDlDone(id, localFile: rel)
        set(id, DlProgress(status: .done, written: 1, total: 1, seriesId: r.seriesId))
    }

    /// 系统报失败：给了续传数据就记为已暂停（继续时从断点接着下），否则回到未下载。都算这一批的失败。
    private func fail(_ id: String, _ resume: Data?) {
        if resume != nil {
            pauseRecord(id, resume)
        } else {
            try? store.removeDownload(id)
            set(id, nil)
        }
        failedInBatch += 1
    }

    private func pauseRecord(_ id: String, _ resume: Data?) {
        guard let r = store.getDownload(id) else { return }
        let cur = items[id]
        let written = resume != nil ? (cur?.written ?? 0) : 0
        if let resume {
            try? resume.write(to: files.resumeDataFile(id))
        } else {
            try? FileManager.default.removeItem(at: files.resumeDataFile(id))
        }
        let total = cur?.total ?? r.total
        try? store.setDlInfo(id, total: total, validator: nil)
        try? store.setDlPaused(id, bytes: written)
        set(id, DlProgress(status: .paused, written: written, total: total, seriesId: r.seriesId))
    }

    // MARK: 暂停、继续、取消

    func pause(_ id: String) {
        guard let cur = items[id], cur.status == .queued || cur.status == .downloading else { return }
        if !starting.contains(id) { stopping.insert(id) }  // 还没交给系统的不会有系统的“已取消”
        set(id, DlProgress(status: .paused, written: cur.written, total: cur.total, seriesId: cur.seriesId))
        Task {
            let resume = await system.pause(id: id)
            pauseRecord(id, resume)
            finishBatchIfIdle()
        }
    }

    func pauseAll(seriesId: String? = nil) {
        for (k, v) in items where (v.status == .queued || v.status == .downloading) && (seriesId == nil || v.seriesId == seriesId) {
            pause(k)
        }
    }

    func cancel(_ id: String) {
        guard let cur = items[id], cur.status != .done else { return }
        if cur.status != .paused && !starting.contains(id) { stopping.insert(id); system.cancel(id: id) }
        try? FileManager.default.removeItem(at: files.resumeDataFile(id))
        try? store.removeDownload(id)
        set(id, nil)
        finishBatchIfIdle()
        cleanupCovers()
    }

    func cancelSeries(_ seriesId: String? = nil) {
        for (k, v) in items where (seriesId == nil || v.seriesId == seriesId) && v.status != .done { cancel(k) }
    }

    /// 继续已暂停的集（单集的灰色暂停环、整门课“继续下载”、资料库“继续全部”）。
    func resumePaused(seriesId: String? = nil) {
        let list = ((try? store.allDownloads()) ?? []).filter { $0.state == .paused && (seriesId == nil || $0.seriesId == seriesId) }.map(
            \.item)
        enqueue(list)
    }

    /// 删除下载（文件和记录；没下完的先停下）。
    func removeDownload(_ id: String) {
        if let cur = items[id], cur.status != .done { cancel(id); return }
        if let r = store.getDownload(id), let lf = r.localFile { try? FileManager.default.removeItem(at: files.absolute(lf)) }
        try? store.removeDownload(id)
        set(id, nil)
        cleanupCovers()
    }

    func removeSeries(_ seriesId: String) {
        for r in (try? store.downloadsOfSeries(seriesId)) ?? [] { removeDownload(r.episodeId) }
    }

    /// 没有任何下载记录的课，本机保存的封面删掉。
    func cleanupCovers() {
        let keys = ((try? FileManager.default.contentsOfDirectory(atPath: files.coversDir.path)) ?? []).filter { $0.hasSuffix(".jpg") }.map
        { String($0.dropLast(4)) }
        for k in orphanCoverKeys(keys, seriesWithDownloads: (try? store.seriesIdsWithDownloads()) ?? []) {
            try? FileManager.default.removeItem(at: files.coversDir.appendingPathComponent(k + ".jpg"))
        }
    }

    // MARK: 对账（启动、回到前台）

    /// active：系统里还在下的集。没下完、系统里也没有的，记为已暂停（有续传数据的继续时从断点接着下）。
    func reconcile(active: Set<String>) {
        // 已下载完成的：文件不在就删记录（这一集回到未下载）
        for r in (try? store.doneDownloads()) ?? [] {
            if let lf = r.localFile, FileManager.default.fileExists(atPath: files.absolute(lf).path) {
                if items[r.episodeId]?.status != .done {
                    items[r.episodeId] = DlProgress(status: .done, written: 1, total: 1, seriesId: r.seriesId)
                }
            } else {
                try? store.removeDownload(r.episodeId)
                items[r.episodeId] = nil
            }
        }
        for r in ((try? store.allDownloads()) ?? []) where r.state != .done {
            let id = r.episodeId
            if active.contains(id) || starting.contains(id) || stopping.contains(id) {
                if items[id] == nil { items[id] = DlProgress(status: .downloading, written: 0, total: r.total, seriesId: r.seriesId) }
                continue
            }
            // 系统已经下完、App 没来得及移入资料库就被关掉了：现在补上
            if FileManager.default.fileExists(atPath: files.doneFile(id).path) {
                finish(id, files.doneFile(id))
                continue
            }
            let hasResume = FileManager.default.fileExists(atPath: files.resumeDataFile(id).path)
            let written = hasResume ? r.bytes : 0
            if r.state != .paused || written != r.bytes { try? store.setDlPaused(id, bytes: written) }
            items[id] = DlProgress(status: .paused, written: written, total: r.total, seriesId: r.seriesId)
        }
        // 孤儿临时文件：没有下载记录的续传数据、下完的文件，以及旧版本留下的半截文件和 .tmp
        let pending = ((try? store.allDownloads()) ?? []).filter { $0.state != .done }
        let keep = Set(
            pending.filter { $0.state == .paused }.map { files.resumeDataFile($0.episodeId).lastPathComponent }
                + pending.map { files.doneFile($0.episodeId).lastPathComponent })
        for n in (try? FileManager.default.contentsOfDirectory(atPath: files.partDir.path)) ?? [] where !keep.contains(n) {
            try? FileManager.default.removeItem(at: files.partDir.appendingPathComponent(n))
        }
        cleanupCovers()
        finishBatchIfIdle()
        onChange?()
    }
}
