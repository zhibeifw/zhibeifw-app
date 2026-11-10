import AVFoundation
import XCTest
@testable import ZhibeiFW

// 播放控制器。用真的系统播放器放测试里现生成的几秒静音 WAV（已下载的集走本地文件），
// 只把“取线路”“问文件在不在”“卡住多久算失败”换成测试里给的，不连网络。

@MainActor
final class PlayerControllerTests: XCTestCase {
    var dir: URL!
    var store: Store!
    var files: AppFiles!
    var damaged: [String] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        files = AppFiles(documents: dir.appendingPathComponent("doc"), caches: dir.appendingPathComponent("cache"))
        files.prepare()
        let db = try SQLiteDB(path: dir.appendingPathComponent("t.db").path)
        _ = try Migrator.migrate(db)
        store = Store(db: db)
        damaged = []
        // 一门课 3 集
        try store.replaceIndex(
            IndexFile(
                categories: [CategoryEntry(id: "分类", name: "分类", icon: nil, color: nil)],
                series: [
                    SeriesEntry(
                        id: "课", title: "课", categoryId: "分类", coverPath: "", status: "ongoing", description: nil,
                        episodes: (1...3).map { EpisodeEntry(id: "课_\($0)", title: "第\($0)课", audioPath: "分类/课/\($0).wav", duration: nil) },
                        updatedAt: nil)
                ], featured: []))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func make(routes: @escaping () async -> String? = { nil }, headStatus: @escaping (String) async -> Int? = { _ in nil },
                      stallLimit: Double = STALL_LIMIT_SEC, probeAfter: Double = PROBE_AFTER_SEC) -> PlayerController {
        let p = PlayerController(store: store, files: files, routes: routes, headStatus: headStatus, stallLimit: stallLimit, probeAfter: probeAfter)
        p.onDamaged = { [unowned self] in self.damaged.append($0) }
        return p
    }

    /// 几秒静音的 WAV（8 kHz、单声道、16 位）
    private func wav(seconds: Double) -> Data {
        let rate = 8000, samples = Int(Double(rate) * seconds), bytes = samples * 2
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data("RIFF".utf8)); u32(36 + bytes); d.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(bytes)
        d.append(Data(count: bytes))
        return d
    }

    /// 把这一集登记成“已下载”，本地文件是 data（nil：记录在、文件不在）
    private func download(_ n: Int, _ data: Data?) throws {
        let id = "课_\(n)"
        try store.startDownloads(
            [DlItem(episodeId: id, seriesId: "课", seriesTitle: "课", episodeTitle: "第\(n)课", pos: n, audioPath: "分类/课/\(n).wav")], ids: [id])
        let rel = files.finalRelative(id, audioPath: "分类/课/\(n).wav")
        if let data { try data.write(to: files.absolute(rel)) }
        try store.setDlDone(id, localFile: rel)
    }

    private func until(_ what: String, _ cond: () -> Bool) async { await until(5, what, cond) }

    private func until(_ timeout: Double, _ what: String, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(cond(), "等不到：\(what)")
    }

    private func pause(_ sec: Double) async { try? await Task.sleep(nanoseconds: UInt64(sec * 1e9)) }

    // MARK: 开始播放、续播

    func testResumesFromSavedPositionAndEntersRecent() async throws {
        try download(1, wav(seconds: 8))
        _ = try store.recordPlayback(episodeId: "课_1", seriesId: "课", position: 3, duration: 8, seriesTitle: "课", episodeTitle: "第1课", coverPath: "")
        try store.hideFromRecent("课_1")
        let p = make()
        XCTAssertTrue(p.start("课_1", ctx: .series("课")))
        XCTAssertTrue(p.looksPlaying, "点了马上显示暂停图标")
        await until("在出声") { p.isPlaying }
        XCTAssertFalse(p.loadingPlayback, "出声后显示暂停图标")
        XCTAssertGreaterThanOrEqual(p.position, 2.9)
        XCTAssertFalse(p.streaming)
        XCTAssertEqual(try store.loadRecent().first?.episodeId, "课_1", "一播放即进最近")
        p.pause()
    }

    func testCompletedEpisodeStartsFromBeginning() async throws {
        try download(1, wav(seconds: 8))
        _ = try store.recordPlayback(episodeId: "课_1", seriesId: "课", position: 8, duration: 8, seriesTitle: "课", episodeTitle: "第1课", coverPath: "")
        XCTAssertEqual(store.loadProgress("课_1")?.completed, true)
        let p = make()
        p.start("课_1", ctx: .series("课"))
        await until("在出声") { p.isPlaying }
        XCTAssertLessThan(p.position, 1.5)
        p.pause()
    }

    func testPauseSavesPositionAndResumeContinues() async throws {
        try download(1, wav(seconds: 8))
        let p = make()
        p.start("课_1", ctx: .series("课"))
        await until("播过 1 秒") { p.position >= 1 }
        p.pause()
        await until("停下") { !p.looksPlaying }
        let saved = try XCTUnwrap(store.loadProgress("课_1")?.position)
        XCTAssertEqual(saved, p.position, accuracy: 0.6)
        p.toggle()
        await until("接着出声") { p.isPlaying }
        XCTAssertGreaterThanOrEqual(p.position, saved - 0.5, "继续不是从头重新加载")
        p.pause()
    }

    // MARK: 播完以后

    func testSeriesPlaysNextAfterFinish() async throws {
        try download(1, wav(seconds: 1.5)); try download(2, wav(seconds: 8))
        let p = make()
        p.start("课_1", ctx: .series("课"))
        await until(8, "接到第 2 集并出声") { p.current?.episodeId == "课_2" && p.isPlaying }
        XCTAssertEqual(store.loadProgress("课_1")?.completed, true, "播完算听完")
        p.pause()
    }

    func testLibraryOnlyPlaysDownloadedNext() async throws {
        try download(1, wav(seconds: 1.5)); try download(3, wav(seconds: 8))
        let p = make()
        p.start("课_1", ctx: .library("课"))
        await until(8, "跳过没下载的第 2 集") { p.current?.episodeId == "课_3" && p.isPlaying }
        p.pause()
    }

    func testSingleStopsAtEnd() async throws {
        try download(1, wav(seconds: 1.5)); try download(2, wav(seconds: 8))
        let p = make()
        p.start("课_1", ctx: .single)
        await until("开始出声") { p.isPlaying }
        await until(6, "播完停住") { !p.looksPlaying }
        XCTAssertEqual(p.current?.episodeId, "课_1")
        XCTAssertEqual(store.loadProgress("课_1")?.completed, true)
    }

    func testSleepAtEndBeatsNext() async throws {
        try download(1, wav(seconds: 1.5)); try download(2, wav(seconds: 8))
        let p = make()
        p.setSleep(.end)
        p.start("课_1", ctx: .series("课"))
        await until("开始出声") { p.isPlaying }
        await until(6, "播完停住") { !p.looksPlaying }
        XCTAssertEqual(p.current?.episodeId, "课_1", "不接下一集")
        XCTAssertEqual(p.sleep, .off)
    }

    func testSleepTimerPausesAndTurnsOff() async throws {
        try download(1, wav(seconds: 10))
        let p = make()
        p.start("课_1", ctx: .series("课"))
        await until("开始出声") { p.isPlaying }
        p.setSleep(.timer(deadline: sleepClock() + 1.5, minutes: 1))
        XCTAssertEqual(p.sleep.choiceId, "m1")
        await until(5, "到点暂停") { !p.looksPlaying }
        XCTAssertEqual(p.sleep, .off)
        XCTAssertNil(p.sleepLeft)
        XCTAssertNotNil(store.loadProgress("课_1"), "到点暂停也存进度")
    }

    // MARK: 本地文件出问题

    func testMissingDownloadedFileIsDamaged() async throws {
        try download(1, nil)
        let p = make()
        p.start("课_1", ctx: .series("课"))
        XCTAssertEqual(p.error, .damaged)
        XCTAssertEqual(damaged, ["课_1"])
        XCTAssertFalse(p.looksPlaying)
    }

    func testCorruptDownloadedFileIsDamaged() async throws {
        try download(1, Data("not audio".utf8))
        let p = make()
        p.start("课_1", ctx: .series("课"))
        await until("报已损坏") { p.error == .damaged }
        XCTAssertEqual(damaged, ["课_1"])
        XCTAssertFalse(p.looksPlaying)
    }

    // MARK: 在线播放

    func testNoRouteCannotPlayAndStaysOutOfRecent() async throws {
        _ = try store.recordPlayback(episodeId: "课_1", seriesId: "课", position: 3, duration: 8, seriesTitle: "课", episodeTitle: "第1课", coverPath: "")
        try store.hideFromRecent("课_1")
        let p = make(routes: { nil })
        p.start("课_1", ctx: .series("课"))
        XCTAssertTrue(p.looksPlaying, "拿地址期间先显示暂停图标")
        await until("提示无法播放") { p.error == .cannotPlay }
        XCTAssertFalse(p.looksPlaying)
        XCTAssertEqual(store.loadProgress("课_1")?.position, 3, "原来的进度不被清零")
        XCTAssertTrue(try store.loadRecent().isEmpty, "失败的那一集不进最近")
    }

    func testStallFailsAndGoneFileReportedEarly() async throws {
        // 连不上的地址：一直缓冲。先问到 404 → 提前报“已下架”
        let p = make(routes: { "https://10.255.255.1" }, headStatus: { _ in 404 }, stallLimit: 20, probeAfter: 0.3)
        p.start("课_1", ctx: .series("课"))
        await until(10, "报已下架") { p.error != nil }
        XCTAssertEqual(p.error, .gone)
        await until("停下") { !p.looksPlaying }
        // 文件还在（问到 200）：不提前报，等满卡住的时限报“网络异常”
        let q = make(routes: { "https://10.255.255.1" }, headStatus: { _ in 200 }, stallLimit: 1.5, probeAfter: 0.3)
        q.start("课_2", ctx: .series("课"))
        await until(10, "卡住超时") { q.error != nil }
        XCTAssertEqual(q.error, .cannotPlay)
        await until("停下") { !q.looksPlaying }
    }

    // MARK: 加载期间的操作

    func testPauseWhileLoadingStaysSilentAndKeepsProgress() async throws {
        try download(1, wav(seconds: 8))
        _ = try store.recordPlayback(episodeId: "课_1", seriesId: "课", position: 3, duration: 8, seriesTitle: "课", episodeTitle: "第1课", coverPath: "")
        let p = make()
        p.start("课_1", ctx: .series("课"))
        XCTAssertTrue(p.loadingPlayback, "等待音频时显示加载且按钮仍可暂停")
        p.pause()
        await pause(1.2)
        XCTAssertFalse(p.isPlaying)
        XCTAssertFalse(p.looksPlaying)
        XCTAssertFalse(p.loadingPlayback, "暂停后不再显示加载")
        XCTAssertEqual(store.loadProgress("课_1")?.position, 3)
    }

    func testSwitchingWhileLoadingKeepsPreviousProgress() async throws {
        try download(1, wav(seconds: 8)); try download(2, wav(seconds: 8))
        _ = try store.recordPlayback(episodeId: "课_1", seriesId: "课", position: 3, duration: 8, seriesTitle: "课", episodeTitle: "第1课", coverPath: "")
        let p = make()
        p.start("课_1", ctx: .series("课"))
        p.start("课_2", ctx: .series("课"))
        await until("第 2 集出声") { p.isPlaying }
        XCTAssertEqual(p.current?.episodeId, "课_2")
        XCTAssertEqual(store.loadProgress("课_1")?.position, 3)
        p.pause()
    }

    // MARK: 标记为已听完、删除下载

    func testMarkCompletedStopsAndIsNotOverwritten() async throws {
        try download(1, wav(seconds: 8))
        let p = make()
        p.start("课_1", ctx: .series("课"))
        await until("播过 1 秒") { p.position >= 1 }
        try store.markCompleted("课_1", seriesId: "课", completed: true)
        XCTAssertTrue(p.stopAsCompleted("课_1"))
        XCTAssertEqual(p.position, 0)
        p.pause(); p.saveNow()
        await pause(0.8)
        XCTAssertEqual(store.loadProgress("课_1")?.completed, true, "旧进度不把已听完盖回去")
        p.toggle()
        await until("重新加载出声") { p.isPlaying }
        XCTAssertLessThan(p.position, 1.5, "从头开始")
        p.pause()
    }

    func testStopIfCurrentClears() async throws {
        try download(1, wav(seconds: 8))
        let p = make()
        p.start("课_1", ctx: .series("课"))
        p.stopIfCurrent("课_1")
        await pause(1)
        XCTAssertNil(p.current)
        XCTAssertFalse(p.isPlaying, "加载结果作废，不出声")
        // 正在出声时删掉：按钮不再显示成在播
        p.start("课_1", ctx: .series("课"))
        await until("在出声") { p.isPlaying }
        p.stopIfCurrent("课_1")
        await pause(0.5)
        XCTAssertNil(p.current)
        XCTAssertFalse(p.looksPlaying)
    }

    // MARK: 跳转、倍速

    func testSeekStaysInBounds() async throws {
        try download(1, wav(seconds: 8))
        let p = make()
        p.start("课_1", ctx: .series("课"))
        await until("知道总时长") { p.duration > 7 }
        p.seek(by: -SEEK_BACK_SECONDS)
        XCTAssertEqual(p.position, 0)
        p.seek(by: SEEK_FORWARD_SECONDS)
        XCTAssertEqual(p.position, p.duration, accuracy: 0.01)
        p.pause()
    }

    func testRateCarriesOverToNextEpisode() async throws {
        try download(1, wav(seconds: 8)); try download(2, wav(seconds: 8))
        let p = make()
        p.start("课_1", ctx: .series("课"))
        await until("出声") { p.isPlaying }
        p.setRate(1.5)
        await until("播放器按 1.5 倍播") { p.player.rate == 1.5 }
        p.start("课_2", ctx: .series("课"))
        await until("第 2 集按 1.5 倍播") { p.current?.episodeId == "课_2" && p.player.rate == 1.5 }
        p.pause()
    }

    // MARK: 被打断（来电、导航播报）

    private func interruption(_ type: AVAudioSession.InterruptionType, resume: Bool = false) {
        var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
        if type == .ended { info[AVAudioSessionInterruptionOptionKey] = resume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0 }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: info)
    }

    func testInterruptionEndResumesOnlyIfUserWantedToListen() async throws {
        try download(1, wav(seconds: 10))
        let p = make()
        p.start("课_1", ctx: .series("课"))
        await until("出声") { p.isPlaying }
        // 系统停下播放器（不经过 App）
        p.player.pause(); interruption(.began)
        await until("停下") { !p.isPlaying }
        interruption(.ended, resume: true)
        await until("打断结束接着播") { p.isPlaying }
        // 系统没建议恢复：不播
        p.player.pause(); interruption(.began)
        await until("停下") { !p.isPlaying }
        interruption(.ended, resume: false)
        await pause(0.8)
        XCTAssertFalse(p.isPlaying)
        // 用户自己点了暂停：打断结束也不播
        p.resume()
        await until("出声") { p.isPlaying }
        p.pause(); interruption(.began)
        interruption(.ended, resume: true)
        await pause(0.8)
        XCTAssertFalse(p.isPlaying)
    }
}
