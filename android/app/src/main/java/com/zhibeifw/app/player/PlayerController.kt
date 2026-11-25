package com.zhibeifw.app.player

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.zhibeifw.app.core.PlayContext
import com.zhibeifw.app.core.SleepSetting
import com.zhibeifw.app.core.pickNext
import com.zhibeifw.app.data.AppFiles
import com.zhibeifw.app.data.EpisodeInfo
import com.zhibeifw.app.data.Store
import com.zhibeifw.app.design.generated.Tok
import com.zhibeifw.app.net.Network
import com.zhibeifw.app.net.buildUrl
import kotlinx.coroutines.CoroutineExceptionHandler
import com.google.common.util.concurrent.ListenableFuture
import androidx.core.content.ContextCompat
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.withContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

// 播放控制器，与 iOS PlayerController.swift 同样的规则。播放状态以系统播放器为准：
//  · 在不在出声：Player.isPlaying；想不想播：Player.playWhenReady（Player.Listener 回调）；
//  · 锁屏、通知栏、耳机、拔耳机、来电在 App 外的暂停/播放都改的是同一个 ExoPlayer，回调即时反映到界面；
//  · 播完接下一集靠 STATE_ENDED；锁屏信息就是 MediaItem 的元数据，换集同时更新；
//  · 定时存进度、睡眠定时：播放器所在线程（主线程）上的 Handler，在播放服务存活期间（前台服务）照常执行，不依赖界面。
// 只有一处界面层状态：点了播放、还在找地址的那一小段（pendingStart），图标先变暂停。

enum class PlayerError(val message: String, val canRetry: Boolean = false) {
    CANNOT_PLAY("网络异常，请检查网络后重试", true),
    READ_FAILED("播放资料读取失败", true),
    DAMAGED("这一集的下载文件已损坏，请重新下载"),
    GONE("这一集已下架")
}
enum class StartResult { STARTED, GONE, READ_FAILED }
data class NowPlaying(val info: EpisodeInfo, val ctx: PlayContext) {
    val episodeId get() = info.episodeId
    val seriesId get() = info.seriesId
}

const val SAVE_INTERVAL_SEC = 5.0
const val STALL_LIMIT_MS = 30_000L
const val PROBE_AFTER_MS = 5_000L

/** 后退 15 秒、前进 30 秒。 */
val SEEK_BACK_SECONDS = Tok.Player.seekBackSeconds.toDouble()
val SEEK_FORWARD_SECONDS = Tok.Player.seekForwardSeconds.toDouble()

// 取线路、问文件在不在、卡住多久算失败、用哪个播放器：平时用网络模块、规格里的时长和播放服务共用的那一个，测试里换掉
class PlayerController(
    private val ctx: Context,
    private val store: Store,
    private val files: AppFiles,
    private val net: Network,
    testPlayer: ExoPlayer? = null,
    private val routes: suspend () -> String? = { net.ensureRoutes() },
    private val headStatus: suspend (String) -> Int? = { net.headStatus(it) },
    private val stallLimitMs: Long = STALL_LIMIT_MS,
    private val probeAfterMs: Long = PROBE_AFTER_MS
) {
    private val main = Handler(Looper.getMainLooper())
    // 后台任务里没接住的错误（比如读库出错）只记日志，不让 App 崩溃
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main +
        CoroutineExceptionHandler { _, e -> Log.w("Player", "后台任务出错", e) })

    var current by mutableStateOf<NowPlaying?>(null); private set
    var isPlaying by mutableStateOf(false); private set
    var systemWantsPlay by mutableStateOf(false); private set
    var pendingStart by mutableStateOf(false); private set
    var buffering by mutableStateOf(false); private set
    var streaming by mutableStateOf(false); private set
    var position by mutableDoubleStateOf(0.0); private set
    var duration by mutableDoubleStateOf(0.0); private set
    var rate by mutableDoubleStateOf(1.0); private set
    var sleep by mutableStateOf<SleepSetting>(SleepSetting.Off); private set
    var sleepLeft by mutableStateOf<Double?>(null); private set
    var error by mutableStateOf<PlayerError?>(null)

    /** 界面上显示“暂停”图标：在出声，或用户刚点了播放、还在加载。 */
    val looksPlaying get() = isPlaying || systemWantsPlay || pendingStart
    val loadingPlayback get() = looksPlaying && (pendingStart || buffering)

    var onProgressSaved: (() -> Unit)? = null
    var onFailure: ((PlayerError) -> Unit)? = null
    var onDamaged: ((String) -> Unit)? = null

    private var lastSavedAt = Double.NEGATIVE_INFINITY
    private var generation = 0
    private var positionKnown = false
    private var markedDone = false
    private var needsReload = false
    private var stallJob: Job? = null
    private var probeJob: Job? = null
    private var pendingSeek: Pair<Double, Long>? = null
    private var durationRecorded = false
    private var attached = testPlayer
    internal val player get() = checkNotNull(attached)
    private var connection: ListenableFuture<MediaController>? = null

    private val listener = object : Player.Listener {
        override fun onIsPlayingChanged(playing: Boolean) {
            val was = isPlaying
            isPlaying = playing
            if (playing) {
                clearStall(); error = null; tick()
            }
            if (was && !playing && !player.playWhenReady && positionKnown && !markedDone) {
                readPosition(); saveNow()
            } // 在 App 外暂停：记下位置
        }

        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            systemWantsPlay = playWhenReady
            if (playWhenReady) {
                pendingStart = false; tick()
            } else clearStall()
        }

        // 来电、导航播报、提示音等短暂抢走音频：按系统默认，播放器暂时不出声，抢完自己接着播；
        // 被抢的时候先记下位置，万一这期间 App 被系统杀掉，进度也不丢
        override fun onPlaybackSuppressionReasonChanged(reason: Int) {
            if (reason == Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS && positionKnown && !markedDone) {
                readPosition(); saveNow()
            }
        }

        override fun onPlaybackStateChanged(state: Int) {
            buffering = state == Player.STATE_BUFFERING
            if (state == Player.STATE_BUFFERING) armStall()
            if (state == Player.STATE_READY) clearStall()
            if (state == Player.STATE_ENDED) onFinished()
        }

        override fun onPlayerError(e: PlaybackException) {
            Log.w("Player", "播放出错", e)
            val c = current ?: return
            // 已下载的本地文件放不了：文件坏了（截断、0 字节等），按“下载文件已损坏”处理，改回未下载，免得一直重试一个坏文件
            if (!streaming) {
                onDamaged?.invoke(c.episodeId); fail(PlayerError.DAMAGED)
            } else fail(PlayerError.CANNOT_PLAY)
        }
    }

    init {
        attached?.addListener(listener)
    }

    private suspend fun connect(): Boolean {
        if (attached != null) return true
        val future = connection ?: MediaController.Builder(ctx, SessionToken(ctx, ComponentName(ctx, PlaybackService::class.java)))
            .buildAsync().also { connection = it }
        return suspendCancellableCoroutine { continuation ->
            future.addListener({
                if (!continuation.isActive) return@addListener
                val connected = runCatching { future.get().isConnected }.getOrDefault(false)
                val engine = PlayerHolder.active
                if (connection === future && connected && engine != null) {
                    if (attached == null) {
                        attached = engine
                        engine.addListener(listener)
                    }
                    continuation.resume(true)
                } else {
                    if (connection === future) {
                        MediaController.releaseFuture(future)
                        connection = null
                    }
                    continuation.resume(false)
                }
            }, ContextCompat.getMainExecutor(ctx))
        }
    }

    internal fun disconnect() {
        if (attached == null && connection == null) return
        if (positionKnown && !markedDone) {
            readPosition()
            saveNow()
        }
        generation++
        clearStall()
        attached?.removeListener(listener)
        attached = null
        connection?.let { MediaController.releaseFuture(it) }
        connection = null
        positionKnown = false
        needsReload = current != null
        pendingStart = false
        isPlaying = false
        systemWantsPlay = false
        buffering = false
    }

    // ---------- 周期回调：位置、定时存进度、睡眠定时（播放器线程上，不依赖界面） ----------

    /** 每 0.5 秒一次，只在需要时跑：想播 / 在播，或者睡眠定时在走（原来一直空转，没播放时也每秒唤醒两次）。 */
    private var ticking = false
    private fun needsTick() =
        attached?.playWhenReady == true || attached?.isPlaying == true || sleep is SleepSetting.Timer

    private fun tick() {
        if (ticking) return
        ticking = true
        main.postDelayed(object : Runnable {
            override fun run() {
                onTick()
                if (needsTick()) main.postDelayed(this, 500) else ticking = false
            }
        }, 500)
    }

    private fun readPosition() {
        var pos = player.currentPosition / 1000.0
        pendingSeek?.let { (to, until) ->
            if (System.currentTimeMillis() >= until || abs(pos - to) < 1.5) pendingSeek =
                null else pos = to
        }
        position = pos
        val d = player.duration
        if (d > 0) {
            val ds = d / 1000.0
            if (duration == 0.0 || abs(duration - ds) > 0.5) duration = ds
            val c = current
            if (!durationRecorded && c != null) {
                durationRecorded = true
                scope.launch(store.progressIo) { store.recordDuration(c.episodeId, ds) }
            }
        }
    }

    private fun onTick() {
        if (current == null || markedDone) return
        if (sleep is SleepSetting.Timer && tickSleep()) return
        if (!positionKnown || player.mediaItemCount == 0) return
        readPosition()
        // 定时保存不通知各页面重读：正在播的这一集页面上用的是播放器的实时位置
        if (isPlaying && abs(position - lastSavedAt) >= SAVE_INTERVAL_SEC) save(position, duration, notify = false)
    }

    // ---------- 进度保存 ----------

    private fun save(pos: Double, dur: Double, np: NowPlaying? = current, notify: Boolean = true) {
        val c = np ?: return
        lastSavedAt = pos
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            withContext(store.progressIo) {
                store.recordPlayback(c.episodeId, c.seriesId, pos, dur, c.info.seriesTitle, c.info.episodeTitle, c.info.coverPath)
            }
            if (notify) onProgressSaved?.invoke()
        }
    }

    fun saveNow() {
        if (current != null && positionKnown && !markedDone) save(position, duration)
    }

    // ---------- 卡住 ----------

    private fun clearStall() {
        stallJob?.cancel(); stallJob = null; probeJob?.cancel(); probeJob = null
    }

    private fun armStall() {
        if (stallJob != null || !(systemWantsPlay || pendingStart)) return
        val c = current ?: return
        val gen = generation
        if (streaming) {
            val path = c.info.audioPath
            probeJob = scope.launch {
                delay(probeAfterMs)
                val code = headStatus(path)
                if (gen == generation && stallJob != null && (code == 404 || code == 410)) fail(
                    PlayerError.GONE
                )
            }
        }
        stallJob = scope.launch {
            delay(stallLimitMs)
            if (gen == generation) fail(PlayerError.CANNOT_PLAY)
        }
    }

    private fun failRead(error: Throwable) {
        Log.w("Player", "读取播放资料失败", error)
        fail(PlayerError.READ_FAILED)
    }

    private fun fail(e: PlayerError) {
        clearStall()
        attached?.pause()
        pendingStart = false
        needsReload = true
        isPlaying = false
        buffering = false
        error = e
        onFailure?.invoke(e)
    }

    // ---------- 播放 ----------

    fun start(episodeId: String, ctx: PlayContext): StartResult {
        val info = try {
            store.getEpisodeInfo(episodeId)
        } catch (e: Exception) {
            Log.w("Player", "读取单集失败", e)
            return StartResult.READ_FAILED
        } ?: return StartResult.GONE
        play(info, ctx)
        return StartResult.STARTED
    }

    fun play(info: EpisodeInfo, ctx: PlayContext) {
        dropExpiredSleep()
        generation++
        val gen = generation
        current?.let { prev ->
            if (positionKnown && !markedDone) {
                readPosition(); save(position, duration, prev)
            }
        }
        markedDone = false
        needsReload = false
        positionKnown = false
        durationRecorded = false
        clearStall()
        pendingSeek = null
        attached?.pause()
        current = NowPlaying(info, ctx)
        position = 0.0; duration = 0.0; error = null; buffering = true
        pendingStart = true

        scope.launch {
            val localResult = withContext(Dispatchers.IO) {
                runCatching { files.localAudio(info.episodeId, store) }
            }
            if (gen != generation) return@launch
            val local = localResult.getOrElse { failRead(it); return@launch }
            if (local is AppFiles.LocalAudio.Missing) {
                onDamaged?.invoke(info.episodeId)
                fail(PlayerError.DAMAGED)
                return@launch
            }
            var uri: String? = null
            var isLocal = false
            if (local is AppFiles.LocalAudio.Found) {
                uri = Uri.fromFile(local.file).toString(); isLocal = true
            } else routes()?.let { uri = buildUrl(it, info.audioPath) }
            if (gen != generation) return@launch
            val u = uri ?: run { fail(PlayerError.CANNOT_PLAY); return@launch }
            val progressResult = withContext(store.progressIo) { runCatching { store.loadProgress(info.episodeId) } }
            if (gen != generation) return@launch
            val prog = progressResult.getOrElse { failRead(it); return@launch }
            val connected = connect()
            if (gen != generation) return@launch
            if (!connected) { fail(PlayerError.CANNOT_PLAY); return@launch }
            val startAt = prog?.let { if (it.completed) 0.0 else it.position } ?: 0.0
            val known = prog?.duration ?: 0.0
            streaming = !isLocal
            position = startAt
            duration = known
            positionKnown = true
            val item = MediaItem.Builder()
                .setMediaId(info.episodeId)
                .setUri(u)
                .setMediaMetadata(metadata(info))
                .build()
            player.setMediaItem(item, (startAt * 1000).toLong())
            player.playbackParameters = PlaybackParameters(rate.toFloat())
            player.prepare()
            if (pendingStart) player.play() // 加载期间用户点了暂停：加载好但不出声
            save(startAt, known) // 一播放即记入“最近”
        }
    }

    /** 锁屏 / 通知栏的信息：标题＝单集标题，副标题＝课程名，封面优先用本地保存的（离线也有）。 */
    private fun metadata(info: EpisodeInfo): MediaMetadata {
        val local = files.coverFile(info.seriesId)
        val art: Uri? = when {
            local.exists() -> Uri.fromFile(local)
            info.coverPath.isNotEmpty() -> net.currentOrigin?.let {
                Uri.parse(
                    buildUrl(
                        it,
                        info.coverPath
                    )
                )
            }

            else -> null
        }
        return MediaMetadata.Builder()
            .setTitle(info.episodeTitle)
            .setArtist(info.seriesTitle)
            .setAlbumTitle(info.seriesTitle)
            .setArtworkUri(art)
            .build()
    }

    fun toggle() {
        if (current == null) return
        if (needsReload) {
            retry(); return
        }
        if (looksPlaying) pause() else resume()
    }

    fun resume() {
        val c = current ?: return
        dropExpiredSleep()
        if (needsReload || attached == null || player.mediaItemCount == 0) {
            play(c.info, c.ctx); return
        }
        if (positionKnown) player.play() else pendingStart = true
    }

    fun pause() {
        if (current == null) return
        pendingStart = false
        clearStall()
        attached?.pause()
        if (positionKnown && !markedDone) {
            readPosition(); save(position, duration)
        }
    }

    fun retry() {
        val c = current ?: return
        error = null
        play(c.info, c.ctx)
    }

    fun seekBy(delta: Double) {
        if (current == null || !positionKnown || markedDone) return
        val to = max(0.0, if (duration > 0) min(duration, position + delta) else position + delta)
        seekTo(to)
    }

    fun seekTo(sec: Double) {
        if (current == null || !positionKnown || markedDone) return
        position = sec
        pendingSeek = sec to System.currentTimeMillis() + 1000
        player.seekTo((sec * 1000).toLong())
    }

    fun changeRate(r: Double) {
        rate = r
        attached?.playbackParameters = PlaybackParameters(r.toFloat())
    }

    fun changeSleep(s: SleepSetting) {
        sleep = s
        sleepLeft = s.secondsLeft(SystemClock.elapsedRealtime())
        tick() // 定时开始走（暂停中设的定时也要按时清掉）
    }

    /** 返回 true 表示到点暂停了。 */
    private fun tickSleep(): Boolean {
        if (sleep !is SleepSetting.Timer) return false
        val left = sleep.secondsLeft(SystemClock.elapsedRealtime()) ?: 0.0
        if (left <= 0) {
            pause()
            sleep = SleepSetting.Off
            sleepLeft = null
            return true
        }
        if (left != sleepLeft) sleepLeft = left
        return false
    }

    /** 已经过了点的睡眠定时（比如停着的时候到点）：清掉，免得一开始播放就被它停下。 */
    private fun dropExpiredSleep() {
        val s = sleep
        if (s is SleepSetting.Timer && (s.secondsLeft(SystemClock.elapsedRealtime()) ?: 0.0) <= 0) {
            sleep = SleepSetting.Off; sleepLeft = null
        }
    }

    /** 用户把正在播放的这一集标记为已听完：停止，之后不把旧位置写回；再点播放从头重新加载。 */
    fun stopAsCompleted(episodeId: String): Boolean {
        if (current?.episodeId != episodeId) return false
        generation++
        markedDone = true
        positionKnown = false
        pendingStart = false
        clearStall()
        attached?.pause()
        needsReload = true
        position = 0.0
        error = null
        return true
    }

    /** 正在播放的这一集的下载被删除：停掉并清空。 */
    fun stopIfCurrent(episodeId: String) {
        if (current?.episodeId != episodeId) return
        generation++
        positionKnown = false
        markedDone = false
        pendingStart = false
        clearStall()
        attached?.pause() // stop() 不改 playWhenReady：不先暂停的话界面、通知栏还显示成“正在播放”
        attached?.stop()
        attached?.clearMediaItems()
        current = null
        position = 0.0; duration = 0.0
    }

    private fun onFinished() {
        val c = current ?: return
        val dur = if (player.duration > 0) player.duration / 1000.0 else maxOf(duration, position)
        positionKnown = false
        position = 0.0
        save(dur, dur) // 播完：算听完
        if (sleep == SleepSetting.End) { // 睡眠定时“单集结束时”优先于接下一集
            sleep = SleepSetting.Off; sleepLeft = null
            stopAtEnd()
            needsReload = true
            return
        }
        val next = runCatching {
            when (val x = c.ctx) {
                is PlayContext.Series -> pickNext(store.seriesEpisodeIds(x.seriesId), c.episodeId)
                is PlayContext.Library -> pickNext(store.doneEpisodeIds(x.seriesId), c.episodeId)
                PlayContext.Single -> null
            }
        }.getOrNull()
        val info = next?.let { runCatching { store.getEpisodeInfo(it) }.getOrNull() }
        if (info != null) play(info, c.ctx) // 自动接下一集：MediaItem 换了，锁屏信息同时更新
        else {
            // 这一集到此结束：之后播放器报的“暂停”不再存位置，免得用归零的位置把“已听完”冲掉
            stopAtEnd(); needsReload = true
        }
    }

    /** 播完不接下一集时，明确让播放器“不想播了”：Media3 播到结尾 playWhenReady 仍是 true，
     *  不清掉的话界面（looksPlaying）、通知栏、锁屏都还显示成“正在播放”（和 iOS 的 player.pause() 一致）。 */
    private fun stopAtEnd() {
        pendingStart = false
        clearStall()
        attached?.pause()
    }

}
