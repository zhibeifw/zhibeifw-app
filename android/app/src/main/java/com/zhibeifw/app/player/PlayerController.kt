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

enum class PlayerError { CANNOT_PLAY, DAMAGED, GONE }
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

class PlayerController(
    private val ctx: Context,
    private val store: Store,
    private val files: AppFiles,
    private val net: Network
) {
    val player = PlayerHolder.get(ctx)
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

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

    var onProgressSaved: (() -> Unit)? = null
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
    private var controller: MediaController? = null

    init {
        // 连上自己的 MediaSessionService：服务因此启动，锁屏和通知栏才有播放卡片
        MediaController.Builder(
            ctx,
            SessionToken(ctx, ComponentName(ctx, PlaybackService::class.java))
        ).buildAsync().also { f ->
            f.addListener({
                controller = try {
                    f.get()
                } catch (e: Exception) {
                    null
                }
            }, { main.post(it) })
        }
        player.addListener(object : Player.Listener {
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

            override fun onPlaybackStateChanged(state: Int) {
                buffering = state == Player.STATE_BUFFERING
                if (state == Player.STATE_BUFFERING) armStall()
                if (state == Player.STATE_READY) clearStall()
                if (state == Player.STATE_ENDED) onFinished()
            }

            override fun onPlayerError(e: PlaybackException) {
                Log.w("Player", "播放出错", e)
                if (current != null) fail(PlayerError.CANNOT_PLAY)
            }
        })
        tick()
    }

    // ---------- 周期回调：位置、定时存进度、睡眠定时（播放器线程上，不依赖界面） ----------

    /** 每 0.5 秒一次，只在需要时跑：想播 / 在播，或者睡眠定时在走（原来一直空转，没播放时也每秒唤醒两次）。 */
    private var ticking = false
    private fun needsTick() =
        player.playWhenReady || player.isPlaying || sleep is SleepSetting.Timer

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
                durationRecorded = true; runCatching { store.recordDuration(c.episodeId, ds) }
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
        try {
            store.recordPlayback(
                c.episodeId,
                c.seriesId,
                pos,
                dur,
                c.info.seriesTitle,
                c.info.episodeTitle,
                c.info.coverPath
            )
            lastSavedAt = pos
            if (notify) onProgressSaved?.invoke()
        } catch (e: Exception) {
            Log.w("Player", "保存播放进度出错", e)
        } // 写库失败不影响播放
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
                delay(PROBE_AFTER_MS)
                val code = net.headStatus(path)
                if (gen == generation && stallJob != null && (code == 404 || code == 410)) fail(
                    PlayerError.GONE
                )
            }
        }
        stallJob = scope.launch {
            delay(STALL_LIMIT_MS)
            if (gen == generation) fail(PlayerError.CANNOT_PLAY)
        }
    }

    private fun fail(e: PlayerError) {
        clearStall()
        player.pause()
        pendingStart = false
        needsReload = true
        isPlaying = false
        buffering = false
        error = e
    }

    // ---------- 播放 ----------

    fun start(episodeId: String, ctx: PlayContext): Boolean {
        val info = runCatching { store.getEpisodeInfo(episodeId) }.getOrNull() ?: return false
        play(info, ctx)
        return true
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
        positionKnown = false
        durationRecorded = false
        clearStall()
        pendingSeek = null
        player.pause()
        current = NowPlaying(info, ctx)
        position = 0.0; duration = 0.0; error = null; buffering = true
        pendingStart = true

        val local = files.localAudio(info.episodeId, store)
        if (local is AppFiles.LocalAudio.Missing) {
            onDamaged?.invoke(info.episodeId)
            fail(PlayerError.DAMAGED)
            return
        }
        scope.launch {
            var uri: String? = null
            var isLocal = false
            if (local is AppFiles.LocalAudio.Found) {
                uri = Uri.fromFile(local.file).toString(); isLocal = true
            } else net.ensureRoutes()?.let { uri = buildUrl(it, info.audioPath) }
            if (gen != generation) return@launch
            val u = uri ?: run { fail(PlayerError.CANNOT_PLAY); return@launch }
            val prog = store.loadProgress(info.episodeId)
            val startAt = prog?.let { if (it.completed) 0.0 else it.position } ?: 0.0
            val known = prog?.duration ?: 0.0
            needsReload = false
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
        if (needsReload || player.mediaItemCount == 0) {
            play(c.info, c.ctx); return
        }
        if (positionKnown) player.play() else pendingStart = true
    }

    fun pause() {
        if (current == null) return
        pendingStart = false
        clearStall()
        player.pause()
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
        player.playbackParameters = PlaybackParameters(r.toFloat())
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

    /** 用户把正在播放的这一集标为已听完：停止，之后不把旧位置写回；再点播放从头重新加载。 */
    fun stopAsCompleted(episodeId: String): Boolean {
        if (current?.episodeId != episodeId) return false
        generation++
        markedDone = true
        positionKnown = false
        pendingStart = false
        clearStall()
        player.pause()
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
        player.stop()
        player.clearMediaItems()
        current = null
        position = 0.0; duration = 0.0
    }

    private fun onFinished() {
        val c = current ?: return
        val dur = if (duration > 0) duration else position
        save(dur, dur) // 播完：算听完
        if (sleep == SleepSetting.End) { // 睡眠定时“单集结束时”优先于接下一集
            sleep = SleepSetting.Off; sleepLeft = null
            stopAtEnd()
            needsReload = true
            return
        }
        val next = when (val x = c.ctx) {
            is PlayContext.Series -> pickNext(store.seriesEpisodeIds(x.seriesId), c.episodeId)
            is PlayContext.Library -> pickNext(store.doneEpisodeIds(x.seriesId), c.episodeId)
            PlayContext.Single -> null
        }
        val info = next?.let { store.getEpisodeInfo(it) }
        if (info != null) play(info, c.ctx) // 自动接下一集：MediaItem 换了，锁屏信息同时更新
        else {
            stopAtEnd(); needsReload = true; position = 0.0
        }
    }

    /** 播完不接下一集时，明确让播放器“不想播了”：Media3 播到结尾 playWhenReady 仍是 true，
     *  不清掉的话界面（looksPlaying）、通知栏、锁屏都还显示成“正在播放”（和 iOS 的 player.pause() 一致）。 */
    private fun stopAtEnd() {
        pendingStart = false
        clearStall()
        player.pause()
    }

    fun release() {
        controller?.release()
    }
}
