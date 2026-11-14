package com.zhibeifw.app

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.zhibeifw.app.core.DlStatus
import com.zhibeifw.app.data.AppFiles
import com.zhibeifw.app.data.Db
import com.zhibeifw.app.data.DlItem
import com.zhibeifw.app.data.Migrator
import com.zhibeifw.app.data.Store
import com.zhibeifw.app.download.DownloadEvent
import com.zhibeifw.app.download.DownloadManager
import com.zhibeifw.app.download.SystemDownloads
import java.io.File
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import com.zhibeifw.app.core.fileKey
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

// 下载管理器自己做的部分（记录、收尾、暂停与继续），系统下载服务换成假的，测试里直接替系统发事件。
@RunWith(AndroidJUnit4::class)
class DownloadManagerDeviceTest {
    private class FakeSystem : SystemDownloads {
        var onEvent: ((DownloadEvent) -> Unit)? = null
        val started = ArrayList<String>()
        val stopped = ArrayList<String>()
        val released = ArrayList<Pair<String, Long>>()
        val generations = mutableMapOf<String, Int>()
        override fun setHandler(h: (DownloadEvent) -> Unit) {
            onEvent = h
        }

        override fun start(id: String, generation: Int, url: String, title: String, description: String) {
            started += id
            generations[id] = generation
        }

        override fun stop(id: String) {
            stopped += id
        }

        override fun release(id: String, taskId: Long) {
            released += id to taskId
        }
        /** 系统表里在下的；null＝查不了 */
        var active: Set<String>? = emptySet()
        /** 设了就让查表等到放行 */
        var gate: CompletableDeferred<Unit>? = null
        override suspend fun activeIds(candidates: Collection<String>): Set<String>? {
            gate?.await()
            return active
        }
    }

    private lateinit var dir: File
    private lateinit var db: Db
    private lateinit var store: Store
    private lateinit var files: AppFiles
    private lateinit var sys: FakeSystem
    private lateinit var dm: DownloadManager
    private var batchFailed = 0
    private var diskFull = 0

    @Before
    fun setUp() = onMain {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        dir = File(ctx.cacheDir, "dm-test-${System.nanoTime()}").apply { mkdirs() }
        files = AppFiles(File(dir, "files"), File(dir, "cache")).apply { prepare() }
        db = Db.open(File(dir, "t.db").path)
        Migrator.migrate(db)
        store = Store(db)
        sys = FakeSystem()
        dm = DownloadManager(sys, store, files)
        dm.origin = { "https://example.invalid" }
        dm.onBatchFailed = { batchFailed++ }
        dm.onDiskFull = { diskFull++ }
    }

    @After
    fun tearDown() {
        db.db.close(); dir.deleteRecursively()
    }

    private fun onMain(block: suspend () -> Unit) = runBlocking(Dispatchers.Main) { block() }
    private fun item(id: String) = DlItem(id, "s", "S", id, 0, "c/s/$id.mp3")
    private suspend fun settle() = repeat(20) { delay(10) }

    @Test
    fun finishedMovesIntoLibrary() = onMain {
        dm.enqueue(listOf(item("a"))); settle()
        assertEquals(listOf("a"), sys.started)
        sys.onEvent!!(DownloadEvent.Progress("a", sys.generations["a"], 500, 1000))
        assertEquals(0.5, dm.ratio("a"), 0.0)
        val src = File(dir, "a.part").apply { writeBytes(ByteArray(1000)) }
        sys.onEvent!!(DownloadEvent.Finished("a", sys.generations["a"], 101, src)); settle()
        assertEquals(DlStatus.DONE, dm.items["a"]?.status)
        assertTrue(files.absolute(store.getDownload("a")!!.localFile!!).length() == 1000L)
    }

    @Test
    fun lateEventsAfterRestartingEpisodeDoNotAffectNewTask() = onMain {
        dm.enqueue(listOf(item("a"))); settle()
        val oldGeneration = sys.generations.getValue("a")
        dm.cancel("a")
        dm.enqueue(listOf(item("a"))); settle()
        val newGeneration = sys.generations.getValue("a")
        val old = File(dir, "old.part").apply { writeText("old") }
        val fresh = File(dir, "new.part").apply { writeText("new") }

        sys.onEvent!!(DownloadEvent.Failed("a", oldGeneration, false))
        sys.onEvent!!(DownloadEvent.Finished("a", oldGeneration, 101, old))
        assertEquals(DlStatus.DOWNLOADING, store.getDownload("a")?.state)
        assertEquals(listOf("a"), sys.stopped)
        assertEquals(listOf("a" to 101L), sys.released)

        sys.onEvent!!(DownloadEvent.Finished("a", newGeneration, 102, fresh)); settle()
        val row = requireNotNull(store.getDownload("a"))
        assertEquals(DlStatus.DONE, row.state)
        assertEquals("new", files.absolute(requireNotNull(row.localFile)).readText())
        assertEquals(listOf("a" to 101L, "a" to 102L), sys.released)
    }

    /** 整门课取消：只撤没下完的，下完的和封面留着；整门课删除：音频、记录、封面都清掉 */
    @Test
    fun seriesCancelThenRemove() = onMain {
        dm.enqueue(listOf(item("a"), item("b"), item("c"))); settle()
        val src = File(dir, "a.part").apply { writeBytes(ByteArray(1000)) }
        sys.onEvent!!(DownloadEvent.Finished("a", sys.generations["a"], 101, src)); settle()
        val cover = File(files.coversDir, fileKey("s") + ".jpg").apply { parentFile?.mkdirs(); writeBytes(ByteArray(10)) }
        val audio = files.absolute(store.getDownload("a")!!.localFile!!)
        dm.cancelSeries("s")
        assertEquals(setOf("b", "c"), sys.stopped.toSet())
        assertEquals(DlStatus.DONE, dm.items["a"]?.status)
        assertNull(dm.items["b"]); assertNull(store.getDownload("c"))
        assertTrue(cover.exists())
        dm.removeSeries("s")
        assertNull(dm.items["a"]); assertNull(store.getDownload("a"))
        assertFalse(audio.exists())
        assertFalse(cover.exists())
    }

    /** 继续时线路都连不上：已暂停的退回暂停（记录还在），新加的回到未下载，整批提示一次 */
    @Test
    fun resumeWithoutRouteStaysPaused() = onMain {
        dm.enqueue(listOf(item("a"))); settle()
        dm.pause("a")
        dm.origin = { null }
        sys.started.clear()
        dm.enqueue(listOf(item("a"), item("b"))); settle()
        assertEquals(DlStatus.PAUSED, dm.items["a"]?.status)
        assertEquals(DlStatus.PAUSED, store.getDownload("a")?.state)
        assertNull(dm.items["b"]); assertNull(store.getDownload("b"))
        assertTrue(sys.started.isEmpty())
        assertEquals(1, batchFailed)
    }

    /** 等线路期间暂停又继续：只交给系统一次 */
    @Test
    fun pauseResumeWhileWaitingForRouteStartsOnce() = onMain {
        val gate = CompletableDeferred<String?>()
        dm.origin = { gate.await() }
        dm.enqueue(listOf(item("a")))
        dm.pause("a")
        dm.enqueue(listOf(item("a")))
        gate.complete("https://example.invalid"); settle()
        assertEquals(listOf("a"), sys.started)
        assertEquals(DlStatus.DOWNLOADING, dm.items["a"]?.status)
    }

    /** 移入资料库失败但不是空间不足：按普通失败，不提示“存储空间不足” */
    @Test
    fun copyFailureIsNotDiskFull() = onMain {
        dm.enqueue(listOf(item("a"))); settle()
        sys.onEvent!!(DownloadEvent.Finished("a", sys.generations["a"], 101, File(dir, "missing.part"))); settle()
        assertNull(dm.items["a"])
        assertEquals(0, diskFull)
        assertEquals(1, batchFailed)
    }

    /** 收尾前已经暂停：不要下完的文件（让系统删掉），保持暂停，不误报存储空间不足 */
    @Test
    fun pausedBeforeFinishKeepsPaused() = onMain {
        dm.enqueue(listOf(item("a"))); settle()
        dm.pause("a")
        val src = File(dir, "a.part").apply { writeBytes(ByteArray(1000)) }
        sys.onEvent!!(DownloadEvent.Finished("a", sys.generations["a"], 101, src)); settle()
        assertEquals(DlStatus.PAUSED, dm.items["a"]?.status)
        assertEquals(0, diskFull)
        assertFalse(files.absolute(files.finalRelative("a", "c/s/a.mp3")).exists())
        assertEquals(listOf("a" to 101L), sys.released)
    }

    /** 对账查系统表在前、刚好在这期间把一集交给系统：对账不把它记成暂停 */
    @Test
    fun reconcileIgnoresStartDuringQuery() = onMain {
        val route = CompletableDeferred<String?>()
        dm.origin = { route.await() }
        dm.enqueue(listOf(item("a"))); settle()
        val gate = CompletableDeferred<Unit>()
        sys.gate = gate; sys.active = emptySet()
        val job = CoroutineScope(Dispatchers.Main).launch { dm.reconcile() }
        settle()
        route.complete("https://example.invalid"); settle()
        assertEquals(listOf("a"), sys.started)
        gate.complete(Unit); job.join()
        assertEquals(DlStatus.DOWNLOADING, dm.items["a"]?.status)
        assertEquals(DlStatus.DOWNLOADING, store.getDownload("a")?.state)
    }

    /** 查不了系统表：这次不对账，在下的不会被记成暂停 */
    @Test
    fun reconcileSkipsWhenTableUnreadable() = onMain {
        dm.enqueue(listOf(item("a"))); settle()
        sys.active = null
        dm.reconcile()
        assertEquals(DlStatus.DOWNLOADING, dm.items["a"]?.status)
        assertEquals(DlStatus.DOWNLOADING, store.getDownload("a")?.state)
    }

    /** 查系统表期间用户取消了：对账以用户的为准，不把它加回来 */
    @Test
    fun reconcileRespectsCancelDuringQuery() = onMain {
        dm.enqueue(listOf(item("a"))); settle()
        val gate = CompletableDeferred<Unit>()
        sys.gate = gate; sys.active = setOf("a")
        val job = CoroutineScope(Dispatchers.Main).launch { dm.reconcile() }
        settle()
        dm.cancel("a")
        gate.complete(Unit); job.join()
        assertNull(dm.items["a"]); assertNull(store.getDownload("a"))
    }

    /** 对账清掉资料库里没有下载记录对应的音频 */
    @Test
    fun reconcileRemovesOrphanAudio() = onMain {
        store.queuedMany(listOf(item("a")))
        store.setDlDone("a", "audio/a.mp3")
        files.absolute("audio/a.mp3").writeBytes(ByteArray(10))
        files.absolute("audio/x.mp3").writeBytes(ByteArray(10))
        dm.reconcile()
        assertTrue(files.absolute("audio/a.mp3").exists())
        assertFalse(files.absolute("audio/x.mp3").exists())
    }
}
