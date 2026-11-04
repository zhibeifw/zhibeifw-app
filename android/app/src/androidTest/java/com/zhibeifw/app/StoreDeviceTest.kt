package com.zhibeifw.app

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.zhibeifw.app.core.Prog
import com.zhibeifw.app.data.Db
import com.zhibeifw.app.data.Migrator
import com.zhibeifw.app.data.Store
import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

// 用户表写入在设备自带的 SQLite 上跑（UPSERT 要 SQLite 3.24，最低支持的 Android 10 自带 3.22，不能用）。
// 规则与 iOS StoreTests 的用户表部分相同。
@RunWith(AndroidJUnit4::class)
class StoreDeviceTest {
    private lateinit var dir: File
    private lateinit var db: Db
    private lateinit var store: Store

    @Before
    fun setUp() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        dir = File(ctx.cacheDir, "store-test-${System.nanoTime()}").apply { mkdirs() }
        db = Db.open(File(dir, "t.db").path)
        Migrator.migrate(db)
        store = Store(db)
        Log.i("StoreDeviceTest", "SQLite ${db.first("SELECT sqlite_version() AS v")?.str("v")}")
    }

    @After
    fun tearDown() {
        db.db.close()
        dir.deleteRecursively()
    }

    @Test
    fun recentRules() {
        store.recordPlayback("课A_1", "课A", 10.0, 600.0, at = 1)
        store.recordPlayback("课A_2", "课A", 10.0, 600.0, at = 2)
        assertEquals(listOf("课A_2", "课A_1"), store.loadRecent().map { it.episodeId })
        // 再存一次是更新同一行：位置跟着变
        store.recordPlayback("课A_1", "课A", 42.0, 600.0, at = 3)
        assertEquals(Prog(42.0, 600.0, false), store.loadProgress("课A_1"))
        // 距结尾 30 秒内算听完、位置归零
        assertTrue(store.recordPlayback("课A_1", "课A", 580.0, 600.0, at = 4))
        assertEquals(Prog(0.0, 600.0, true), store.loadProgress("课A_1"))
        // 标记不更新最后播放时间、不改变去留
        store.markCompleted("课A_2", "课A", true)
        assertEquals(listOf("课A_1", "课A_2"), store.loadRecent().map { it.episodeId })
        assertEquals(true, store.loadProgress("课A_2")?.completed)
        store.markCompleted("课A_2", "课A", false)
        assertEquals(false, store.loadProgress("课A_2")?.completed)
        // 此前没有记录就标记：新建一行但不出现在最近
        store.markCompleted("x", "y", true)
        assertEquals(true, store.loadProgress("x")?.completed)
        assertFalse(store.loadRecent().any { it.episodeId == "x" })
        // 删除记录只是隐藏；再播放才回来，并清除已听完
        store.hideFromRecent("课A_1")
        assertEquals(listOf("课A_2"), store.loadRecent().map { it.episodeId })
        store.recordPlayback("课A_1", "课A", 5.0, 600.0, at = 9)
        assertEquals("课A_1", store.loadRecent().first().episodeId)
        assertEquals(false, store.loadProgress("课A_1")?.completed)
        // 时长为 0 时不覆盖已知时长
        store.recordPlayback("课A_1", "课A", 6.0, 0.0, at = 10)
        assertEquals(600.0, store.loadProgress("课A_1")?.duration)
        store.clearRecent()
        assertTrue(store.loadRecent().isEmpty())
    }

    @Test
    fun goneEpisodesKeepTitles() {
        store.recordPlayback("e9", "s9", 5.0, 60.0, "旧课", "第9课", "c.jpg")
        val r = store.loadRecent().first()
        assertTrue(r.gone); assertEquals("旧课", r.seriesTitle); assertEquals("第9课", r.epTitle); assertNull(r.audioPath)
        // 空标题保存不会冲掉已有的
        store.recordPlayback("e9", "s9", 6.0, 60.0)
        assertEquals("旧课", store.loadRecent().first().seriesTitle)
        store.markCompleted("e9", "s9", true)
        assertEquals("第9课", store.loadRecent().first().epTitle)
    }

    @Test
    fun favorites() {
        store.addFavorite("a", "A", at = 1)
        store.addFavorite("b", "B", at = 2)
        assertEquals(listOf("b", "a"), store.loadFavorites().map { it.id })
        assertTrue(store.isFavorite("a"))
        store.addFavorite("a", at = 9) // 已收藏时再收藏不改时间，空标题不覆盖
        assertEquals(listOf("b", "a"), store.loadFavorites().map { it.id })
        assertEquals("A", store.loadFavorites().last().title)
        store.addFavorite("a", "A2", "a.jpg", at = 9) // 有新标题就更新
        assertEquals("A2", store.loadFavorites().last().title)
        store.removeFavorite("a"); store.addFavorite("a", at = 10)
        assertEquals(listOf("a", "b"), store.loadFavorites().map { it.id })
        assertFalse(store.isFavorite("z"))
    }

    @Test
    fun backupCopiesUserTables() {
        store.recordPlayback("课A_1", "课A", 10.0, 600.0, at = 1)
        store.recordPlayback("课A_2", "课A", 20.0, 600.0, at = 2)
        store.addFavorite("课A", at = 3)
        val bak = File(dir, "bak.db")
        Migrator.backupUserTables(db, bak)
        val b = Db.open(bak.path)
        try {
            assertEquals(2L, b.first("SELECT COUNT(*) AS n FROM user_progress")?.values?.get("n"))
            assertEquals(20.0, b.first("SELECT position FROM user_progress WHERE episode_id = '课A_2'")?.values?.get("position"))
            assertEquals(1L, b.first("SELECT COUNT(*) AS n FROM user_favorite")?.values?.get("n"))
            // 空表也建出来
            assertEquals(0L, b.first("SELECT COUNT(*) AS n FROM user_download")?.values?.get("n"))
        } finally {
            b.db.close()
        }
    }
}
