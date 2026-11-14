package com.zhibeifw.app.player

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.CommandButton
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.zhibeifw.app.MainActivity
import com.zhibeifw.app.design.generated.Tok

/** 整个 App 只有一个 ExoPlayer（播放状态的唯一来源）。 */
@OptIn(UnstableApi::class)
object PlayerHolder {
    val waveform = AudioWaveform()
    @Volatile
    private var p: ExoPlayer? = null
    val SEEK_BACK_MS = (Tok.Player.seekBackSeconds * 1000).toLong()
    val SEEK_FORWARD_MS = (Tok.Player.seekForwardSeconds * 1000).toLong()

    fun get(ctx: Context): ExoPlayer = p ?: synchronized(this) {
        p ?: ExoPlayer.Builder(ctx.applicationContext, object : androidx.media3.exoplayer.DefaultRenderersFactory(ctx.applicationContext) {
            override fun buildAudioSink(context: Context, enableFloatOutput: Boolean, enableAudioOutputPlaybackParams: Boolean): androidx.media3.exoplayer.audio.AudioSink? =
                super.buildAudioSink(context, enableFloatOutput, enableAudioOutputPlaybackParams)?.let { WaveformAudioSink(it, waveform) }
        })
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(C.USAGE_MEDIA)
                    .setContentType(C.AUDIO_CONTENT_TYPE_SPEECH).build(), true
            ) // 来电、导航播报等短暂抢占音频：按系统默认暂时停下，结束后接着播
            .setHandleAudioBecomingNoisy(true) // 拔耳机自动暂停
            .setSeekBackIncrementMs(SEEK_BACK_MS)
            .setSeekForwardIncrementMs(SEEK_FORWARD_MS)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .build().also { p = it }
    }
}

/**
 * 后台播放 + 锁屏/通知栏媒体控制：Media3 的 MediaSessionService，锁屏和通知栏由 Media3 自动处理。
 * 媒体会话整个播放期间只建一次，换集只换 MediaItem 的元数据。
 * 按钮只有三个：后退 15 秒、播放/暂停、前进 30 秒；不放上一集/下一集。
 */
@OptIn(UnstableApi::class)
class PlaybackService : MediaSessionService() {
    private var session: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        val player = PlayerHolder.get(this)
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val back = CommandButton.Builder(CommandButton.ICON_SKIP_BACK_15)
            .setPlayerCommand(Player.COMMAND_SEEK_BACK).setDisplayName("后退 15 秒")
            .setSlots(CommandButton.SLOT_BACK).build()
        val fwd = CommandButton.Builder(CommandButton.ICON_SKIP_FORWARD_30)
            .setPlayerCommand(Player.COMMAND_SEEK_FORWARD).setDisplayName("前进 30 秒")
            .setSlots(CommandButton.SLOT_FORWARD).build()
        session = MediaSession.Builder(this, player)
            .setSessionActivity(open)
            .setMediaButtonPreferences(listOf(back, fwd))
            .setCallback(object : MediaSession.Callback {
                override fun onConnect(
                    session: MediaSession,
                    controller: MediaSession.ControllerInfo
                ): MediaSession.ConnectionResult {
                    val cmds = MediaSession.ConnectionResult.DEFAULT_PLAYER_COMMANDS.buildUpon()
                        .remove(Player.COMMAND_SEEK_TO_NEXT)
                        .remove(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
                        .remove(Player.COMMAND_SEEK_TO_PREVIOUS)
                        .remove(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
                        // 播放服务对外公开（Media3 要求）：别的 App 连上来只能控制播放，不能把内容换掉
                        .remove(Player.COMMAND_SET_MEDIA_ITEM)
                        .remove(Player.COMMAND_CHANGE_MEDIA_ITEMS)
                        .remove(Player.COMMAND_SET_PLAYLIST_METADATA)
                        .build()
                    return MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                        .setAvailablePlayerCommands(cmds).build()
                }
            })
            .build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    override fun onTaskRemoved(rootIntent: Intent?) {
        val p = session?.player
        if (p == null || !p.playWhenReady || p.mediaItemCount == 0) stopSelf()
    }

    override fun onDestroy() {
        session?.run { release() }
        session = null
        super.onDestroy()
    }
}
