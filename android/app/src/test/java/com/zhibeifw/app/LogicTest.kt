package com.zhibeifw.app

import com.zhibeifw.app.core.*
import com.zhibeifw.app.design.generated.IconData
import com.zhibeifw.app.design.generated.Tok
import com.zhibeifw.app.net.pickFirstReachable
import com.zhibeifw.app.ui.Layout
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// 与 iOS 的 LogicTests.swift 同一批用例。

class VersionTest {
    @Test
    fun compare() {
        assertEquals(1, compareVersions("1.10.0", "1.9.0"))
        assertEquals(0, compareVersions("1.2", "1.2.0"))
        assertEquals(1, compareVersions("2.0.0", "1.99.99"))
        assertEquals(1, compareVersions("10.0.0", "9.9.9"))
        assertEquals(-1, compareVersions("1.0.1", "1.0.2"))
        assertEquals(1, compareVersions("99999999999999999999.0.0", "99999999999999999998.9.9"))
        assertNull(compareVersions("v1.0.0", "1.0.0"))
        assertNull(compareVersions("1.2.0-beta", "1.0.0"))
        assertNull(compareVersions(null, "1.0.0"))
    }

    @Test
    fun dateVersions() {
        assertEquals(1, compareVersions("2026.10.19", "2026.9.30"))
        assertEquals(1, compareVersions("2027.1.1", "2026.12.31"))
        assertEquals(0, compareVersions("2026.01.05", "2026.1.5"))
        assertEquals(1, compareVersions("2026.10.21", "1.0.0"))
    }
}

class FormatTest {
    @Test
    fun clocks() {
        assertEquals("00:00", clock(0.0))
        assertEquals("12:03", clock(723.0))
        assertEquals("113:32", clock(113 * 60 + 32.0))
        assertEquals("00:00", clock(Double.NaN))
        assertEquals("00:00", clock(-5.0))
        assertEquals("−38:12", remainingClock(100.0, 2392.0))
        assertEquals("zZ 29:51", sleepLabel(1791.0))
        assertEquals("zZ 本集结束", sleepLabel(null))
    }

    @Test
    fun pill() {
        assertEquals(PillState(PillKind.NEW, "播放"), pillState(null))
        assertEquals(PillState(PillKind.NEW, "62 分钟"), pillState(null, 3710.0))
        assertEquals(PillState(PillKind.HALF, "剩 14:20"), pillState(Prog(100.0, 960.0, false)))
        assertEquals(PillState(PillKind.DONE, "62 分钟"), pillState(Prog(0.0, 3710.0, true)))
        assertEquals(PillState(PillKind.DONE, "已听完"), pillState(Prog(0.0, 0.0, true)))
        assertEquals(0.0, progressRatio(5.0, 0.0), 0.0)
        assertEquals(1.0, progressRatio(50.0, 10.0), 0.0)
    }

    @Test
    fun live() {
        val db = Prog(10.0, 100.0, false)
        assertEquals(Prog(50.0, 100.0, false), liveProgress("a", 50.0, 100.0, true, "a", db))
        assertEquals(db, liveProgress("b", 50.0, 100.0, true, "a", db))
        assertEquals(db, liveProgress("a", 0.0, 0.0, true, "a", db))
        val done = Prog(0.0, 100.0, true)
        assertEquals(done, liveProgress("a", 0.0, 100.0, false, "a", done))
        assertEquals(false, liveProgress("a", 3.0, 100.0, true, "a", done)?.completed)
    }

    @Test
    fun cards() {
        assertEquals(322f, Layout.cardWidths(390f, 844f).first)
        assertEquals(238f, Layout.cardWidths(390f, 844f).second)
        assertEquals(325f, Layout.cardWidths(393f, 852f).first)
        // 平板一屏固定张数：竖屏大 2.2、小 3.5；横屏大 3.2、小 4.5
        assertEquals(442f, Layout.cardWidths(1032f, 1376f).first)
        assertEquals(273f, Layout.cardWidths(1032f, 1376f).second)
        assertEquals(408f, Layout.cardWidths(1376f, 1032f).first)
        assertEquals(286f, Layout.cardWidths(1376f, 1032f).second)
        assertEquals(191f, Layout.cardWidths(744f, 1133f).second)
        assertEquals(4, Layout.tileColumns(700f))
        assertEquals(172f, Layout.seriesRowCoverWidth(390f))
    }
}

class ValidateTest {
    @Test
    fun ids() {
        assertTrue(isValidId("ep_ruzhonglun-37"))
        assertTrue(isValidId("入中论讲解_01"))
        for (bad in listOf(
            "a b",
            "a/b",
            "a.b",
            "《入行论》",
            "😀",
            "",
            "a".repeat(101),
            "é"
        )) assertFalse(bad, isValidId(bad))
        assertFalse(isValidId(5))
    }

    @Test
    fun paths() {
        assertTrue(isValidRelativePath("中观/入中论讲解/第1课.mp3"))
        assertTrue(isValidRelativePath("releases/zhibeifw-1.2.0.apk"))
        for (bad in listOf(
            "/a.mp3",
            "../a",
            "a/../b",
            "https://x/a",
            "javascript:x",
            "//x/a",
            "a\\b",
            "a b",
            "a?x=1",
            "a#b",
            ""
        )) assertFalse(bad, isValidRelativePath(bad))
    }

    @Test
    fun origins() {
        assertTrue(isHttpsOrigin("https://zbfw.org"))
        assertTrue(isHttpsOrigin("https://a.b.c:8443"))
        assertTrue(isHttpsOrigin("https://[2001:db8::1]"))
        for (bad in listOf(
            "http://zbfw.org",
            "https://zbfw.org/",
            "https://zbfw.org/x",
            "https://u:p@zbfw.org",
            "ftp://x"
        )) assertFalse(bad, isHttpsOrigin(bad))
    }

    @Test
    fun domains() {
        assertEquals(
            listOf("https://a.org", "https://c.org"),
            parseDomains("""{"domains":["https://a.org","http://b.org","https://a.org","https://c.org"],"fallbackIps":["https://1.2.3.4"]}""")?.domains
        )
        val many = (0 until 15).joinToString(",") { "\"https://d$it.org\"" }
        assertEquals(10, parseDomains("{\"domains\":[$many]}")?.domains?.size)
        assertNull(parseDomains("""{"domains":[]}"""))
        assertNull(parseDomains("<html>"))
        assertNull(parseDomains("""{"domains":["https://a.org"],"x":"""" + "a".repeat(11000) + "\"}"))
    }

    @Test
    fun index() {
        val text = """
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
        val r = parseIndex(text)!!
        assertEquals(listOf("中观", "初学"), r.categories.map { it.id })
        assertEquals("infinite-outline", r.categories[0].icon)
        assertNull(r.categories[1].icon); assertNull(r.categories[1].color)
        assertEquals(listOf("入中论讲解", "s3"), r.series.map { it.id })
        assertEquals(listOf("入中论讲解_01", "入中论讲解_02"), r.series[0].episodes.map { it.id })
        assertEquals(3660, r.series[0].episodes[0].duration)
        assertNull(r.series[0].episodes[1].duration)
        assertEquals(1792232480L, r.series[0].updatedAt)
        assertNull(r.series[1].updatedAt)
        assertEquals(listOf(FeaturedEntry("新人入门", "入中论讲解")), r.featured)
        assertNull(parseIndex("""{"categories":[]}"""))
        assertNull(parseIndex("""{"categories":[{"id":"a","name":"a","series":[{"id":"bad id"}]}]}"""))
        assertNotNull(parseIndex("""{"categories":[{"id":"a","name":"a","series":[]}]}"""))
        assertNull(parseIndex("not json"))
        assertEquals(emptyList<String>(), r.categoryOrder) // 没写就是空的，分类页跟 categories 一样
    }

    /** 分类页的先后 categoryOrder：只收合规的 ID，去重；不是数组就当没有 */
    @Test
    fun indexCategoryOrder() {
        val base =
            """{"categories":[{"id":"a","name":"a","series":[]},{"id":"b","name":"b","series":[]}],"""
        assertEquals(
            listOf("b", "a", "新分类"),
            parseIndex(base + """"categoryOrder":["b","bad id",3,"a","b","新分类"]}""")?.categoryOrder
        )
        assertEquals(
            emptyList<String>(),
            parseIndex(base + """"categoryOrder":"b"}""")?.categoryOrder
        )
    }

    @Test
    fun upgrade() {
        assertNotNull(parseUpgrade("""{"latestVersion":"1.10.0","minVersion":"1.9.0","apkPath":"releases/a.apk"}"""))
        assertNull(parseUpgrade("""{"latestVersion":"1.0.0","minVersion":"1.1.0","apkPath":"releases/a.apk"}"""))
        assertNull(parseUpgrade("""{"latestVersion":"1.0.0","minVersion":"1.0.0","apkPath":"other/a.apk"}"""))
        assertNull(parseUpgrade("""{"latestVersion":"v1","minVersion":"1.0.0","apkPath":"releases/a.apk"}"""))
    }

    @Test
    fun categoryStyle() {
        assertEquals(Tok.ContentPalette.colors[1], resolveCategoryColor("blue", "x"))
        assertEquals(placeholderColor("中观"), resolveCategoryColor("random", "中观"))
        // 分类方块多出的 10 种：名字和颜色一一对应，18 种互不相同；封面占位色块仍只在前 8 种里取
        assertEquals(Tok.ContentPalette.categoryExtraColors.size, CATEGORY_EXTRA_COLOR_NAMES.size)
        assertEquals(Tok.ContentPalette.categoryExtraColors[0], resolveCategoryColor("red", "x"))
        assertEquals(
            Tok.ContentPalette.categoryExtraColors[9],
            resolveCategoryColor("charcoal", "x")
        )
        assertEquals(
            18,
            (Tok.ContentPalette.colors + Tok.ContentPalette.categoryExtraColors).toSet().size
        )
        assertTrue(isValidColorSetting("wine")); assertFalse(isValidColorSetting("gold"))
        assertEquals(8, Tok.ContentPalette.colors.size)
        assertEquals("infinite-outline", resolveCategoryIcon("infinite-outline", "x"))
        assertEquals(DEFAULT_ICON, resolveCategoryIcon("no-such-icon", "x"))
        assertEquals(DEFAULT_ICON, resolveCategoryIcon(null, "x"))
        for (i in RANDOM_ICONS + DEFAULT_ICON) assertNotNull(i, IconData.get(i))
    }

    @Test
    fun json() {
        assertEquals(
            mapOf("a" to listOf(1.0, "x\n", true, JsonNull)),
            Json.parse("""{"a":[1,"x\n",true,null]}""")
        )
        assertEquals(
            """{"a":[1,"x\n",true,null]}""",
            Json.stringify(mapOf("a" to listOf(1.0, "x\n", true, JsonNull)))
        )
        assertEquals("中A", Json.parse("\"中\\u0041\""))
    }
}

class FileKeyTest {
    /** 对照表由 v1.0 的 TypeScript 算法生成，两端必须逐位一致。 */
    @Test
    fun matchesV1() {
        assertEquals("ep_ruzhonglun_37", fileKey("ep_ruzhonglun_37"))
        assertEquals("h_3edc09c6510d1ce2", fileKey("入中论讲解_01"))
        assertEquals("h_5fa2f0b40e4fddf4", fileKey("入中论讲解"))
        assertEquals("h_69959f4b3b57018d", fileKey("《入行论》"))
        assertEquals("h_249fcb3253cc4f16", fileKey("😀课"))
        assertEquals("h_2dd603ecedce70a5", fileKey("a".repeat(65)))
        assertEquals("h_8ae5568ec9863ea3", fileKey("中观"))
        assertEquals("h_a3082dfe647f2354", fileKey("意识真是从大脑中产生的吗_41"))
    }

    @Test
    fun placeholderMatchesV1() {
        assertEquals(6, placeholderIndex("ep_ruzhonglun_37"))
        assertEquals(4, placeholderIndex("入中论讲解"))
        assertEquals(3, placeholderIndex("《入行论》"))
    }

    @Test
    fun orphans() {
        assertEquals(
            listOf("x"),
            orphanPartKeys(listOf(fileKey("入中论讲解_01"), "x"), listOf("入中论讲解_01"))
        )
        assertEquals(listOf("y"), orphanCoverKeys(listOf(fileKey("中观"), "y"), listOf("中观")))
    }
}

class DownloadFileTest {
    @Test
    fun progressThrottle() {
        val t = com.zhibeifw.app.download.ProgressThrottle()
        assertTrue(t.pass(0, 100, 0))
        assertFalse(t.pass(5, 100, 100))
        assertFalse(t.pass(0, 1000, 1000))
        assertTrue(t.pass(50, 1000, 1000))
    }
}

class InteractionTest {
    @Test
    fun navCollapse() {
        val n = NavCollapse()
        n.feed(5.0); n.feed(8.0); assertFalse(n.collapsed)
        n.feed(30.0); n.feed(50.0); assertFalse(n.collapsed)
        n.feed(90.0); assertTrue(n.collapsed)
        n.feed(40.0); n.feed(20.0); assertTrue(n.collapsed)
        n.feed(8.0); assertFalse(n.collapsed)
        val m = NavCollapse()
        m.reset(100.0); m.feed(110.0); m.feed(105.0); m.feed(115.0); m.feed(110.0); m.feed(120.0)
        assertFalse(m.collapsed)
    }

    @Test
    fun pushGuard() {
        var now = 0L
        val g = PushGuard(700) { now }
        assertTrue(g.allow("a")); assertFalse(g.allow("a")); assertTrue(g.allow("b"))
        now = 800; assertTrue(g.allow("a"))
        g.setShown("p", true); assertFalse(g.allow("p")); g.setShown(
            "p",
            false
        ); assertTrue(g.allow("p"))
    }

    @Test
    fun update() {
        val u = UpgradeFile("1.10.0", "1.2.0", "releases/a.apk")
        assertEquals(
            UpdateDecision.Optional("1.10.0", "releases/a.apk"),
            decideUpdate("1.9.0", u, UpdateChannel.SITE)
        )
        assertEquals(UpdateDecision.None, decideUpdate("1.9.0", u, UpdateChannel.STORE))
        assertEquals(
            UpdateDecision.Outdated("1.10.0", "releases/a.apk"),
            decideUpdate("1.1.0", u, UpdateChannel.STORE)
        )
        assertEquals(UpdateDecision.None, decideUpdate("1.10.0", u, UpdateChannel.SITE))
        assertEquals(UpdateDecision.None, decideUpdate("bad", u, UpdateChannel.SITE))
        assertTrue(shouldAutoCheck(null, 0))
        assertFalse(shouldAutoCheck(0, CHECK_INTERVAL_MS - 1))
        assertTrue(suppressedByRemindLater(RemindLater("1.10.0", 0), "1.10.0", REMIND_LATER_MS - 1))
        assertFalse(suppressedByRemindLater(RemindLater("1.10.0", 0), "1.11.0", 1))
    }

    @Test
    fun syncPolicy() {
        assertTrue(shouldSyncOnForeground(60_000, 0, false))
        assertFalse(shouldSyncOnForeground(59_999, 0, false))
        assertFalse(shouldSyncOnForeground(99_999, 0, true))
        assertEquals(0L, launchFreshWaitMs(false, 10))
        assertEquals(2000L, launchFreshWaitMs(true, 1000))
        assertEquals(0L, launchFreshWaitMs(true, 5000))
    }

    @Test
    fun sleepChoices() {
        assertEquals(
            listOf(
                "单集结束时",
                "1 小时",
                "45 分钟",
                "30 分钟",
                "15 分钟",
                "10 分钟",
                "5 分钟",
                "关闭"
            ), SLEEP_CHOICES.map { it.title })
        assertEquals("m30", SleepSetting.Timer(0, 30).choiceId)
        assertEquals("c", pickNext(listOf("a", "b", "c"), "b"))
        assertNull(pickNext(listOf("a", "b"), "b"))
        assertNull(pickNext(listOf("a"), "x"))
    }

    @Test
    fun downloadMenu() {
        assertEquals(listOf("下载"), downloadMenuItems(null).map { it.title })
        assertEquals(
            listOf("暂停下载", "取消下载"),
            downloadMenuItems(DlStatus.DOWNLOADING).map { it.title })
        assertEquals(
            listOf("继续下载", "取消下载"),
            downloadMenuItems(DlStatus.PAUSED).map { it.title })
        assertEquals(listOf("删除下载"), downloadMenuItems(DlStatus.DONE).map { it.title })
        assertEquals(emptyList<DlMenuItem>(), downloadMenuItems(null, false))
    }

    @Test
    fun normalize() {
        assertEquals("abc 入 行论", normalizeText("  ＡＢＣ​ 入  行论 "))
        assertEquals(listOf("b", "a", "c"), orderOrigins("b", listOf("a", "b"), listOf("c", "a")))
    }
}

class RaceTest {
    @Test
    fun firstFastWins() = runBlocking {
        assertEquals(
            "a",
            pickFirstReachable(listOf("a", "b"), 1500) { if (it == "a") 1 else 2 }?.first
        )
    }

    @Test
    fun staggerThenSecondWins() = runBlocking {
        val t0 = System.currentTimeMillis()
        val r = pickFirstReachable(listOf("slow", "fast"), 100) {
            if (it == "slow") {
                delay(2000); 1
            } else 2
        }
        assertEquals("fast", r?.first)
        assertTrue(System.currentTimeMillis() - t0 < 1000)
    }

    @Test
    fun failureMovesOnImmediately() = runBlocking {
        val t0 = System.currentTimeMillis()
        assertEquals(
            "good",
            pickFirstReachable(listOf("bad", "good"), 5000) { if (it == "bad") null else 1 }?.first
        )
        assertTrue(System.currentTimeMillis() - t0 < 1000)
    }

    @Test
    fun allFail() = runBlocking {
        assertNull(pickFirstReachable<Int>(listOf("a", "b", "c"), 10) { null })
        assertNull(pickFirstReachable(emptyList(), 10) { 1 })
    }

    @Test
    fun coverBucketRoundsUpTo256() {
        assertEquals(256, coverBucket(0))
        assertEquals(256, coverBucket(256))
        assertEquals(512, coverBucket(257))
        val p = "中观/入中论讲解/cover.jpg"
        assertEquals("中观/入中论讲解/cover-640.jpg", coverThumbPath(p, 640))
        assertEquals("中观/入中论讲解/cover-320.jpg", coverSourcePath(p, 108))
        assertEquals("中观/入中论讲解/cover-320.jpg", coverSourcePath(p, 320))
        assertEquals("中观/入中论讲解/cover-640.jpg", coverSourcePath(p, 564))
        assertEquals(p, coverSourcePath(p, 641))
        assertEquals("a.b/cover", coverThumbPath("a.b/cover", 320))
        assertEquals(320, coverRequestPx(108)); assertEquals(
            640,
            coverRequestPx(564)
        ); assertEquals(1280, coverRequestPx(1116))
        assertEquals(1280, coverBucket(1206))
    }

    @Test
    fun libraryCountTextShowsBothWhenNotAllDone() {
        assertEquals("3 节", libraryCountText(3, 3))
        assertEquals("3 节 · 已下载 1 节", libraryCountText(3, 1))
        assertEquals("2 节 · 已下载 0 节", libraryCountText(2, 0))
        assertEquals(listOf("3 节"), libraryCountLines(3, 3))
        assertEquals(listOf("3 节", "已下载 1 节"), libraryCountLines(3, 1))
    }
}
