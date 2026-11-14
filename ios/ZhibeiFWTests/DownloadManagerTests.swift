import XCTest
#if os(watchOS)
@testable import ZhibeiFWWatch
#else
@testable import ZhibeiFW
#endif

// 下载。下载、排队、重试、续传都交给系统，这里只测我们自己做的部分：
// 下载记录、下完移入资料库、暂停与续传数据、失败整批只提示一次、空间不足、对账。
// 用假的“系统下载服务”代替 URLSession，测试里直接替系统发事件。

final class FakeSystem: SystemDownloads {
    var handler: (@MainActor (DownloadEvent) -> Void)?
    var started: [(id: String, resume: Data?)] = []
    var cancelled: [String] = []
    /// 暂停、取消时交下来的任务编号
    var stoppedTasks: [Int?] = []
    var pauseData: Data? = Data("resume".utf8)
    var active = Set<String>()
    /// 给每个任务编号（像真的系统一样）；false 时不给（nil）
    var numbersTasks = false
    var lastTask = 0
    /// 设了就让 pause 等到放行（模拟系统迟迟不交回续传数据）
    var pauseGate: CheckedContinuation<Void, Never>?
    var holdPause = false

    func setHandler(_ h: @escaping @MainActor (DownloadEvent) -> Void) { handler = h }
    func start(id: String, url: URL, resumeData: Data?) -> Int? {
        started.append((id, resumeData)); active.insert(id)
        guard numbersTasks else { return nil }
        lastTask += 1
        return lastTask
    }
    func pause(id: String, task: Int?) async -> Data? {
        stoppedTasks.append(task)
        if holdPause { await withCheckedContinuation { pauseGate = $0 } }
        active.remove(id); return pauseData
    }
    func cancel(id: String, task: Int?) { cancelled.append(id); stoppedTasks.append(task); active.remove(id) }
    func activeTasks() async -> [String: Int] { Dictionary(uniqueKeysWithValues: active.map { ($0, 0) }) }
}

@MainActor
final class DownloadManagerTests: XCTestCase {
    var dir: URL!
    var store: Store!
    var files: AppFiles!
    var sys: FakeSystem!
    var dm: DownloadManager!
    var batchFailed = 0
    var diskFullAlerts = 0

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        files = AppFiles(documents: dir.appendingPathComponent("doc"), caches: dir.appendingPathComponent("cache"))
        files.prepare()
        let db = try SQLiteDB(path: dir.appendingPathComponent("t.db").path)
        _ = try Migrator.migrate(db)
        store = Store(db: db)
        sys = FakeSystem()
        dm = DownloadManager(system: sys, store: store, files: files)
        dm.origin = { "https://example.invalid" }
        batchFailed = 0
        dm.onBatchFailed = { [unowned self] in self.batchFailed += 1 }
        diskFullAlerts = 0
        dm.onDiskFull = { [unowned self] in self.diskFullAlerts += 1 }
    }
    override func tearDown() async throws {
        dm = nil; sys = nil; store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func item(_ id: String, _ pos: Int) -> DlItem {
        DlItem(episodeId: id, seriesId: "s", seriesTitle: "s", episodeTitle: id, pos: pos, audioPath: "c/s/\(id).mp3")
    }

    /// 交给系统（等线路是异步的）
    private func enqueue(_ list: [DlItem]) async {
        dm.enqueue(list)
        await settle()
    }

    /// 等线路是异步的：等这一批都交给系统
    private func settle() async {
        for _ in 0..<500 where dm.items.keys.contains(where: dm.isHandingOver) { await Task.yield() }
    }

    private func send(_ e: DownloadEvent) { sys.handler?(e) }

    private func tmpFile(_ bytes: Int = 1000) throws -> URL {
        let u = files.partDir.appendingPathComponent(UUID().uuidString + ".tmp")
        try Data(count: bytes).write(to: u)
        return u
    }

    func testFinishedMovesIntoLibrary() async throws {
        await enqueue([item("a", 0)])
        XCTAssertEqual(sys.started.map(\.id), ["a"])
        XCTAssertEqual(dm.items["a"]?.status, .downloading)
        send(.progress("a", 500, 1000))
        XCTAssertEqual(dm.ratio("a"), 0.5)
        send(.finished("a", try tmpFile()))
        XCTAssertEqual(dm.items["a"]?.status, .done)
        let r = store.getDownload("a")
        XCTAssertEqual(r?.state, .done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.absolute(r!.localFile!).path))
        XCTAssertEqual(batchFailed, 0)
    }

    func testDownloadedAudioSurvivesStoreReopenWithoutNetwork() async throws {
        await enqueue([item("offline", 0)])
        let payload = Data("offline audio fixture".utf8)
        let tmp = try tmpFile()
        try payload.write(to: tmp)
        send(.finished("offline", tmp))
        let reopened = Store(db: try SQLiteDB(path: dir.appendingPathComponent("t.db").path))
        guard case .file(let url) = files.localAudio(for: "offline", store: reopened) else {
            return XCTFail("已下载文件应能在资料库重开后直接读取")
        }
        XCTAssertEqual(try Data(contentsOf: url), payload)
        try FileManager.default.removeItem(at: url)
        guard case .missing = files.localAudio(for: "offline", store: reopened) else {
            return XCTFail("丢失的离线文件不能当作可用下载")
        }
    }

    /// 系统报失败：没有续传数据的回到未下载；有的记为已暂停；整批结束只提示一次
    func testFailuresAlertOncePerBatch() async throws {
        await enqueue([item("a", 0), item("b", 1), item("c", 2)])
        send(.failed("a", URLError(.timedOut), nil))
        XCTAssertEqual(batchFailed, 0)  // 还有在下的，先不提示
        send(.progress("b", 300, 1000))
        send(.failed("b", URLError(.networkConnectionLost), Data("r".utf8)))
        send(.finished("c", try tmpFile()))
        XCTAssertNil(dm.items["a"]); XCTAssertNil(store.getDownload("a"))
        XCTAssertEqual(dm.items["b"]?.status, .paused)
        XCTAssertEqual(dm.items["b"]?.written, 300)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.resumeDataFile("b").path))
        XCTAssertEqual(dm.items["c"]?.status, .done)
        XCTAssertEqual(batchFailed, 1)
    }

    /// 暂停交给系统生成续传数据；继续时把续传数据交回系统
    func testPauseThenResumeUsesSystemResumeData() async throws {
        await enqueue([item("a", 0)])
        send(.progress("a", 400, 1000))
        dm.pause("a")
        for _ in 0..<50 where store.getDownload("a")?.state != .paused { await Task.yield() }
        XCTAssertEqual(dm.items["a"]?.status, .paused)
        XCTAssertEqual(store.getDownload("a")?.bytes, 400)
        // 暂停后进度环停在原处，总大小也记进库里（重启后还是 40%）
        XCTAssertEqual(dm.ratio("a"), 0.4)
        XCTAssertEqual(store.getDownload("a")?.total, 1000)
        send(.failed("a", URLError(.cancelled), nil))  // 系统随后报“已取消”：不算失败
        XCTAssertEqual(dm.items["a"]?.status, .paused)
        XCTAssertEqual(batchFailed, 0)

        sys.started = []
        dm.resumePaused()
        for _ in 0..<50 where sys.started.isEmpty { await Task.yield() }
        await settle()
        XCTAssertEqual(sys.started.first?.resume, Data("resume".utf8))
        XCTAssertEqual(dm.items["a"]?.status, .downloading)
        XCTAssertEqual(dm.ratio("a"), 0.4)
    }

    /// 暂停、取消按系统任务编号去停，不会停到同一集刚开始的新任务
    func testStopUsesTaskNumber() async {
        sys.numbersTasks = true
        await enqueue([item("a", 0), item("b", 1)])
        dm.pause("a")
        for _ in 0..<50 where sys.stoppedTasks.isEmpty { await Task.yield() }
        dm.cancel("b")
        XCTAssertEqual(sys.stoppedTasks, [1, 2])
    }

    /// 对账时系统里找不到、被记为暂停的集，系统随后补交“下完”：照收，不丢掉
    func testFinishAfterReconcileInferredPause() async throws {
        await enqueue([item("a", 0)])
        sys.active = []
        dm.reconcile(active: [:])
        XCTAssertEqual(dm.items["a"]?.status, .paused)
        send(.finished("a", try tmpFile()))
        XCTAssertEqual(dm.items["a"]?.status, .done)
        XCTAssertEqual(store.getDownload("a")?.state, .done)
    }

    /// 上次运行交给系统的任务：对账时记下编号，暂停时按编号停
    func testReconcileAdoptsTaskNumberFromLastRun() async {
        try? store.startDownloads([item("a", 0)], ids: ["a"])
        dm.reconcile(active: ["a": 7])
        XCTAssertEqual(dm.items["a"]?.status, .downloading)
        dm.pause("a")
        for _ in 0..<50 where sys.stoppedTasks.isEmpty { await Task.yield() }
        XCTAssertEqual(sys.stoppedTasks, [7])
    }

    /// 等系统列任务期间刚交给系统的（不在 active 里）：不记成暂停
    func testReconcileKeepsTaskStartedMeanwhile() async {
        sys.numbersTasks = true
        await enqueue([item("a", 0)])
        dm.reconcile(active: [:])
        XCTAssertEqual(dm.items["a"]?.status, .downloading)
    }

    func testCancelRemovesRecord() async {
        await enqueue([item("a", 0)])
        dm.cancel("a")
        XCTAssertEqual(sys.cancelled, ["a"])
        XCTAssertNil(dm.items["a"]); XCTAssertNil(store.getDownload("a"))
        send(.failed("a", URLError(.cancelled), nil))
        XCTAssertEqual(batchFailed, 0)
    }

    /// 整门课取消：只撤没下完的，下完的和封面留着；整门课删除：音频、记录、封面都清掉
    func testSeriesCancelThenRemove() async throws {
        await enqueue([item("a", 0), item("b", 1), item("c", 2)])
        send(.finished("a", try tmpFile()))
        let cover = files.coversDir.appendingPathComponent(fileKey("s") + ".jpg")
        try Data(count: 10).write(to: cover)
        let audio = files.absolute(store.getDownload("a")!.localFile!)
        dm.cancelSeries("s")
        XCTAssertEqual(Set(sys.cancelled), ["b", "c"])
        XCTAssertEqual(dm.items["a"]?.status, .done)
        XCTAssertNil(dm.items["b"]); XCTAssertNil(store.getDownload("c"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cover.path))
        dm.removeSeries("s")
        XCTAssertNil(dm.items["a"]); XCTAssertNil(store.getDownload("a"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cover.path))
    }

    func testDiskFullAlertsOnce() async {
        await enqueue([item("a", 0), item("b", 1)])
        send(.failed("a", DiskFullError(), nil))
        send(.failed("b", DiskFullError(), nil))
        XCTAssertNil(store.getDownload("a")); XCTAssertNil(store.getDownload("b"))
        XCTAssertEqual(diskFullAlerts, 1)
        XCTAssertEqual(batchFailed, 0)
    }

    /// 用户划掉 App，系统取消后台下载：记为已暂停，不提示失败
    func testSystemCancelledBecomesPaused() async {
        await enqueue([item("a", 0)])
        send(.failed("a", URLError(.cancelled), Data("r".utf8)))
        XCTAssertEqual(dm.items["a"]?.status, .paused)
        XCTAssertEqual(batchFailed, 0)
    }

    /// 暂停恰好赶上下完：系统不再报“已取消”；以后这一集真的失败不能被当成“自己停的”吞掉
    func testPauseRacingFinishDoesNotSwallowLaterFailure() async throws {
        await enqueue([item("a", 0)])
        sys.pauseData = nil
        dm.pause("a")
        // 用户已经点了暂停：下完的文件不要，保持暂停（和 Android 一样）
        let tmp = try tmpFile()
        send(.finished("a", tmp))
        XCTAssertEqual(dm.items["a"]?.status, .paused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
        for _ in 0..<50 where store.getDownload("a")?.state != .paused { await Task.yield() }
        dm.removeDownload("a")
        sys.started = []
        await enqueue([item("a", 0)])
        send(.failed("a", URLError(.timedOut), nil))
        XCTAssertNil(dm.items["a"])
        XCTAssertNil(store.getDownload("a"))
        XCTAssertEqual(batchFailed, 1)
    }

    /// 暂停后又继续：旧任务迟到的“已取消”和进度不能把新开始的这一集又记成暂停
    func testStaleEventsFromStoppedTaskIgnored() async throws {
        sys.numbersTasks = true
        await enqueue([item("a", 0)])  // 任务 1
        send(.progress("a", 400, 1000, task: 1))
        dm.pause("a")
        for _ in 0..<50 where store.getDownload("a")?.state != .paused { await Task.yield() }
        sys.started = []
        dm.resumePaused()
        for _ in 0..<50 where sys.started.isEmpty { await Task.yield() }  // 任务 2
        await settle()
        XCTAssertEqual(dm.items["a"]?.status, .downloading)
        send(.progress("a", 999, 1000, task: 1))
        send(.failed("a", URLError(.cancelled), Data("old".utf8), task: 1))
        XCTAssertEqual(dm.items["a"]?.status, .downloading)
        XCTAssertNotEqual(dm.ratio("a"), 0.999)
        // 新任务自己的失败照常算
        send(.failed("a", URLError(.timedOut), nil, task: 2))
        XCTAssertNil(dm.items["a"])
        XCTAssertEqual(batchFailed, 1)
    }

    /// 暂停后系统还没交回续传数据，用户又点了继续：等交回来时不能再把它记成暂停
    func testResumeBeforePauseReturns() async throws {
        sys.numbersTasks = true
        sys.holdPause = true
        await enqueue([item("a", 0)])
        dm.pause("a")
        for _ in 0..<50 where sys.pauseGate == nil { await Task.yield() }
        sys.started = []
        dm.enqueue([item("a", 0)])  // 单集“继续”
        XCTAssertEqual(dm.items["a"]?.status, .downloading)
        for _ in 0..<50 where sys.started.isEmpty { await Task.yield() }
        sys.pauseGate?.resume()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(dm.items["a"]?.status, .downloading)
        XCTAssertEqual(store.getDownload("a")?.state, .downloading)
        XCTAssertEqual(sys.started.count, 1)
    }

    /// 等线路期间暂停又继续：只交给系统一次
    func testPauseResumeWhileWaitingForRouteStartsOnce() async throws {
        var gate: CheckedContinuation<Void, Never>?
        dm.origin = {
            await withCheckedContinuation { gate = $0 }
            return "https://example.invalid"
        }
        dm.enqueue([item("a", 0)])
        for _ in 0..<50 where gate == nil { await Task.yield() }
        let first = gate
        gate = nil
        dm.pause("a")
        dm.enqueue([item("a", 0)])  // 单集“继续”
        for _ in 0..<50 where gate == nil { await Task.yield() }
        first?.resume()
        gate?.resume()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(sys.started.map(\.id), ["a"])
        XCTAssertEqual(dm.items["a"]?.status, .downloading)
    }

    private func pausedWithResumeData(_ id: String) async {
        await enqueue([item(id, 0)])
        send(.progress(id, 400, 1000))
        dm.pause(id)
        for _ in 0..<50 where store.getDownload(id)?.state != .paused { await Task.yield() }
    }

    /// 继续时线路都连不上：已暂停的退回暂停（记录和续传数据都在），新加的回到未下载，整批提示一次
    func testResumeWithoutRouteStaysPaused() async throws {
        await pausedWithResumeData("a")
        dm.origin = { nil }
        sys.started = []
        dm.enqueue([item("a", 0), item("b", 1)])
        for _ in 0..<100 where dm.hasActive { await Task.yield() }
        XCTAssertEqual(dm.items["a"]?.status, .paused)
        XCTAssertEqual(store.getDownload("a")?.state, .paused)
        XCTAssertEqual(dm.ratio("a"), 0.4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.resumeDataFile("a").path))
        XCTAssertNil(dm.items["b"]); XCTAssertNil(store.getDownload("b"))
        XCTAssertTrue(sys.started.isEmpty)
        XCTAssertEqual(batchFailed, 1)
    }

    /// 继续后还在等线路时对账：续传数据不能被当成孤儿删掉
    func testReconcileWhileWaitingForRouteKeepsResumeData() async throws {
        await pausedWithResumeData("a")
        var gate: CheckedContinuation<Void, Never>?
        dm.origin = {
            await withCheckedContinuation { gate = $0 }
            return "https://example.invalid"
        }
        sys.started = []
        dm.enqueue([item("a", 0)])
        for _ in 0..<50 where gate == nil { await Task.yield() }
        dm.reconcile(active: [:])
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.resumeDataFile("a").path))
        gate?.resume()
        for _ in 0..<100 where sys.started.isEmpty { await Task.yield() }
        XCTAssertEqual(sys.started.first?.resume, Data("resume".utf8))
    }

    /// 移入资料库失败但不是空间不足：按普通失败，不提示“存储空间不足”
    func testMoveFailureIsNotDiskFull() async throws {
        await enqueue([item("a", 0)])
        send(.finished("a", files.partDir.appendingPathComponent("missing.tmp")))
        XCTAssertNil(dm.items["a"])
        XCTAssertEqual(diskFullAlerts, 0)
        XCTAssertEqual(batchFailed, 1)
    }

    /// 对账清掉资料库里没有下载记录对应的音频
    func testReconcilePreservesFilesWhenDownloadQueryFails() throws {
        let downloads = [item("a", 0), item("b", 1), item("c", 2)]
        try store.startDownloads(downloads, ids: downloads.map(\.episodeId))
        let rel = files.finalRelative("a", audioPath: downloads[0].audioPath)
        try store.setDlDone("a", localFile: rel)
        try store.setDlPaused("b", bytes: 3)
        let audio = files.absolute(rel)
        let cover = files.coverFile(seriesId: "s")
        let resume = files.resumeDataFile("b")
        let pending = files.doneFile("c")
        for url in [audio, cover, resume, pending] { try Data([1]).write(to: url) }

        try store.db.exec("ALTER TABLE user_download RENAME TO unavailable_download")
        XCTAssertThrowsError(try store.allDownloads())
        dm.cleanupCovers()
        dm.reconcile(active: ["c": 1])
        try store.db.exec("ALTER TABLE unavailable_download RENAME TO user_download")

        for url in [audio, cover, resume, pending] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
        }
        XCTAssertEqual(store.getDownload("a")?.state, .done)
    }

    func testReconcileRemovesOrphanAudio() throws {
        try store.queuedMany([item("a", 0)])
        try store.setDlDone("a", localFile: "audio/a.mp3")
        try Data(count: 10).write(to: files.absolute("audio/a.mp3"))
        try Data(count: 10).write(to: files.absolute("audio/x.mp3"))
        dm.reconcile(active: [:])
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.absolute("audio/a.mp3").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.absolute("audio/x.mp3").path))
    }

    /// App 没打开时系统下完、来不及移入资料库就被关掉：下次对账接回来
    func testReconcilePicksUpFinishedFile() throws {
        try store.queuedMany([item("a", 0)])
        try store.setDlState("a", .downloading)
        try Data(count: 1000).write(to: files.doneFile("a"))
        try Data(count: 10).write(to: files.partDir.appendingPathComponent("old.tmp"))
        dm.reconcile(active: [:])
        XCTAssertEqual(dm.items["a"]?.status, .done)
        let r = store.getDownload("a")
        XCTAssertEqual(r?.state, .done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.absolute(r!.localFile!).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.doneFile("a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.partDir.appendingPathComponent("old.tmp").path))
    }

    /// 对账：系统还在下的保持下载中；系统里没有的记为已暂停（没有续传数据的进度归零）
    func testReconcile() throws {
        try store.queuedMany([item("a", 0), item("b", 1)])
        try store.setDlState("a", .downloading); try store.setDlState("b", .downloading)
        dm.reconcile(active: ["a": 9])
        XCTAssertEqual(dm.items["a"]?.status, .downloading)
        XCTAssertEqual(dm.items["b"]?.status, .paused)
        XCTAssertEqual(store.getDownload("b")?.state, .paused)
        XCTAssertEqual(store.getDownload("b")?.bytes, 0)
    }
}
