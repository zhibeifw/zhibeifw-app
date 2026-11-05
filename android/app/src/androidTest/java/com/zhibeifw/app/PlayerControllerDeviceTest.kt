package com.zhibeifw.app

import android.os.SystemClock
import androidx.media3.exoplayer.ExoPlayer
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.zhibeifw.app.core.CategoryEntry
import com.zhibeifw.app.core.EpisodeEntry
import com.zhibeifw.app.core.IndexFile
import com.zhibeifw.app.core.PlayContext
import com.zhibeifw.app.core.SeriesEntry
import com.zhibeifw.app.core.SleepSetting
import com.zhibeifw.app.data.AppFiles
import com.zhibeifw.app.data.Db
import com.zhibeifw.app.data.DlItem
import com.zhibeifw.app.data.Migrator
import com.zhibeifw.app.data.Store
import com.zhibeifw.app.net.Network
import com.zhibeifw.app.player.PlayerController
import com.zhibeifw.app.player.PlayerError
import com.zhibeifw.app.player.SEEK_BACK_SECONDS
import com.zhibeifw.app.player.SEEK_FORWARD_SECONDS
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

// 播放控制器，规则与 iOS PlayerControllerTests 相同。用真的 ExoPlayer 放测试里现生成的几秒静音 WAV（已下载的集走本地文件），
// 只把“取线路”“问文件在不在”“卡住多久算失败”换成测试里给的，不连网络。每个测试用自己的播放器，结束时释放。
@RunWith(AndroidJUnit4::class)
class PlayerControllerDeviceTest {
    private val ctx = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var dir: File
    private lateinit var db: Db
    private lateinit var store: Store
    private lateinit var files: AppFiles
    private val players = ArrayList<ExoPlayer>()
    private val damaged = ArrayList<String>()

    @Before
    fun setUp() = onMain {
        dir = File(ctx.cacheDir, "pc-test-${System.nanoTime()}").apply { mkdirs() }
        files = AppFiles(File(dir, "files"), File(dir, "cache")).apply { prepare() }
        db = Db.open(File(dir, "t.db").path)
        Migrator.migrate(db)
        store = Store(db)
        store.replaceIndex(
            IndexFile(
                listOf(CategoryEntry("分类", "分类", null, null)),
                listOf(
                    SeriesEntry(
                        "课", "课", "分类", "", "ongoing", null,
                        (1..3).map { EpisodeEntry("课_$it", "第${it}课", "分类/课/$it.wav", null) }, null
                    )
                ),
                emptyList()
            )
        )
    }

    @After
    fun tearDown() = onMain {
        players.forEach { it.release() }
        db.db.close(); dir.deleteRecursively()
    }

    private fun onMain(block: suspend () -> Unit) = runBlocking(Dispatchers.Main) { block() }

    private fun make(
        routes: suspend () -> String? = { null },
        headStatus: suspend (String) -> Int? = { null },
        stallLimitMs: Long = 30_000,
        probeAfterMs: Long = 5_000
    ): PlayerController {
        val ep = ExoPlayer.Builder(ctx).build().also { players.add(it) }
        return PlayerController(ctx, store, files, Network(ctx), ep, routes, headStatus, stallLimitMs, probeAfterMs).apply {
            onDamaged = { damaged.add(it) }
        }
    }

    /** 几秒静音的 WAV（8 kHz、单声道、16 位） */
    private fun wav(seconds: Double): ByteArray {
        val rate = 8000
        val bytes = (rate * seconds).toInt() * 2
        val o = ByteArrayOutputStream()
        fun u32(v: Int) = o.write(byteArrayOf(v.toByte(), (v shr 8).toByte(), (v shr 16).toByte(), (v shr 24).toByte()))
        fun u16(v: Int) = o.write(byteArrayOf(v.toByte(), (v shr 8).toByte()))
        o.write("RIFF".toByteArray()); u32(36 + bytes); o.write("WAVEfmt ".toByteArray())
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        o.write("data".toByteArray()); u32(bytes)
        o.write(ByteArray(bytes))
        return o.toByteArray()
    }

    /** 把这一集登记成“已下载”，本地文件是 data（null：记录在、文件不在） */
    private fun download(n: Int, data: ByteArray?) {
        val id = "课_$n"
        store.startDownloads(listOf(DlItem(id, "课", "课", "第${n}课", n, "分类/课/$n.wav")), listOf(id))
        val rel = files.finalRelative(id, "分类/课/$n.wav")
        if (data != null) files.absolute(rel).apply { parentFile?.mkdirs() }.writeBytes(data)
        store.setDlDone(id, rel)
    }

    private suspend fun until(what: String, timeoutMs: Long = 5_000, cond: () -> Boolean) {
        val end = SystemClock.elapsedRealtime() + timeoutMs
        while (!cond() && SystemClock.elapsedRealtime() < end) delay(50)
        assertTrue("等不到：$what", cond())
    }

    private fun record(id: String, pos: Double, dur: Double) {
        store.recordPlayback(id, "课", pos, dur, "课", id, "")
    }

    // ---------- 开始播放、续播 ----------

    @Test
    fun resumesFromSavedPositionAndEntersRecent() = onMain {
        download(1, wav(8.0))
        record("课_1", 3.0, 8.0); store.hideFromRecent("课_1")
        val p = make()
        assertTrue(p.start("课_1", PlayContext.Series("课")))
        assertTrue("点了马上显示暂停图标", p.looksPlaying)
        until("在出声") { p.isPlaying }
        assertTrue(p.player.currentPosition >= 2900)
        assertFalse(p.streaming)
        assertEquals("一播放即进最近", "课_1", store.loadRecent().first().episodeId)
        p.pause()
    }

    @Test
    fun completedEpisodeStartsFromBeginning() = onMain {
        download(1, wav(8.0))
        record("课_1", 8.0, 8.0)
        assertEquals(true, store.loadProgress("课_1")?.completed)
        val p = make()
        p.start("课_1", PlayContext.Series("课"))
        until("在出声") { p.isPlaying }
        assertTrue(p.player.currentPosition < 1500)
        p.pause()
    }

    @Test
    fun pauseSavesPositionAndResumeContinues() = onMain {
        download(1, wav(8.0))
        val p = make()
        p.start("课_1", PlayContext.Series("课"))
        until("播过 1 秒") { p.player.currentPosition >= 1000 }
        p.pause()
        until("停下") { !p.looksPlaying }
        val saved = store.loadProgress("课_1")!!.position
        assertEquals(p.player.currentPosition / 1000.0, saved, 0.6)
        p.toggle()
        until("接着出声") { p.isPlaying }
        assertTrue("继续不是从头重新加载", p.player.currentPosition / 1000.0 >= saved - 0.5)
        p.pause()
    }

    // ---------- 播完以后 ----------

    @Test
    fun seriesPlaysNextAfterFinish() = onMain {
        download(1, wav(1.5)); download(2, wav(8.0))
        val p = make()
        p.start("课_1", PlayContext.Series("课"))
        until("接到第 2 集并出声", 8_000) { p.current?.episodeId == "课_2" && p.isPlaying }
        assertEquals("播完算听完", true, store.loadProgress("课_1")?.completed)
        p.pause()
    }

    @Test
    fun libraryOnlyPlaysDownloadedNext() = onMain {
        download(1, wav(1.5)); download(3, wav(8.0))
        val p = make()
        p.start("课_1", PlayContext.Library("课"))
        until("跳过没下载的第 2 集", 8_000) { p.current?.episodeId == "课_3" && p.isPlaying }
        p.pause()
    }

    @Test
    fun singleStopsAtEnd() = onMain {
        download(1, wav(1.5)); download(2, wav(8.0))
        val p = make()
        p.start("课_1", PlayContext.Single)
        until("开始出声") { p.isPlaying }
        until("播完停住", 6_000) { !p.looksPlaying }
        delay(500)
        assertEquals("课_1", p.current?.episodeId)
        assertEquals(true, store.loadProgress("课_1")?.completed)
    }

    @Test
    fun sleepAtEndBeatsNext() = onMain {
        download(1, wav(1.5)); download(2, wav(8.0))
        val p = make()
        p.changeSleep(SleepSetting.End)
        p.start("课_1", PlayContext.Series("课"))
        until("开始出声") { p.isPlaying }
        until("播完停住", 6_000) { !p.looksPlaying }
        assertEquals("不接下一集", "课_1", p.current?.episodeId)
        assertEquals(SleepSetting.Off, p.sleep)
    }

    @Test
    fun sleepTimerPausesAndTurnsOff() = onMain {
        download(1, wav(10.0))
        val p = make()
        p.start("课_1", PlayContext.Series("课"))
        until("开始出声") { p.isPlaying }
        p.changeSleep(SleepSetting.Timer(SystemClock.elapsedRealtime() + 1_500, 1))
        assertEquals("m1", p.sleep.choiceId)
        until("到点暂停") { !p.looksPlaying }
        assertEquals(SleepSetting.Off, p.sleep)
        assertNull(p.sleepLeft)
        assertNotNull("到点暂停也存进度", store.loadProgress("课_1"))
    }

    // ---------- 本地文件出问题 ----------

    @Test
    fun missingDownloadedFileIsDamaged() = onMain {
        download(1, null)
        val p = make()
        p.start("课_1", PlayContext.Series("课"))
        assertEquals(PlayerError.DAMAGED, p.error)
        assertEquals(listOf("课_1"), damaged)
        assertFalse(p.looksPlaying)
    }

    @Test
    fun corruptDownloadedFileIsDamaged() = onMain {
        download(1, "not audio".toByteArray())
        val p = make()
        p.start("课_1", PlayContext.Series("课"))
        until("报已损坏") { p.error == PlayerError.DAMAGED }
        assertEquals(listOf("课_1"), damaged)
        assertFalse(p.looksPlaying)
    }

    // ---------- 在线播放 ----------

    @Test
    fun noRouteCannotPlayAndStaysOutOfRecent() = onMain {
        record("课_1", 3.0, 8.0); store.hideFromRecent("课_1")
        val p = make(routes = { null })
        p.start("课_1", PlayContext.Series("课"))
        assertTrue("拿地址期间先显示暂停图标", p.looksPlaying)
        until("提示无法播放") { p.error == PlayerError.CANNOT_PLAY }
        assertFalse(p.looksPlaying)
        assertEquals("原来的进度不被清零", 3.0, store.loadProgress("课_1")!!.position, 0.0)
        assertTrue("失败的那一集不进最近", store.loadRecent().isEmpty())
    }

    @Test
    fun stallFailsAndGoneFileReportedEarly() = onMain {
        // 连不上的地址：一直缓冲。先问到 404 → 提前报“已下架”
        val p = make(routes = { "https://10.255.255.1" }, headStatus = { 404 }, stallLimitMs = 20_000, probeAfterMs = 300)
        p.start("课_1", PlayContext.Series("课"))
        until("报已下架") { p.error != null }
        assertEquals(PlayerError.GONE, p.error)
        until("停下") { !p.looksPlaying }
        // 文件还在（问到 200）：不提前报，等满卡住的时限报“网络异常”
        val q = make(routes = { "https://10.255.255.1" }, headStatus = { 200 }, stallLimitMs = 1_500, probeAfterMs = 300)
        q.start("课_2", PlayContext.Series("课"))
        until("卡住超时") { q.error != null }
        assertEquals(PlayerError.CANNOT_PLAY, q.error)
        until("停下") { !q.looksPlaying }
    }

    // ---------- 加载期间的操作 ----------

    @Test
    fun pauseWhileLoadingStaysSilentAndKeepsProgress() = onMain {
        download(1, wav(8.0))
        record("课_1", 3.0, 8.0)
        val p = make()
        p.start("课_1", PlayContext.Series("课"))
        p.pause()
        delay(1_200)
        assertFalse(p.isPlaying)
        assertFalse(p.looksPlaying)
        assertEquals(3.0, store.loadProgress("课_1")!!.position, 0.0)
    }

    @Test
    fun switchingWhileLoadingKeepsPreviousProgress() = onMain {
        download(1, wav(8.0)); download(2, wav(8.0))
        record("课_1", 3.0, 8.0)
        val p = make()
        p.start("课_1", PlayContext.Series("课"))
        p.start("课_2", PlayContext.Series("课"))
        until("第 2 集出声") { p.isPlaying }
        assertEquals("课_2", p.current?.episodeId)
        assertEquals(3.0, store.loadProgress("课_1")!!.position, 0.0)
        p.pause()
    }

    // ---------- 标为已听完、删除下载 ----------

    @Test
    fun markCompletedStopsAndIsNotOverwritten() = onMain {
        download(1, wav(8.0))
        val p = make()
        p.start("课_1", PlayContext.Series("课"))
        until("播过 1 秒") { p.player.currentPosition >= 1000 }
        store.markCompleted("课_1", "课", true)
        assertTrue(p.stopAsCompleted("课_1"))
        assertEquals(0.0, p.position, 0.0)
        p.pause(); p.saveNow()
        delay(800)
        assertEquals("旧进度不把已听完盖回去", true, store.loadProgress("课_1")?.completed)
        p.toggle()
        until("重新加载出声") { p.isPlaying }
        assertTrue("从头开始", p.player.currentPosition < 1500)
        p.pause()
    }

    @Test
    fun stopIfCurrentClears() = onMain {
        download(1, wav(8.0))
        val p = make()
        p.start("课_1", PlayContext.Series("课"))
        p.stopIfCurrent("课_1")
        delay(1_000)
        assertNull(p.current)
        assertFalse("加载结果作废，不出声", p.isPlaying)
        // 正在出声时删掉：按钮不再显示成在播
        p.start("课_1", PlayContext.Series("课"))
        until("在出声") { p.isPlaying }
        p.stopIfCurrent("课_1")
        delay(500)
        assertNull(p.current)
        assertFalse(p.looksPlaying)
    }

    // ---------- 跳转、倍速 ----------

    @Test
    fun seekStaysInBounds() = onMain {
        download(1, wav(8.0))
        val p = make()
        p.start("课_1", PlayContext.Series("课"))
        until("知道总时长") { p.duration > 7 }
        p.seekBy(-SEEK_BACK_SECONDS)
        assertEquals(0.0, p.position, 0.0)
        p.seekBy(SEEK_FORWARD_SECONDS)
        assertEquals(p.duration, p.position, 0.01)
        p.pause()
    }

    @Test
    fun rateCarriesOverToNextEpisode() = onMain {
        download(1, wav(8.0)); download(2, wav(8.0))
        val p = make()
        p.start("课_1", PlayContext.Series("课"))
        until("出声") { p.isPlaying }
        p.changeRate(1.5)
        until("播放器按 1.5 倍播") { p.player.playbackParameters.speed == 1.5f }
        p.start("课_2", PlayContext.Series("课"))
        until("第 2 集按 1.5 倍播") { p.current?.episodeId == "课_2" && p.isPlaying && p.player.playbackParameters.speed == 1.5f }
        p.pause()
    }
}
