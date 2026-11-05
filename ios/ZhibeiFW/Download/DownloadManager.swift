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

/// 系统交回来的下载事件（在主线程上处理）。task：系统的任务编号（认得出是哪一次下载；不知道为 nil）。
enum DownloadEvent {
    case progress(String, Int64, Int64, task: Int? = nil)
    /// 下完：文件已挪到我们自己的临时位置
    case finished(String, URL, task: Int? = nil)
    /// 失败：系统给了续传数据就带上
    case failed(String, Error, Data?, task: Int? = nil)
}

/// 系统的下载服务（两端各一份；测试里换成假的）。
protocol SystemDownloads: AnyObject {
    func setHandler(_ h: @escaping @MainActor (DownloadEvent) -> Void)
    /// 交给系统下载；有续传数据就从断点接着下。返回系统的任务编号。
    @discardableResult func start(id: String, url: URL, resumeData: Data?) -> Int?
    /// 暂停：停下这一集，返回系统给的续传数据（拿不到为 nil）。
    /// task：要停的系统任务编号；nil 表示不知道（上次运行交给系统的），按集 ID 找。
    func pause(id: String, task: Int?) async -> Data?
    func cancel(id: String, task: Int?)
    /// 系统里还在下（含排队、等网络）的集 → 系统任务编号。
    func activeTasks() async -> [String: Int]
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

/// 一集的实时进度，每集一个：进度变了只有显示这一集的地方重画，不会让所有读下载状态的页面都重算。
@MainActor
@Observable
final class DlLive {
    var written: Int64
    var total: Int64
    var ratio: Double { total > 0 ? min(1, Double(written) / Double(total)) : 0 }
    init(written: Int64, total: Int64) {
        self.written = written
        self.total = total
    }
}

@MainActor
@Observable
final class DownloadManager {
    /// 每集的状态（排队、下载中、已暂停、已下载）。只在状态变了时写；进度见 live。
    private(set) var items: [String: DlProgress] = [:]
    @ObservationIgnored private var live: [String: DlLive] = [:]

    /// 这一集的下载进度（0～1）。
    func ratio(_ id: String) -> Double { live[id]?.ratio ?? items[id]?.ratio ?? 0 }
    private func written(_ id: String) -> Int64 { live[id]?.written ?? items[id]?.written ?? 0 }
    /// 总大小：进度事件只更新 live，记录里的可能还是开始时的 0
    private func total(_ id: String) -> Int64 { max(live[id]?.total ?? 0, items[id]?.total ?? 0) }
    /// 整批结束有失败时 +1（界面据此弹一次“部分下载失败，请稍后重试”）。
    private(set) var failedBatch = 0
    private(set) var diskFull = 0

    @ObservationIgnored let system: SystemDownloads
    @ObservationIgnored let store: Store
    @ObservationIgnored let files: AppFiles
    @ObservationIgnored var origin: () async -> String? = { await Network.shared.ensureRoutes() }
    /// 正在交给系统（还在等线路）的集：对账时别把它们当成中断
    @ObservationIgnored private var starting = Set<String>()
    /// 每集当前交给系统的任务编号，以及我们自己停下（暂停、取消）的任务编号：停下的任务随后报的事件一律不认，
    /// 免得“已取消”来晚了，把已经重新开始的这一集又记成暂停
    @ObservationIgnored private var liveTask: [String: Int] = [:]
    @ObservationIgnored private var retired = Set<Int>()
    /// 停下时不知道任务编号的（比如上次运行时交给系统的）：系统随后报的“已取消”不算失败
    @ObservationIgnored private var stopping = Set<String>()
    /// 对账时因为系统里找不到而记为暂停的集（不是用户点的）：系统随后交来“下完”的话照收。
    /// 回到前台时系统补交“下完”和对账同时进行，前者可能晚到
    @ObservationIgnored private var inferredPaused = Set<String>()
    /// 每集的代号：开始、暂停、取消都换一个。等线路、等系统交回续传数据期间代号变了，那一轮的结果就不再用
    @ObservationIgnored private var gen: [String: Int] = [:]
    private func bump(_ id: String) -> Int {
        let g = (gen[id] ?? 0) + 1
        gen[id] = g
        return g
    }
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
        if let v {
            if let l = live[id] {
                if l.written != v.written { l.written = v.written }
                if l.total != v.total { l.total = v.total }
            } else {
                live[id] = DlLive(written: v.written, total: v.total)
            }
        } else {
            live[id] = nil
        }
        if notify { onChange?() }
    }

    /// 停下这一集当前的系统任务：之后它报的事件都不认。不知道编号的记下集 ID。
    /// 返回这个任务的编号（不知道就是 nil），去系统里停的时候按它找，不会停错同一集刚开始的新任务
    @discardableResult private func retire(_ id: String) -> Int? {
        if let t = liveTask.removeValue(forKey: id) { retired.insert(t); return t }
        stopping.insert(id)
        return nil
    }

    /// 这一集还在等线路、没交给系统
    func isHandingOver(_ id: String) -> Bool { starting.contains(id) }

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
        let resumed = Set(todo.map(\.episodeId)).subtracting(fresh.map(\.episodeId))
        // 整批一个事务；连下载记录都写不进去，就别交给系统（否则下完找不到记录，这几集一直挂着“下载中”）
        do { try store.startDownloads(fresh, ids: todo.map(\.episodeId)) } catch {
            NSLog("写下载记录失败：\(error)"); onBatchFailed?(); return
        }
        var tokens: [String: Int] = [:]
        for it in todo {
            let cur = items[it.episodeId]
            inferredPaused.remove(it.episodeId)
            set(
                it.episodeId,
                DlProgress(
                    status: .downloading, written: cur == nil ? 0 : written(it.episodeId), total: cur == nil ? 0 : total(it.episodeId),
                    seriesId: it.seriesId),
                notify: false)
            starting.insert(it.episodeId)
            tokens[it.episodeId] = bump(it.episodeId)
        }
        onChange?()
        Task {
            let o = await origin()
            for it in todo {
                let id = it.episodeId, token = tokens[id]
                // 等线路期间被暂停、取消，或者暂停后又继续了（那一轮自己会交给系统）
                guard gen[id] == token else { continue }
                guard items[id]?.status == .downloading else { starting.remove(id); continue }
                guard let o, let url = buildUrl(o, it.audioPath) else {
                    starting.remove(id)
                    // 线路暂时都连不上：本来是暂停的退回暂停，续传数据留着；新加的才回到未下载
                    if resumed.contains(id) {
                        pauseRecord(id, try? Data(contentsOf: files.resumeDataFile(id)))
                        failedInBatch += 1
                    } else {
                        fail(id, nil)
                    }
                    continue
                }
                // 上一轮暂停、取消留下的“自己停的”记号：这一集重新开始了，不再适用
                stopping.remove(id)
                starting.remove(id)
                let resume = try? Data(contentsOf: files.resumeDataFile(id))
                try? FileManager.default.removeItem(at: files.resumeDataFile(id))
                if let t = system.start(id: id, url: url, resumeData: resume) { liveTask[id] = t }
            }
            finishBatchIfIdle()
        }
    }

    // MARK: 系统交回来的事件

    /// 这个任务的事件认不认：我们自己停下的任务、这一集已经换了新任务后旧任务的事件都不认。terminal：下完或失败（这个任务到此结束）。
    private func accept(_ id: String, _ task: Int?, terminal: Bool) -> Bool {
        guard let task else { return true }
        if terminal ? retired.remove(task) != nil : retired.contains(task) { return false }
        if let cur = liveTask[id], cur != task { return false }
        if terminal { liveTask[id] = nil }
        return true
    }

    private func handle(_ e: DownloadEvent) {
        switch e {
        case let .progress(id, w, t, task):
            guard accept(id, task, terminal: false), items[id]?.status == .downloading, let l = live[id] else { return }
            l.written = w; l.total = t
            return
        case let .finished(id, tmp, task):
            guard accept(id, task, terminal: true) else {  // 我们自己停下的任务恰好下完了：不要
                stopping.remove(id)
                try? FileManager.default.removeItem(at: tmp)
                return
            }
            finish(id, tmp)
        case let .failed(id, error, resume, task):
            let current = task != nil && liveTask[id] == task
            guard accept(id, task, terminal: true) else { return }  // 我们自己停的，已经处理过
            if !current, stopping.remove(id) != nil { return }
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
        // 用户已经暂停或取消了：下完的文件不要，状态保持用户点的那样
        let inferred = inferredPaused.remove(id) != nil
        guard let r = store.getDownload(id) else {
            // 记录没了：内存里也别再挂着“下载中”
            try? FileManager.default.removeItem(at: tmp)
            if items[id]?.status != .done { set(id, nil) }
            return
        }
        guard r.state != .done, inferred || (r.state != .paused && items[id]?.status != .paused) else {
            try? FileManager.default.removeItem(at: tmp); return
        }
        let rel = files.finalRelative(id, audioPath: r.audioPath)
        let final = files.absolute(rel)
        try? FileManager.default.removeItem(at: final)
        do { try FileManager.default.moveItem(at: tmp, to: final) } catch {
            try? FileManager.default.removeItem(at: tmp)
            // 只有空间不足才提示“存储空间不足”，其它错误按普通失败
            handle(.failed(id, isOutOfSpace(error) ? DiskFullError() : error, nil)); return
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
        let written = resume != nil ? written(id) : 0
        if let resume {
            try? resume.write(to: files.resumeDataFile(id))
        } else {
            try? FileManager.default.removeItem(at: files.resumeDataFile(id))
        }
        let total = max(total(id), r.total)
        try? store.setDlInfo(id, total: total, validator: nil)
        try? store.setDlPaused(id, bytes: written)
        set(id, DlProgress(status: .paused, written: written, total: total, seriesId: r.seriesId))
    }

    // MARK: 暂停、继续、取消

    func pause(_ id: String) {
        guard let cur = items[id], cur.status == .queued || cur.status == .downloading else { return }
        let g = bump(id)
        inferredPaused.remove(id)
        let handedOver = starting.remove(id) == nil
        let task = handedOver ? retire(id) : nil  // 还没交给系统的不会有系统的“已取消”
        set(id, DlProgress(status: .paused, written: written(id), total: total(id), seriesId: cur.seriesId))
        Task {
            // 还没交给系统的不用去系统里停
            let resume = handedOver ? await system.pause(id: id, task: task) : nil
            // 等系统交回续传数据期间又继续或取消了：这份续传数据不用
            guard gen[id] == g, items[id]?.status == .paused else { return }
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
        if cancelOne(id) { cleanupCovers() }
    }

    /// 取消一集，不清封面（整门课一起取消时最后清一次）；真取消了返回 true
    @discardableResult
    private func cancelOne(_ id: String) -> Bool {
        guard let cur = items[id], cur.status != .done else { return false }
        _ = bump(id)
        inferredPaused.remove(id)
        if cur.status != .paused && starting.remove(id) == nil {
            system.cancel(id: id, task: retire(id))
        }
        try? FileManager.default.removeItem(at: files.resumeDataFile(id))
        try? store.removeDownload(id)
        set(id, nil)
        finishBatchIfIdle()
        return true
    }

    func cancelSeries(_ seriesId: String? = nil) {
        let ids = items.filter { (seriesId == nil || $0.value.seriesId == seriesId) && $0.value.status != .done }.map(\.key)
        for k in ids { cancelOne(k) }
        if !ids.isEmpty { cleanupCovers() }
    }

    /// 继续已暂停的集（单集的灰色暂停环、整门课“继续下载”、资料库“继续全部”）。
    func resumePaused(seriesId: String? = nil) {
        let list = ((try? store.allDownloads()) ?? []).filter { $0.state == .paused && (seriesId == nil || $0.seriesId == seriesId) }.map(
            \.item)
        enqueue(list)
    }

    /// 删除下载（文件和记录；没下完的先停下）。
    func removeDownload(_ id: String) {
        removeOne(id)
        cleanupCovers()
    }

    /// 删一集，不清封面（整门课一起删时最后清一次）
    private func removeOne(_ id: String) {
        if let cur = items[id], cur.status != .done { cancelOne(id); return }
        if let r = store.getDownload(id), let lf = r.localFile { try? FileManager.default.removeItem(at: files.absolute(lf)) }
        try? store.removeDownload(id)
        set(id, nil)
    }

    func removeSeries(_ seriesId: String) {
        for r in (try? store.downloadsOfSeries(seriesId)) ?? [] { removeOne(r.episodeId) }
        cleanupCovers()
    }

    /// 没有任何下载记录的课，本机保存的封面删掉。
    func cleanupCovers() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: files.coversDir.path)) ?? []
        let keys = names.filter { $0.hasSuffix(".jpg") }.map { String($0.dropLast(4)) }
        for k in orphanCoverKeys(keys, seriesWithDownloads: (try? store.seriesIdsWithDownloads()) ?? []) {
            try? FileManager.default.removeItem(at: files.coversDir.appendingPathComponent(k + ".jpg"))
        }
    }

    // MARK: 对账（启动、回到前台）

    /// active：系统里还在下的集。没下完、系统里也没有的，记为已暂停（有续传数据的继续时从断点接着下）。
    func reconcile(active: [String: Int]) {
        // 已下载完成的：文件不在就删记录（这一集回到未下载）
        for r in (try? store.doneDownloads()) ?? [] {
            if let lf = r.localFile, FileManager.default.fileExists(atPath: files.absolute(lf).path) {
                if items[r.episodeId]?.status != .done {
                    set(r.episodeId, DlProgress(status: .done, written: 1, total: 1, seriesId: r.seriesId), notify: false)
                }
            } else {
                try? store.removeDownload(r.episodeId)
                set(r.episodeId, nil, notify: false)
            }
        }
        for r in ((try? store.allDownloads()) ?? []) where r.state != .done {
            let id = r.episodeId
            // 上次运行交给系统的任务：记下编号，以后暂停、取消按编号停，不按集 ID 猜
            if let t = active[id], liveTask[id] == nil, !starting.contains(id), !stopping.contains(id) { liveTask[id] = t }
            // liveTask：等系统列任务期间刚交给系统的，不在 active 里
            if active[id] != nil || starting.contains(id) || stopping.contains(id) || liveTask[id] != nil {
                if items[id] == nil { set(id, DlProgress(status: .downloading, written: 0, total: r.total, seriesId: r.seriesId), notify: false) }
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
            if r.state != .paused { inferredPaused.insert(id) }
            set(id, DlProgress(status: .paused, written: written, total: r.total, seriesId: r.seriesId), notify: false)
        }
        // 孤儿临时文件：没有下载记录的续传数据、下完的文件，以及旧版本留下的半截文件和 .tmp
        let pending = ((try? store.allDownloads()) ?? []).filter { $0.state != .done }
        // 续传数据按“没下完”保留，不只看暂停：继续时记录先改成下载中，等线路回来才读续传数据
        let keep = Set(
            pending.map { files.resumeDataFile($0.episodeId).lastPathComponent }
                + pending.map { files.doneFile($0.episodeId).lastPathComponent })
        for n in (try? FileManager.default.contentsOfDirectory(atPath: files.partDir.path)) ?? [] where !keep.contains(n) {
            try? FileManager.default.removeItem(at: files.partDir.appendingPathComponent(n))
        }
        // 资料库音频目录里没有下载记录对应的文件（移入资料库到一半被关掉等）
        let all = (try? store.allDownloads()) ?? []
        let keepAudio = all.map { ($0.localFile ?? files.finalRelative($0.episodeId, audioPath: $0.audioPath)) as NSString }.map {
            $0.lastPathComponent
        }
        let onDisk = ((try? FileManager.default.contentsOfDirectory(at: files.audioDir, includingPropertiesForKeys: [.isRegularFileKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.map(\.lastPathComponent)
        for n in orphanAudioNames(onDisk, keep: keepAudio) {
            try? FileManager.default.removeItem(at: files.audioDir.appendingPathComponent(n))
        }
        cleanupCovers()
        finishBatchIfIdle()
        onChange?()
    }
}
