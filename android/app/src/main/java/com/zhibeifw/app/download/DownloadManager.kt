package com.zhibeifw.app.download

import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.setValue
import com.zhibeifw.app.core.DlStatus
import com.zhibeifw.app.core.fileKey
import com.zhibeifw.app.core.isNoSpaceError
import com.zhibeifw.app.core.orphanAudioNames
import com.zhibeifw.app.core.orphanCoverKeys
import com.zhibeifw.app.data.AppFiles
import com.zhibeifw.app.data.DlItem
import com.zhibeifw.app.data.Store
import com.zhibeifw.app.net.buildUrl
import java.io.File
import kotlin.math.abs
import kotlin.math.min
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// 下载。与 iOS DownloadManager.swift 是同一套做法。
//  真正的下载、排队、同时下几个、断网重试都交给系统（Android 系统 DownloadManager，iOS URLSession 后台会话），
//  这里只做系统不管的事：记下载记录、下完移入资料库、显示进度、失败时整批提示一次、对账。
//  - 有网就下，不分 Wi-Fi 还是流量，不提示；
//  - 暂停：系统没有公开的暂停，从系统里删掉，继续时从头下（iOS 用系统的续传数据）；
//  - 系统报失败：回到“未下载”；整批结束只提示一次；
//  - 存储空间不足：提示一次。

/** 系统交回来的下载事件（在主线程上处理）。 */
sealed class DownloadEvent {
    data class Progress(val id: String, val written: Long, val total: Long) : DownloadEvent()

    /** 下完：系统下好的文件，复制进资料库后交还系统删掉 */
    data class Finished(val id: String, val file: File) : DownloadEvent()
    data class Failed(val id: String, val diskFull: Boolean) : DownloadEvent()
}

/** 系统的下载服务（测试或换实现时可替换）。 */
interface SystemDownloads {
    fun setHandler(h: (DownloadEvent) -> Unit)

    /** 交给系统下载（标题、说明显示在系统通知栏里）。 */
    fun start(id: String, url: String, title: String, description: String)

    /** 停下并从系统里删掉（暂停、取消都用它；系统没有公开的暂停）。 */
    fun stop(id: String)

    /** 下完的文件已复制进资料库：交还系统删掉。 */
    fun release(id: String)

    /** 系统里还在下（含排队、等网络、刚下完待收尾）的集；candidates 是数据库里没下完的集，用来认出系统里的下载。查不了返回 null。 */
    suspend fun activeIds(candidates: Collection<String>): Set<String>?
}

/** 进度节流：变化够 1% 且距上次够 0.25 秒才放行（线程安全，在查询线程上调用）。 */
class ProgressThrottle {
    private var lastRatio = -1.0
    private var lastAt = 0L
    @Synchronized
    fun pass(written: Long, total: Long, now: Long = System.currentTimeMillis()): Boolean {
        val ratio = if (total > 0) written.toDouble() / total else 0.0
        if (lastRatio >= 0 && (abs(ratio - lastRatio) < 0.01 || now - lastAt < 250)) return false
        lastRatio = ratio; lastAt = now
        return true
    }
}

data class DlProgress(
    val status: DlStatus,
    val written: Long,
    val total: Long,
    val seriesId: String
) {
    val ratio get() = if (total > 0) min(1.0, written.toDouble() / total) else 0.0
}

/** 一集的实时进度，每集一个：进度变了只有显示这一集的地方重画，不会让所有读下载状态的页面都重算。 */
class DlLive(written: Long, total: Long) {
    var written by mutableLongStateOf(written)
    var total by mutableLongStateOf(total)
    val ratio get() = if (total > 0) min(1.0, written.toDouble() / total) else 0.0
}

class DownloadManager(
    val system: SystemDownloads,
    val store: Store,
    val files: AppFiles,
) {
    /** 每集的状态（排队、下载中、已暂停、已下载）。只在状态变了时写；进度见 live。 */
    val items = mutableStateMapOf<String, DlProgress>()
    private val live = HashMap<String, DlLive>()

    /** 这一集的下载进度（0～1）。 */
    fun ratio(id: String): Double = live[id]?.ratio ?: items[id]?.ratio ?: 0.0

    /** 整批结束有失败时 +1（界面据此弹一次“部分下载失败，请稍后重试”）。 */
    var failedBatch by mutableIntStateOf(0); private set
    var diskFull by mutableIntStateOf(0); private set

    var origin: suspend () -> String? = { null }
    var onChange: (() -> Unit)? = null

    /** 整批结束有失败：“部分下载失败，请稍后重试”（整批只提示一次）。 */
    var onBatchFailed: (() -> Unit)? = null

    /** 存储空间不足：“手机存储空间不足，下载失败”。 */
    var onDiskFull: (() -> Unit)? = null

    // 后台任务里没接住的错误（比如读库出错）只记日志，不让 App 崩溃
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main +
        CoroutineExceptionHandler { _, e -> Log.w("Download", "后台任务出错", e) })

    /** 正在交给系统（还在等线路）的集：对账时别把它们当成中断 */
    private val starting = HashSet<String>()

    /** 每集的代号：开始、暂停、取消都换一个。等线路回来时代号变了（期间暂停过、又继续了），这一轮就不再交给系统，免得交两次 */
    private val gen = HashMap<String, Int>()
    private fun bump(id: String): Int = ((gen[id] ?: 0) + 1).also { gen[id] = it }
    private var failedInBatch = 0
    private var diskFullShown = false

    init {
        system.setHandler(::handle)
    }

    /** notify：状态变了才通知各页面重新读库；单纯的进度变化不通知（界面直接读 items）。 */
    private fun set(id: String, v: DlProgress?, notify: Boolean = true) {
        if (v == null) {
            items.remove(id); live.remove(id)
        } else {
            items[id] = v
            live.getOrPut(id) { DlLive(v.written, v.total) }.apply { written = v.written; total = v.total }
        }
        if (notify) onChange?.invoke()
    }

    /** 有没有排队或正在下的集 */
    val hasActive get() = items.values.any { it.status == DlStatus.QUEUED || it.status == DlStatus.DOWNLOADING }

    private fun finishBatchIfIdle() {
        if (hasActive) return
        if (failedInBatch > 0) {
            failedInBatch = 0; failedBatch++; onBatchFailed?.invoke()
        }
        diskFullShown = false
    }

    /** 把一批集交给系统下载（已在下或已下载的忽略；已暂停的从头重下）。 */
    fun enqueue(list: List<DlItem>) {
        val seen = HashSet<String>()
        val todo =
            list.filter { seen.add(it.episodeId) && (items[it.episodeId]?.status.let { s -> s == null || s == DlStatus.PAUSED }) }
        if (todo.isEmpty()) return
        val fresh = todo.filter { items[it.episodeId]?.status != DlStatus.PAUSED }
        runCatching { store.startDownloads(fresh, todo.map { it.episodeId }) } // 整批一个事务
        val tokens = HashMap<String, Int>()
        for (it in todo) {
            set(
                it.episodeId,
                DlProgress(DlStatus.DOWNLOADING, 0, items[it.episodeId]?.total ?: 0, it.seriesId),
                notify = false
            )
            starting.add(it.episodeId)
            tokens[it.episodeId] = bump(it.episodeId)
        }
        onChange?.invoke()
        scope.launch {
            val o = origin()
            for (it in todo) {
                // 等线路期间被暂停、取消，或者暂停后又继续了（那一轮自己会交给系统）
                if (gen[it.episodeId] != tokens[it.episodeId]) continue
                starting.remove(it.episodeId)
                // 交给系统是在另一条线程上排队做的：换一个代号，正在查系统表的对账（查表可能早于交出）看到代号变了就不碰这一集
                bump(it.episodeId)
                if (items[it.episodeId]?.status != DlStatus.DOWNLOADING) continue
                if (o == null) {
                    fail(it.episodeId); continue
                }
                runCatching {
                    system.start(
                        it.episodeId,
                        buildUrl(o, it.audioPath),
                        it.episodeTitle,
                        it.seriesTitle
                    )
                }
                    .onFailure { _ -> fail(it.episodeId) }
            }
            finishBatchIfIdle()
        }
    }

    private fun handle(e: DownloadEvent) {
        when (e) {
            is DownloadEvent.Progress -> {
                if (items[e.id]?.status != DlStatus.DOWNLOADING) return
                live[e.id]?.apply { written = e.written; total = e.total }
                return
            }

            is DownloadEvent.Finished -> {
                scope.launch { finish(e.id, e.file); finishBatchIfIdle() }; return
            }

            is DownloadEvent.Failed -> if (e.diskFull) diskFullFail(e.id)
            else if (runCatching { store.getDownload(e.id) }.getOrNull() != null) fail(e.id)
        }
        finishBatchIfIdle()
    }

    private suspend fun finish(id: String, file: File) {
        val r = runCatching { store.getDownload(id) }.getOrNull()
        if (r == null || r.state == DlStatus.DONE) {
            system.release(id); return
        }
        // 用户已经暂停了：下完的文件不要，让系统删掉（多半暂停时已删过；启动对账记为暂停的那种系统里还留着）
        if (r.state == DlStatus.PAUSED || items[id]?.status == DlStatus.PAUSED) {
            system.release(id); return
        }
        val g = gen[id]
        val rel = files.finalRelative(id, r.audioPath)
        val final = files.absolute(rel)
        // 复制成功：true；空间不足：null；其它错误：false
        val ok: Boolean? = withContext(Dispatchers.IO) {
            try {
                file.copyTo(final, overwrite = true)
                final.length() > 0
            } catch (e: Exception) {
                final.delete()
                if (isNoSpaceError(e)) null else false
            }
        }
        // 复制期间被暂停或取消了：复制出来的文件不要，状态保持用户点的那样
        if (gen[id] != g) {
            if (ok == true) withContext(Dispatchers.IO) { final.delete() }
            return
        }
        system.release(id)
        when (ok) {
            null -> diskFullFail(id)
            false -> {
                final.delete(); fail(id)
            }

            true -> {
                runCatching { store.setDlDone(id, rel) }
                set(id, DlProgress(DlStatus.DONE, 1, 1, r.seriesId))
            }
        }
    }

    private fun fail(id: String) {
        bump(id)
        system.stop(id)
        runCatching { store.removeDownload(id) }
        set(id, null)
        failedInBatch++
    }

    private fun diskFullFail(id: String) {
        bump(id)
        system.stop(id)
        runCatching { store.removeDownload(id) }
        set(id, null)
        if (!diskFullShown) {
            diskFullShown = true; diskFull++; onDiskFull?.invoke()
        }
    }

    fun pause(id: String) {
        val cur = items[id] ?: return
        if (cur.status != DlStatus.QUEUED && cur.status != DlStatus.DOWNLOADING) return
        bump(id); starting.remove(id)
        system.stop(id)
        runCatching { store.setDlPaused(id, 0) }
        set(id, cur.copy(status = DlStatus.PAUSED, written = 0))
        finishBatchIfIdle()
    }

    fun pauseAll(seriesId: String? = null) {
        items.filter { (it.value.status == DlStatus.QUEUED || it.value.status == DlStatus.DOWNLOADING) && (seriesId == null || it.value.seriesId == seriesId) }.keys.toList()
            .forEach(::pause)
    }

    fun cancel(id: String) {
        if (cancelOne(id)) cleanupCovers()
    }

    /** 取消一集，不清封面（整门课一起取消时最后清一次）；真取消了返回 true */
    private fun cancelOne(id: String): Boolean {
        val cur = items[id] ?: return false
        if (cur.status == DlStatus.DONE) return false
        bump(id); starting.remove(id)
        system.stop(id)
        runCatching { store.removeDownload(id) }
        set(id, null)
        finishBatchIfIdle()
        return true
    }

    fun cancelSeries(seriesId: String? = null) {
        val ids = items.filter { (seriesId == null || it.value.seriesId == seriesId) && it.value.status != DlStatus.DONE }.keys.toList()
        ids.forEach { cancelOne(it) }
        if (ids.isNotEmpty()) cleanupCovers()
    }

    fun resumePaused(seriesId: String? = null) {
        enqueue(
            runCatching { store.allDownloads() }.getOrDefault(emptyList())
                .filter { it.state == DlStatus.PAUSED && (seriesId == null || it.seriesId == seriesId) }
                .map { it.item })
    }

    /** 删除下载（文件和记录；没下完的先停下）。 */
    fun removeDownload(id: String) {
        removeOne(id)
        cleanupCovers()
    }

    /** 删一集，不清封面（整门课一起删时最后清一次） */
    private fun removeOne(id: String) {
        items[id]?.let {
            if (it.status != DlStatus.DONE) {
                cancelOne(id); return
            }
        }
        runCatching { store.getDownload(id)?.localFile }.getOrNull()?.let { files.absolute(it).delete() }
        runCatching { store.removeDownload(id) }
        set(id, null)
    }

    fun removeSeries(seriesId: String) {
        for (r in runCatching { store.downloadsOfSeries(seriesId) }.getOrDefault(emptyList())) removeOne(r.episodeId)
        cleanupCovers()
    }

    /** 没有任何下载记录的课，本机保存的封面删掉。 */
    fun cleanupCovers() {
        val all = files.coversDir.listFiles().orEmpty()
        val keys = all.map { it.name }.filter { it.endsWith(".jpg") }.map { it.removeSuffix(".jpg") }
        val keep = runCatching { store.seriesIdsWithDownloads() }.getOrElse { return }
        // 另存封面时中途被关掉留下的临时文件：封面已经在了、或这门课已经没有下载的才删（这两种情况都不会正在另存）
        val keepKeys = keep.map(::fileKey).toSet()
        for (f in all) if (f.name.endsWith(".jpg.tmp")) {
            val k = f.name.removeSuffix(".jpg.tmp")
            if (k in keys || k !in keepKeys) f.delete()
        }
        for (k in orphanCoverKeys(keys, keep)) File(
            files.coversDir,
            "$k.jpg"
        ).delete()
    }

    /** 对账（启动、回到前台）：系统里还在下的保持“下载中”；没下完、系统里也没有的记为已暂停（继续时从头下）。 */
    suspend fun reconcile() {
        for (r in runCatching { store.doneDownloads() }.getOrDefault(emptyList())) {
            val lf = r.localFile
            if (lf != null && files.absolute(lf).exists()) {
                if (items[r.episodeId]?.status != DlStatus.DONE)
                    set(r.episodeId, DlProgress(DlStatus.DONE, 1, 1, r.seriesId), notify = false)
            } else {
                runCatching { store.removeDownload(r.episodeId) }
                items.remove(r.episodeId); live.remove(r.episodeId)
            }
        }
        val all = runCatching { store.allDownloads() }.getOrElse { return }
        val pending = all.filter { it.state != DlStatus.DONE }
        val gens = pending.associate { it.episodeId to gen[it.episodeId] }
        // 查不了系统表：这次不对账，免得把在下的都记成暂停
        val active = system.activeIds(pending.map { it.episodeId }) ?: return
        for (r0 in pending) {
            val id = r0.episodeId
            // 等系统表期间用户暂停、取消、继续过，或者已经下完：以现在的为准
            if (gen[id] != gens[id]) continue
            val r = runCatching { store.getDownload(id) }.getOrNull() ?: continue
            if (r.state == DlStatus.DONE) continue
            if (id in active || id in starting) {
                if (items[id] == null) set(id, DlProgress(DlStatus.DOWNLOADING, 0, r.total, r.seriesId), notify = false)
                continue
            }
            if (r.state != DlStatus.PAUSED || r.bytes != 0L) runCatching {
                store.setDlPaused(
                    id,
                    0
                )
            }
            set(id, DlProgress(DlStatus.PAUSED, 0, r.total, r.seriesId), notify = false)
        }
        // 旧版本自己下载时留下的半截文件；资料库里没有下载记录对应的音频（复制到一半被关掉等）
        val keepAudio = all.map { it.localFile ?: files.finalRelative(it.episodeId, it.audioPath) }
            .map { it.substringAfterLast('/') }
        withContext(Dispatchers.IO) {
            files.partDir.listFiles()?.forEach { it.delete() }
            val onDisk = files.audioDir.listFiles()?.filter { it.isFile }?.map { it.name } ?: emptyList()
            for (n in orphanAudioNames(onDisk, keepAudio)) File(files.audioDir, n).delete()
        }
        cleanupCovers()
        finishBatchIfIdle()
        onChange?.invoke()
    }
}
