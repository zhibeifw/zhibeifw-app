import XCTest
@testable import ZhibeiFW

// 与 Android 的 LogicTest.kt 同一批用例。

final class VersionTests: XCTestCase {
    func testWholeFileResponse() {
        XCTAssertTrue(isWholeFileResponse(status: 200, contentRange: nil))
        XCTAssertTrue(isWholeFileResponse(status: 206, contentRange: "bytes 0-51605985/51605986"))
        XCTAssertTrue(isWholeFileResponse(status: 206, contentRange: nil))
        XCTAssertFalse(isWholeFileResponse(status: 206, contentRange: "bytes 1000-51605985/51605986"))
        XCTAssertFalse(isWholeFileResponse(status: 404, contentRange: nil))
    }
}

final class FormatTests: XCTestCase {
    func testClock() {
        XCTAssertEqual(clock(.nan), "00:00")
        XCTAssertEqual(sleepLabel(1791), "zZ 29:51")
        XCTAssertEqual(sleepLabel(nil), "zZ 本集结束")
    }
    func testPill() {
        XCTAssertEqual(pillState(nil), PillState(kind: .new, text: "播放"))
        XCTAssertEqual(pillState(nil, knownDuration: 3710), PillState(kind: .new, text: "62 分钟"))
        XCTAssertEqual(pillState(Prog(position: 100, duration: 960, completed: false)), PillState(kind: .half, text: "剩 14:20"))
        XCTAssertEqual(pillState(Prog(position: 0, duration: 3710, completed: true)), PillState(kind: .done, text: "62 分钟"))
        XCTAssertEqual(pillState(Prog(position: 0, duration: 0, completed: true)), PillState(kind: .done, text: "已听完"))
        XCTAssertEqual(progressRatio(5, 0), 0)
        XCTAssertEqual(progressRatio(50, 10), 1)
    }
    func testLiveProgress() {
        let db = Prog(position: 10, duration: 100, completed: false)
        XCTAssertEqual(
            liveProgress(currentId: "a", position: 50, duration: 100, active: true, episodeId: "a", fromDb: db),
            Prog(position: 50, duration: 100, completed: false))
        XCTAssertEqual(liveProgress(currentId: "b", position: 50, duration: 100, active: true, episodeId: "a", fromDb: db), db)
        XCTAssertEqual(liveProgress(currentId: "a", position: 0, duration: 0, active: true, episodeId: "a", fromDb: db), db)
        let done = Prog(position: 0, duration: 100, completed: true)
        XCTAssertEqual(liveProgress(currentId: "a", position: 0, duration: 100, active: false, episodeId: "a", fromDb: done), done)
        XCTAssertEqual(
            liveProgress(currentId: "a", position: 3, duration: 100, active: true, episodeId: "a", fromDb: done)?.completed, false)
    }
    func testCardLayout() {
        XCTAssertEqual(Layout.cardWidths(390, 844).large, 322)
        XCTAssertEqual(Layout.cardWidths(390, 844).small, 238)
        XCTAssertEqual(Layout.cardWidths(393, 852).large, 325)
        // 平板一屏固定张数：竖屏大 2.2、小 3.5；横屏大 3.2、小 4.5
        XCTAssertEqual(Layout.cardWidths(1032, 1376).large, 442)
        XCTAssertEqual(Layout.cardWidths(1032, 1376).small, 273)
        XCTAssertEqual(Layout.cardWidths(1376, 1032).large, 408)
        XCTAssertEqual(Layout.cardWidths(1376, 1032).small, 286)
        XCTAssertEqual(Layout.cardWidths(744, 1133).small, 191)
        XCTAssertEqual(Layout.tileColumns(700), 4)
        XCTAssertEqual(Layout.seriesRowCoverWidth(390), 172)
    }
}

final class ValidateTests: XCTestCase {
    func testDomains() {
        XCTAssertEqual(
            parseDomains(
                #"{"domains":["https://a.org","http://b.org","https://a.org","https://c.org"],"fallbackIps":["https://1.2.3.4"]}"#)?
                .domains, ["https://a.org", "https://c.org"])
        let many = (0..<15).map { "\"https://d\($0).org\"" }.joined(separator: ",")
        XCTAssertEqual(parseDomains("{\"domains\":[\(many)]}")?.domains.count, 10)
        XCTAssertNil(parseDomains(#"{"domains":[]}"#))
        XCTAssertNil(parseDomains("<html>"))
        XCTAssertNil(parseDomains(#"{"domains":["https://a.org"],"x":""# + String(repeating: "a", count: 11000) + #""}"#))
    }
    func testIndex() {
        let text = """
            {"featured":[{"title":"新人入门","seriesId":"入中论讲解"},{"title":"","seriesId":"x"}],
             "categories":[
              {"id":"中观","name":"中观","icon":"infinite-outline","color":"brown","series":[
                {"id":"入中论讲解","title":"入中论讲解","coverPath":"中观/入中论讲解/cover.jpg","status":"ongoing","updatedAt":1792232480,"description":"  简介  ",
                 "episodes":[{"id":"入中论讲解_01","title":"第1课","audioPath":"中观/入中论讲解/第1课.mp3","duration":3660},
                             {"id":"入中论讲解_01","title":"重复","audioPath":"x.mp3"},
                             {"id":"bad id","title":"x","audioPath":"x.mp3"},
                             {"id":"入中论讲解_02","title":"第2课","audioPath":"中观/入中论讲解/第2课.mp3","duration":"abc"}]},
                {"id":"bad","title":"t","coverPath":"/abs.jpg","status":"ongoing"},
                {"id":"s2","title":"t2","coverPath":"c.jpg","status":"paused"},
                {"id":"s3","title":"t3","coverPath":"c.jpg","status":"completed","updatedAt":1792232480000}]},
              {"id":"初学","name":"初学","icon":"Bad Icon","color":"gold","series":[]},
              {"id":"中观","name":"重复","series":[]}]}
            """
        let r = parseIndex(text)!
        XCTAssertEqual(r.categories.map(\.id), ["中观", "初学"])
        XCTAssertEqual(r.categories[0].icon, "infinite-outline")
        XCTAssertNil(r.categories[1].icon)
        XCTAssertNil(r.categories[1].color)
        XCTAssertEqual(r.series.map(\.id), ["入中论讲解", "s3"])
        XCTAssertEqual(r.series[0].episodes.map(\.id), ["入中论讲解_01", "入中论讲解_02"])
        XCTAssertEqual(r.series[0].episodes[0].duration, 3660)
        XCTAssertNil(r.series[0].episodes[1].duration)
        XCTAssertEqual(r.series[0].updatedAt, 1792232480)
        XCTAssertNil(r.series[1].updatedAt)  // 毫秒不采用
        XCTAssertEqual(r.featured, [FeaturedEntry(title: "新人入门", seriesId: "入中论讲解")])
        XCTAssertNil(parseIndex(#"{"categories":[]}"#))
        XCTAssertNil(parseIndex(#"{"categories":[{"id":"a","name":"a","series":[{"id":"bad id"}]}]}"#))
        XCTAssertNotNil(parseIndex(#"{"categories":[{"id":"a","name":"a","series":[]}]}"#))
        XCTAssertNil(parseIndex("not json"))
        XCTAssertEqual(r.categoryOrder, [])  // 没写就是空的，分类页跟 categories 一样
    }
    /// 分类页的先后 categoryOrder：只收合规的 ID，去重；不是数组就当没有
    func testIndexCategoryOrder() {
        let base = #"{"categories":[{"id":"a","name":"a","series":[]},{"id":"b","name":"b","series":[]}],"#
        XCTAssertEqual(parseIndex(base + #""categoryOrder":["b","bad id",3,"a","b","新分类"]}"#)?.categoryOrder, ["b", "a", "新分类"])
        XCTAssertEqual(parseIndex(base + #""categoryOrder":"b"}"#)?.categoryOrder, [])
    }
    func testUpgrade() {
        XCTAssertNotNil(parseUpgrade(#"{"latestVersion":"1.10.0","minVersion":"1.9.0","apkPath":"releases/a.apk"}"#))
        XCTAssertNil(parseUpgrade(#"{"latestVersion":"1.0.0","minVersion":"1.1.0","apkPath":"releases/a.apk"}"#))
        XCTAssertNil(parseUpgrade(#"{"latestVersion":"1.0.0","minVersion":"1.0.0","apkPath":"other/a.apk"}"#))
        XCTAssertNil(parseUpgrade(#"{"latestVersion":"v1","minVersion":"1.0.0","apkPath":"releases/a.apk"}"#))
    }
    func testCategoryStyle() {
        XCTAssertEqual(resolveCategoryColor("blue", id: "x"), Tok.ContentPalette.colors[1])
        XCTAssertEqual(resolveCategoryColor("random", id: "中观"), placeholderColor("中观"))
        // 分类方块多出的 10 种：名字和颜色一一对应，18 种互不相同；封面占位色块仍只在前 8 种里取
        XCTAssertEqual(Tok.ContentPalette.categoryExtraColors.count, CATEGORY_EXTRA_COLOR_NAMES.count)
        XCTAssertEqual(resolveCategoryColor("red", id: "x"), Tok.ContentPalette.categoryExtraColors[0])
        XCTAssertEqual(resolveCategoryColor("charcoal", id: "x"), Tok.ContentPalette.categoryExtraColors[9])
        XCTAssertEqual(Set(Tok.ContentPalette.colors + Tok.ContentPalette.categoryExtraColors).count, 18)
        XCTAssertTrue(isValidColorSetting("wine")); XCTAssertFalse(isValidColorSetting("gold"))
        XCTAssertEqual(Tok.ContentPalette.colors.count, 8)
        XCTAssertEqual(resolveCategoryIcon("infinite-outline", id: "x"), "infinite-outline")
        XCTAssertEqual(resolveCategoryIcon("no-such-icon", id: "x"), DEFAULT_ICON)
        XCTAssertEqual(resolveCategoryIcon(nil, id: "x"), DEFAULT_ICON)
        XCTAssertEqual(resolveCategoryIcon("random", id: "中观"), resolveCategoryIcon("random", id: "中观"))
        for i in RANDOM_ICONS + [DEFAULT_ICON] { XCTAssertTrue(Icons.exists(i), i) }  // 备选和默认图标都确实存在
    }
}

final class FileKeyTests: XCTestCase {
    func testOrphans() {
        XCTAssertEqual(orphanCoverKeys([fileKey("中观"), "y"], seriesWithDownloads: ["中观"]), ["y"])
        XCTAssertEqual(orphanAudioNames(["a.mp3", "x.mp3"], keep: ["a.mp3", "b.m4a"]), ["x.mp3"])
        XCTAssertTrue(isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
        XCTAssertTrue(
            isOutOfSpace(
                NSError(
                    domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])))
        XCTAssertFalse(isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
    }
}

final class DownloadLogicTests: XCTestCase {
    func testProgressThrottle() {
        let t = ProgressThrottle()
        let d = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(t.pass(written: 0, total: 100, now: d))  // 第一次放行
        XCTAssertFalse(t.pass(written: 5, total: 100, now: d.addingTimeInterval(0.1)))  // 不到 0.25 秒
        XCTAssertFalse(t.pass(written: 0, total: 1000, now: d.addingTimeInterval(1)))  // 不到 1%
        XCTAssertTrue(t.pass(written: 50, total: 1000, now: d.addingTimeInterval(1)))
    }
}

final class InteractionTests: XCTestCase {
    func testPushGuard() {
        var now = 0.0
        let g = PushGuard(windowMs: 700) { now }
        XCTAssertTrue(g.allow("a")); XCTAssertFalse(g.allow("a")); XCTAssertTrue(g.allow("b"))
        now = 800; XCTAssertTrue(g.allow("a"))
    }
    func testUpdate() {
        let u = UpgradeFile(latestVersion: "1.10.0", minVersion: "1.2.0", apkPath: "releases/a.apk")
        XCTAssertEqual(decideUpdate(current: "1.9.0", u, channel: .site), .optional(version: "1.10.0", apkPath: "releases/a.apk"))
        XCTAssertEqual(decideUpdate(current: "1.9.0", u, channel: .store), .none)
        XCTAssertEqual(decideUpdate(current: "1.1.0", u, channel: .store), .outdated(version: "1.10.0", apkPath: "releases/a.apk"))
        XCTAssertEqual(decideUpdate(current: "1.10.0", u, channel: .site), .none)
        XCTAssertEqual(decideUpdate(current: "bad", u, channel: .site), .none)
        XCTAssertTrue(shouldAutoCheck(lastCheckedAt: nil, now: 0))
        XCTAssertFalse(shouldAutoCheck(lastCheckedAt: 0, now: CHECK_INTERVAL_MS - 1))
    }
    func testSyncPolicy() {
        XCTAssertTrue(shouldSyncOnForeground(now: 60_000, lastSyncAt: 0, syncing: false))
        XCTAssertFalse(shouldSyncOnForeground(now: 59_999, lastSyncAt: 0, syncing: false))
        XCTAssertFalse(shouldSyncOnForeground(now: 99_999, lastSyncAt: 0, syncing: true))
        XCTAssertEqual(launchFreshWaitMs(online: false, elapsedMs: 10), 0)
        XCTAssertEqual(launchFreshWaitMs(online: true, elapsedMs: 1000), 2000)
        XCTAssertEqual(launchFreshWaitMs(online: true, elapsedMs: 5000), 0)
    }
    func testSleepChoices() {
        XCTAssertEqual(SLEEP_CHOICES.map(\.title), ["单集结束时", "1 小时", "45 分钟", "30 分钟", "15 分钟", "10 分钟", "5 分钟", "关闭"])
        XCTAssertEqual(SleepSetting.timer(deadline: 0, minutes: 30).choiceId, "m30")
        XCTAssertEqual(SleepSetting.timer(deadline: 100, minutes: 1).secondsLeft(now: 40.2), 60)
        XCTAssertEqual(SleepSetting.timer(deadline: 100, minutes: 1).secondsLeft(now: 130), 0)
        XCTAssertNil(SleepSetting.end.secondsLeft(now: 0))
        XCTAssertEqual(pickNext(["a", "b", "c"], current: "b"), "c")
        XCTAssertNil(pickNext(["a", "b"], current: "b"))
        XCTAssertNil(pickNext(["a"], current: "x"))
    }
    func testDownloadMenu() {
        XCTAssertEqual(downloadMenuItems(nil).map(\.title), ["下载"])
        XCTAssertEqual(downloadMenuItems(.downloading).map(\.title), ["暂停下载", "取消下载"])
        XCTAssertEqual(downloadMenuItems(.paused).map(\.title), ["继续下载", "取消下载"])
        XCTAssertEqual(downloadMenuItems(.done).map(\.title), ["删除下载"])
        XCTAssertEqual(downloadMenuItems(nil, canDownload: false), [])
    }
    func testNormalize() {
        XCTAssertEqual(orderOrigins(remembered: "b", saved: ["a", "b"], builtin: ["c", "a"]), ["b", "a", "c"])
    }
}

final class RaceTests: XCTestCase {
    func testFirstFastWins() async {
        let r = await pickFirstReachable(["a", "b"], staggerMs: 1500) { (o: String) async -> Int? in o == "a" ? 1 : 2 }
        XCTAssertEqual(r?.origin, "a")
    }
    func testStaggerThenSecondWins() async {
        let t0 = Date()
        let r = await pickFirstReachable(["slow", "fast"], staggerMs: 100) { (o: String) async -> Int? in
            if o == "slow" { try? await Task.sleep(nanoseconds: 2_000_000_000); return 1 }
            return 2
        }
        XCTAssertEqual(r?.origin, "fast")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0)
    }
    func testFailureMovesOnImmediately() async {
        let t0 = Date()
        let r = await pickFirstReachable(["bad", "good"], staggerMs: 5000) { (o: String) async -> Int? in o == "bad" ? nil : 1 }
        XCTAssertEqual(r?.origin, "good")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0)
    }
    func testAllFail() async {
        let r = await pickFirstReachable(["a", "b", "c"], staggerMs: 10) { (_: String) async -> Int? in nil }
        XCTAssertNil(r)
        let e = await pickFirstReachable([], staggerMs: 10) { (_: String) async -> Int? in 1 }
        XCTAssertNil(e)
    }

    func testCoverBucketRoundsUpTo256() {
        XCTAssertEqual(coverBucket(0), 256)
        XCTAssertEqual(coverBucket(256), 256)
        XCTAssertEqual(coverBucket(257), 512)
        // 封面小图
        let p = "中观/入中论讲解/cover.jpg"
        XCTAssertEqual(coverThumbPath(p, width: 640), "中观/入中论讲解/cover-640.jpg")
        XCTAssertEqual(coverSourcePath(p, requestedPx: 108), "中观/入中论讲解/cover-320.jpg")
        XCTAssertEqual(coverSourcePath(p, requestedPx: 320), "中观/入中论讲解/cover-320.jpg")
        XCTAssertEqual(coverSourcePath(p, requestedPx: 564), "中观/入中论讲解/cover-640.jpg")
        XCTAssertEqual(coverSourcePath(p, requestedPx: 641), p)
        XCTAssertEqual(coverThumbPath("a.b/cover", width: 320), "a.b/cover")  // 没有扩展名就不动
        XCTAssertEqual(coverBucket(1206), 1280)
    }

    func testLibraryCountText() {
        XCTAssertEqual(libraryCountText(total: 3, done: 3), "3 节")
        XCTAssertEqual(libraryCountText(total: 3, done: 1), "3 节 · 已下载 1 节")
        XCTAssertEqual(libraryCountText(total: 2, done: 0), "2 节 · 已下载 0 节")
        XCTAssertEqual(libraryCountLines(total: 3, done: 3), ["3 节"])
        XCTAssertEqual(libraryCountLines(total: 3, done: 1), ["3 节", "已下载 1 节"])
    }
}

final class ImageLoaderTests: XCTestCase {
    /// 有本地封面时取过一次，同步查内存要能命中（不再每次进页面重新读文件、解码）
    func testLocalCoverHitsMemory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("il-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let loader = ImageLoader(diskDir: dir.appendingPathComponent("cache"))
        let local = dir.appendingPathComponent("cover.png")
        let img = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 36)).image { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        }
        try img.pngData()!.write(to: local)
        XCTAssertNil(loader.cached("c/s/cover.jpg", maxPixel: 320, local: true))
        let loaded = await loader.load("c/s/cover.jpg", maxPixel: 320, localFile: local)
        XCTAssertNotNil(loaded)
        XCTAssertNotNil(loader.cached("c/s/cover.jpg", maxPixel: 320, local: true))
    }
}

final class NearEndTests: XCTestCase {
    /// 不到 30 秒的短音频按播到 95% 算听完，不是一开始就算
    func testShortAudio() {
        XCTAssertFalse(isNearEnd(0, 20))
        XCTAssertFalse(isNearEnd(10, 20))
        XCTAssertTrue(isNearEnd(19, 20))
        XCTAssertFalse(isNearEnd(0, 31))
        XCTAssertTrue(isNearEnd(1, 31))
        XCTAssertTrue(isNearEnd(3570, 3600))
        XCTAssertFalse(isNearEnd(0, 0))
    }
}

final class BadNumberTests: XCTestCase {
    /// 库里有无穷大、NaN、超大值时不崩
    func testNonFiniteDoesNotCrash() {
        XCTAssertEqual(clock(.infinity), "00:00")
        XCTAssertEqual(clock(.nan), "00:00")
        XCTAssertFalse(clock(1e300).isEmpty)
        XCTAssertFalse(pillState(Prog(position: 0, duration: .infinity, completed: false)).text.isEmpty)
        XCTAssertFalse(pillState(nil, knownDuration: 1e300).text.isEmpty)
        XCTAssertNil(Row(values: ["x": .double(.infinity)]).optInt("x"))
        XCTAssertNil(Row(values: ["x": .double(1e300)]).optInt("x"))
        XCTAssertEqual(Row(values: ["x": .double(3.9)]).optInt("x"), 3)
    }
}
