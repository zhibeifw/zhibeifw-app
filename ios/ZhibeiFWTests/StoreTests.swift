import XCTest
#if os(iOS)
import Intents
#endif
#if os(watchOS)
@testable import ZhibeiFWWatch
#else
@testable import ZhibeiFW
#endif

// 数据库：建表与迁移、目录写库、搜索、用户表状态规则、下载对账。

final class StoreTests: XCTestCase {
    var dir: URL!
    var db: SQLiteDB!
    var store: Store!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try SQLiteDB(path: dir.appendingPathComponent("t.db").path)
        _ = try Migrator.migrate(db)
        store = Store(db: db)
    }
    override func tearDownWithError() throws {
        store = nil; db = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func index(_ series: [(String, String, String, [String])], featured: [FeaturedEntry] = []) -> IndexFile {
        // (id, 分类, 状态, 各集标题)
        var cats: [CategoryEntry] = []
        for s in series where !cats.contains(where: { $0.id == s.1 }) {
            cats.append(CategoryEntry(id: s.1, name: s.1, icon: nil, color: nil))
        }
        return IndexFile(
            categories: cats,
            series: series.map { s in
                SeriesEntry(
                    id: s.0, title: s.0, categoryId: s.1, coverPath: "\(s.1)/\(s.0)/cover.jpg", status: s.2, description: nil,
                    episodes: s.3.enumerated().map {
                        EpisodeEntry(
                            id: "\(s.0)_\($0.offset + 1)", title: $0.element, audioPath: "\(s.1)/\(s.0)/\($0.element).mp3", duration: 600)
                    },
                    updatedAt: nil)
            }, featured: featured)
    }

    #if !os(tvOS)
    func testSiriEpisodeUsesTitleNotListPosition() throws {
        try store.replaceIndex(index([("论语", "儒学", "ongoing", ["导言", "第10课", "第100课"])]))
        XCTAssertEqual(try store.siriEpisodes(matching: "论语 第10课").map(\.id), ["论语_2"])
        XCTAssertEqual(try store.siriEpisodes(matching: "论语第十集").map(\.id), ["论语_2"])
        XCTAssertEqual(try store.siriEpisodes(matching: "论语010").map(\.id), ["论语_2"])
        XCTAssertTrue(try store.siriEpisodes(matching: "论语第2集").isEmpty)
        XCTAssertTrue(try store.siriEpisodes(matching: "论语第1课").isEmpty)
        XCTAssertTrue(try store.siriEpisodes(matching: "另一门课第10课").isEmpty)
        XCTAssertTrue(try store.siriEpisodes(matching: "").isEmpty)
    }

    func testSiriAmbiguousEpisodeKeepsAllMatches() throws {
        try store.replaceIndex(index([("论语", "儒学", "ongoing", ["第1课", "第1课"])]))
        XCTAssertEqual(try store.siriEpisodes(matching: "论语第1课").count, 2)
    }
    #endif

    #if os(iOS)
    private func mediaIntent(_ title: String? = nil, id: String? = nil) -> INPlayMediaIntent {
        let items = title == nil && id == nil ? nil : [INMediaItem(identifier: id, title: title, type: .unknown, artwork: nil)]
        return INPlayMediaIntent(mediaItems: items, mediaContainer: nil, playShuffled: nil,
                                 playbackRepeatMode: .none, resumePlayback: nil,
                                 playbackQueueLocation: .now, playbackSpeed: nil, mediaSearch: nil)
    }

    func testMediaIntentRequiresEpisodeForCourseName() throws {
        try store.replaceIndex(index([("论语", "儒学", "ongoing", ["第1课", "第10课"])]))
        guard case .items(let items, let needsChoice) = try SiriMediaSelection.resolve(mediaIntent("论语"), store: store)
        else { return XCTFail("应该询问集数") }
        XCTAssertTrue(needsChoice)
        XCTAssertEqual(items.count, 2)
        guard case .items(let selected, let more) = try SiriMediaSelection.resolve(mediaIntent(id: items[1].identifier), store: store)
        else { return XCTFail("应解析用户选中的集") }
        XCTAssertFalse(more)
        XCTAssertEqual(selected.first?.identifier, "episode:论语_2")
    }

    func testMediaIntentExplicitEpisodeAndResume() throws {
        try store.replaceIndex(index([("论语", "儒学", "ongoing", ["第1课", "第10课"])]))
        guard case .items(let items, let needsChoice) = try SiriMediaSelection.resolve(mediaIntent("论语第十集"), store: store)
        else { return XCTFail("应解析指定集数") }
        XCTAssertFalse(needsChoice)
        XCTAssertEqual(items.first?.identifier, "episode:论语_2")
        guard case .resume = try SiriMediaSelection.resolve(mediaIntent(), store: store)
        else { return XCTFail("无指定内容时继续播放") }
        guard case .missing = try SiriMediaSelection.resolve(mediaIntent("论语第999集"), store: store)
        else { return XCTFail("不存在的集数不能换播另一集") }
        guard case .missing = try SiriMediaSelection.resolve(mediaIntent(id: "unknown"), store: store)
        else { return XCTFail("无效标识不能变成继续播放") }
    }

    func testMediaIntentSingleEpisodeCourseStillAsks() throws {
        try store.replaceIndex(index([("论语", "儒学", "ongoing", ["第1课"])]))
        guard case .items(_, let needsChoice) = try SiriMediaSelection.resolve(mediaIntent("论语"), store: store)
        else { return XCTFail("应询问用户") }
        XCTAssertTrue(needsChoice)
    }
    #endif

    func testMigrateFreshAndIdempotent() throws {
        XCTAssertEqual(db.userVersion, 3)
        let again = try Migrator.migrate(db)
        XCTAssertEqual(again.userVersion, 3)
        XCTAssertEqual(again.catalogVersion, 7)
        XCTAssertFalse(again.catalogRebuilt)
    }

    func testUserTablesFromV1Kept() throws {
        // 模拟 v1.0 的 user_version = 1 的库，升级后旧数据完整保留
        let p = dir.appendingPathComponent("old.db").path
        let old = try SQLiteDB(path: p)
        try old.transaction {
            try Schema.user[0].up(old); try old.setUserVersion(1)
        }
        try old.run("INSERT INTO user_favorite (series_id, added) VALUES (?, ?)", ["s1", 5])
        try old.run(
            "INSERT INTO user_progress (episode_id, series_id, position, duration, completed, hidden, last_played, updated) VALUES ('e1','s1',10,100,0,0,1,1)"
        )
        var backedUp = false
        _ = try Migrator.migrate(old, beforeUserMigration: { _, _ in backedUp = true })
        XCTAssertTrue(backedUp)
        XCTAssertEqual(old.userVersion, 3)
        let s = Store(db: old)
        XCTAssertEqual(try s.loadFavorites().first?.title, "已下架的课程")
        XCTAssertEqual(s.loadProgress("e1")?.position, 10)
    }

    func testReplaceIndexAndHome() throws {
        try store.replaceIndex(
            index([("入中论讲解", "中观", "ongoing", ["第1课", "第2课"]), ("中观根本慧论", "中观", "completed", ["第1课"]), ("净土教言", "净土", "completed", [])]))
        let h = try store.loadHome()
        XCTAssertEqual(h.ongoing.map(\.id), ["入中论讲解"])
        XCTAssertEqual(h.ongoing.first?.lastTitle, "第2课")
        XCTAssertEqual(h.categories.map(\.id), ["中观", "净土"])
        XCTAssertTrue(h.featured.isEmpty)
        // 只写变了的课：再同步一次同样内容，不出错、结果一样
        try store.replaceIndex(index([("入中论讲解", "中观", "ongoing", ["第1课", "第2课", "第3课"]), ("中观根本慧论", "中观", "completed", ["第1课"])]))
        XCTAssertEqual(try store.loadEpisodes("入中论讲解").count, 3)
        XCTAssertNil(try store.loadSeriesHeader("净土教言"))  // 下架的课清掉
    }

    #if !os(watchOS)
    /// 小组件自己读 index.json 得到的“最新课程”，必须和 App 写库后主页的“新课程”一样：同样的课、同样的先后、同样的最后一集
    func testWidgetLatestMatchesHome() throws {
        let json = #"""
        {"categories":[
          {"id":"中观","name":"中观","series":[
            {"id":"甲","title":"甲课","coverPath":"a/c.jpg","status":"ongoing","updatedAt":100,"episodes":[{"id":"甲_1","title":"第1课","audioPath":"a/1.mp3"},{"id":"甲_2","title":"第2课","audioPath":"a/2.mp3"}]},
            {"id":"乙","title":"乙课","coverPath":"b/c.jpg","status":"ongoing","episodes":[{"id":"乙_1","title":"第1课","audioPath":"b/1.mp3"}]},
            {"id":"丙","title":"丙课","coverPath":"c/c.jpg","status":"completed","updatedAt":999,"episodes":[{"id":"丙_1","title":"第1课","audioPath":"c/1.mp3"}]},
            {"id":"丁","title":"丁课","coverPath":"d/c.jpg","status":"ongoing","updatedAt":300,"episodes":[{"id":"丁_1","title":"第1课","audioPath":"d/1.mp3"},{"id":"丁_2","title":"坏的一集","audioPath":"/abs.mp3"}]}
          ]},
          {"id":"净土","name":"净土","series":[
            {"id":"戊","title":"戊课","coverPath":"e/c.jpg","status":"ongoing","updatedAt":300,"episodes":[{"id":"戊_1","title":"第1课","audioPath":"e/1.mp3"}]},
            {"id":"己","title":"己课","coverPath":"f/c.jpg","status":"ongoing","episodes":[{"id":"己_1","title":"第1课","audioPath":"f/1.mp3"}]},
            {"id":"坏","title":"","coverPath":"g/c.jpg","status":"ongoing","episodes":[]}
          ]}
        ]}
        """#
        let data = Data(json.utf8)
        try store.replaceIndex(try XCTUnwrap(parseIndex(data)))
        let home = try store.loadHome().ongoing.prefix(WidgetCatalog.latestLimit)
        let widget = try XCTUnwrap(WidgetCatalog.parseLatest(data))
        XCTAssertEqual(widget.map(\.id), home.map(\.id))
        XCTAssertEqual(widget.map(\.id), ["丁", "戊", "甲", "乙", "己"])
        XCTAssertEqual(widget.map(\.lastId), home.map { store.lastEpisode($0.id)?.id ?? "" })
        XCTAssertEqual(widget.first?.lastTitle, "第1课")  // 不合规的那一集丢掉
    }

    /// 分类页按 categoryOrder 排，主页仍按 categories；清单里没有的排后面；index.json 去掉清单后回到 categories 的先后
    #endif

    func testCategoryOrderOnlyForCategoryPage() throws {
        var idx = index([("课1", "中观", "completed", []), ("课2", "净土", "completed", []), ("课3", "基础", "completed", [])])
        idx.categoryOrder = ["基础", "中观", "不存在"]
        try store.replaceIndex(idx)
        XCTAssertEqual(try store.loadCategories().map(\.id), ["基础", "中观", "净土"])
        XCTAssertEqual(try store.loadHome().categories.map(\.id), ["中观", "净土", "基础"])
        idx.categoryOrder = []
        try store.replaceIndex(idx)
        XCTAssertEqual(try store.loadCategories().map(\.id), ["中观", "净土", "基础"])
    }

    func testSearch() throws {
        try store.replaceIndex(
            index([("入行论广释", "中观", "completed", []), ("入中论讲解", "中观", "completed", []), ("大圆满前行", "实修", "completed", [])]))
        XCTAssertEqual(try store.searchSeries("入中论").rows.map(\.id), ["入中论讲解"])
        let fb = try store.searchSeries("入行论第54课")
        XCTAssertTrue(fb.fallback); XCTAssertEqual(fb.matched, "入行论"); XCTAssertEqual(fb.rows.map(\.id), ["入行论广释"])
        XCTAssertEqual(try store.searchSeries("入行轮").matched, "入行")
        XCTAssertTrue(try store.searchSeries("xyz").rows.isEmpty)
        XCTAssertTrue(try store.searchSeries("%' OR 1=1 --").rows.isEmpty)  // 注入只当文字
        XCTAssertTrue(try store.searchSeries("").rows.isEmpty)
        XCTAssertEqual(try store.searchSeries("满").rows.map(\.id), ["大圆满前行"])
    }

    /// 拼音搜索（苹果两端才有，Android 还没有）。
    func testPinyinSearch() throws {
        try store.replaceIndex(
            index([("金刚经讲记", "般若", "completed", []), ("心经", "般若", "completed", []), ("大圆满前行", "实修", "completed", [])]))
        XCTAssertEqual(try store.searchSeries("jgj").rows.map(\.id), ["金刚经讲记"])
        XCTAssertEqual(try store.searchSeries("JGJ").rows.map(\.id), ["金刚经讲记"])  // 大小写都行
        XCTAssertEqual(try store.searchSeries("dymqx").rows.map(\.id), ["大圆满前行"])
        XCTAssertEqual(try store.searchSeries("xinjing").rows.map(\.id), ["心经"])
        XCTAssertEqual(try store.searchSeries("xin jing").rows.map(\.id), ["心经"])  // 空格不算
        // 全拼：开头的排在包含的前面
        XCTAssertEqual(try store.searchSeries("jing").rows.map(\.id), ["金刚经讲记", "心经"])
        XCTAssertTrue(try store.searchSeries("q").rows.isEmpty)  // 一个字母不按拼音找
        XCTAssertTrue(try store.searchSeries("zzz").rows.isEmpty)
        // 目录换了，拼音缓存要跟着换
        try store.replaceIndex(index([("入菩萨行论", "中观", "completed", [])]))
        XCTAssertTrue(try store.searchSeries("jgj").rows.isEmpty)
        XCTAssertEqual(try store.searchSeries("rpsx").rows.map(\.id), ["入菩萨行论"])
    }

    func testRecentRules() throws {
        try store.replaceIndex(index([("课A", "中观", "completed", ["一", "二"])]))
        try store.recordPlayback(episodeId: "课A_1", seriesId: "课A", position: 10, duration: 600, at: 1)
        try store.recordPlayback(episodeId: "课A_2", seriesId: "课A", position: 10, duration: 600, at: 2)
        XCTAssertEqual(try store.loadRecent().map(\.episodeId), ["课A_2", "课A_1"])
        // 距结尾 30 秒内算听完、位置归零
        XCTAssertTrue(try store.recordPlayback(episodeId: "课A_1", seriesId: "课A", position: 580, duration: 600, at: 3))
        XCTAssertEqual(store.loadProgress("课A_1"), Prog(position: 0, duration: 600, completed: true))
        // 标记不更新最后播放时间、不改变去留
        try store.markCompleted("课A_2", seriesId: "课A", completed: true)
        XCTAssertEqual(try store.loadRecent().map(\.episodeId), ["课A_1", "课A_2"])
        // 此前没有记录就标记：新建一行但不出现在最近
        try store.markCompleted("x", seriesId: "y", completed: true)
        XCTAssertFalse(try store.loadRecent().contains { $0.episodeId == "x" })
        // 删除记录只是隐藏；再播放才回来
        try store.hideFromRecent("课A_1")
        XCTAssertEqual(try store.loadRecent().map(\.episodeId), ["课A_2"])
        XCTAssertEqual(store.loadProgress("课A_1")?.completed, true)
        try store.recordPlayback(episodeId: "课A_1", seriesId: "课A", position: 5, duration: 600, at: 9)
        XCTAssertEqual(try store.loadRecent().first?.episodeId, "课A_1")
        XCTAssertEqual(store.loadProgress("课A_1")?.completed, false)  // 重新播放清除已听完
        try store.clearRecent()
        XCTAssertTrue(try store.loadRecent().isEmpty)
    }

    func testGoneEpisodesStillShown() throws {
        try store.recordPlayback(
            episodeId: "e9", seriesId: "s9", position: 5, duration: 60, seriesTitle: "旧课", episodeTitle: "第9课", coverPath: "c.jpg")
        let r = try store.loadRecent().first!
        XCTAssertTrue(r.gone); XCTAssertEqual(r.seriesTitle, "旧课"); XCTAssertEqual(r.epTitle, "第9课"); XCTAssertNil(r.audioPath)
        // 空标题保存不会冲掉已有的
        try store.recordPlayback(episodeId: "e9", seriesId: "s9", position: 6, duration: 60)
        XCTAssertEqual(try store.loadRecent().first?.seriesTitle, "旧课")
    }

    func testFavorites() throws {
        try store.addFavorite("a", title: "A", at: 1)
        try store.addFavorite("b", title: "B", at: 2)
        XCTAssertEqual(try store.loadFavorites().map(\.id), ["b", "a"])
        try store.addFavorite("a", at: 9)  // 已收藏时再收藏不改时间
        XCTAssertEqual(try store.loadFavorites().map(\.id), ["b", "a"])
        try store.removeFavorite("a"); try store.addFavorite("a", at: 10)
        XCTAssertEqual(try store.loadFavorites().map(\.id), ["a", "b"])
        XCTAssertTrue(try store.loadFavorites()[0].gone)
    }

    func testDownloadStates() throws {
        let items = [
            DlItem(episodeId: "e1", seriesId: "s", seriesTitle: "S", episodeTitle: "1", pos: 0, audioPath: "a.mp3"),
            DlItem(episodeId: "e2", seriesId: "s", seriesTitle: "S", episodeTitle: "2", pos: 1, audioPath: "b.mp3"),
            DlItem(episodeId: "e3", seriesId: "s", seriesTitle: "S", episodeTitle: "3", pos: 2, audioPath: "c.mp3"),
        ]
        try store.queuedMany(items)
        try store.setDlInfo("e1", total: 100, validator: nil)
        try store.setDlPaused("e1", bytes: 40)
        try store.setDlDone("e3", localFile: "audio/e3.mp3")
        XCTAssertEqual(store.getDownload("e1")?.state, .paused)
        XCTAssertEqual(store.getDownload("e1")?.bytes, 40)
        XCTAssertEqual(store.getDownload("e1")?.total, 100)
        XCTAssertEqual(store.getDownload("e2")?.state, .queued)
        XCTAssertEqual(store.getDownload("e3")?.state, .done)
        let lib = try store.loadLibrary()
        XCTAssertEqual(lib.first?.n, 3); XCTAssertEqual(lib.first?.paused, 1); XCTAssertEqual(lib.first?.done, 1)
    }

    /// 提交失败（这里用延迟检查的外键）之后，事务层数要回到 0，嵌套事务照常能用
    func testTransactionDepthAfterCommitFailure() throws {
        try db.exec(
            "CREATE TABLE p (id INTEGER PRIMARY KEY); CREATE TABLE c (pid INTEGER REFERENCES p(id) DEFERRABLE INITIALLY DEFERRED); PRAGMA foreign_keys = ON;"
        )
        XCTAssertThrowsError(try db.transaction { try db.run("INSERT INTO c (pid) VALUES (9)") })
        try db.transaction { try db.transaction { try db.run("INSERT INTO p (id) VALUES (1)") } }
        XCTAssertEqual(try db.first("SELECT count(*) AS n FROM p")?.int("n"), 1)
        XCTAssertEqual(try db.first("SELECT count(*) AS n FROM c")?.int("n"), 0)
    }

    /// 别的线程在写库的事务里：读查询不用等它做完，读到的是提交前的内容
    func testReadsDoNotWaitForWriter() throws {
        try store.addFavorite("a", title: "A", at: 1)
        let inTx = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let db = self.db!
        DispatchQueue.global().async {
            try? db.transaction {
                try db.run("INSERT INTO user_favorite (series_id, added) VALUES ('b', 2)")
                inTx.signal()
                Thread.sleep(forTimeInterval: 1)
            }
            done.signal()
        }
        inTx.wait()
        let t0 = Date()
        let n = try db.first("SELECT count(*) AS n FROM user_favorite")?.int("n")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5)
        XCTAssertEqual(n, 1)
        done.wait()
        XCTAssertEqual(try db.first("SELECT count(*) AS n FROM user_favorite")?.int("n"), 2)
    }

    /// 目录换了先后：签名没变的课只改先后
    func testReorderOnlyUpdatesPos() throws {
        try store.replaceIndex(index([("课A", "中观", "completed", ["一"]), ("课B", "中观", "completed", ["一"])]))
        try store.replaceIndex(index([("课B", "中观", "completed", ["一"]), ("课A", "中观", "completed", ["一"])]))
        XCTAssertEqual(try db.all("SELECT id FROM catalog_series ORDER BY pos").map { $0.str("id") }, ["课B", "课A"])
    }

    func testBackup() throws {
        try store.addFavorite("a", title: "A")
        let p = dir.appendingPathComponent("bak.db").path
        try Migrator.backupUserTables(db, to: p)
        try Migrator.backupUserTables(db, to: p)  // 再备份一次是覆盖
        let b = try SQLiteDB(path: p)
        XCTAssertEqual(try b.first("SELECT count(*) AS n FROM user_favorite")?.int("n"), 1)
    }
}
