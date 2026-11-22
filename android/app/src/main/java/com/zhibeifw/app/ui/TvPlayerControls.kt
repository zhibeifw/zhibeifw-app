package com.zhibeifw.app.ui

import android.os.SystemClock
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.key.*
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalFocusManager
import com.zhibeifw.app.AppModel
import com.zhibeifw.app.core.*
import com.zhibeifw.app.design.C
import com.zhibeifw.app.design.SeekIcon
import com.zhibeifw.app.design.ZIcon
import com.zhibeifw.app.design.generated.Tok
import com.zhibeifw.app.design.generated.Tok.Television as TV
import com.zhibeifw.app.images.CoverImage
import com.zhibeifw.app.player.*
import kotlinx.coroutines.delay

@Composable
internal fun TvPlayerControls(model: AppModel, p: PlayerController) {
    val current = p.current ?: return
    BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val factor = minOf(1f, maxWidth.value / (TV.playerCover + TV.playerGap + TV.playerControls + TV.margin * 2))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy((TV.playerGap * factor).d)) {
            CoverImage(model.images, current.info.coverPath, current.seriesId, RoundedCornerShape(TV.playerRadius.d),
                Modifier.width((TV.playerCover * factor).d).aspectRatio(16f / 9f), originVersion = model.net.originVersion)
            Column(Modifier.width((TV.playerControls * factor).d)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Tok.Space.scale[1].d)) {
                        Text(current.info.episodeTitle, style = MaterialTheme.typography.headlineMedium)
                        TvPill("${current.info.seriesTitle} ›", { model.goToSeries(current.seriesId) })
                    }
                    NativeMenu({ moreGroups(model, p) }) { open ->
                        TvIconButton(open, Modifier.size(Tok.Space.MinTouchTarget.android.d), label = "更多操作") {
                            ZIcon("ellipsis-horizontal", Tok.Menu.iconSize.d, LocalContentColor.current)
                        }
                    }
                }
                Spacer(Modifier.height(TV.gap.d))
                val error = p.error
                if (error != null) {
                    val message = when (error) {
                        PlayerError.GONE -> "这一集已下架"
                        PlayerError.DAMAGED -> "这一集的文件已损坏"
                        PlayerError.CANNOT_PLAY -> "暂时无法播放，请检查网络后重试"
                    }
                    Text(message, color = C.danger())
                    if (error == PlayerError.CANNOT_PLAY) TvPill("重试", { p.retry() })
                    return@Column
                }
                var scrub by remember(current.episodeId) { mutableStateOf<Double?>(null) }
                val pos = scrub ?: p.position
                val focus = LocalFocusManager.current
                var held by remember(current.episodeId) { mutableStateOf<Key?>(null) }
                fun step(key: Key) = p.seekBy(if (key == Key.DirectionLeft) -SEEK_BACK_SECONDS else SEEK_FORWARD_SECONDS)
                LaunchedEffect(held, current.episodeId) {
                    val key = held ?: return@LaunchedEffect
                    delay(500)
                    while (true) {
                        step(key)
                        delay(300)
                    }
                }
                Box(Modifier.onFocusChanged { if (!it.hasFocus) held = null }.onPreviewKeyEvent { event ->
                    val key = event.key
                    // Slider 默认用上下键微调数值。电视用这两个键离开进度条。
                    if (key == Key.DirectionUp || key == Key.DirectionDown) {
                        if (event.type == KeyEventType.KeyDown) {
                            focus.moveFocus(if (key == Key.DirectionUp) FocusDirection.Up else FocusDirection.Down)
                        }
                        return@onPreviewKeyEvent true
                    }
                    if (key != Key.DirectionLeft && key != Key.DirectionRight) return@onPreviewKeyEvent false
                    if (event.type == KeyEventType.KeyDown && event.nativeKeyEvent.repeatCount == 0) {
                        step(key)
                        held = key
                    } else if (event.type == KeyEventType.KeyUp && held == key) held = null
                    true
                }) {
                    ProgressBar(pos, p.duration, { scrub = it }, { p.seekTo(it); scrub = null }, { p.seekBy(it) })
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(clock(pos), color = C.labelSecondary())
                    val sleep = p.sleep
                    val right = when (sleep) {
                        SleepSetting.End -> sleepLabel(null)
                        is SleepSetting.Timer -> {
                            val left by produceState(sleep.secondsLeft(SystemClock.elapsedRealtime()), sleep) {
                                while (true) { value = sleep.secondsLeft(SystemClock.elapsedRealtime()); delay(1000) }
                            }
                            sleepLabel(left)
                        }
                        SleepSetting.Off -> if (p.duration > 0) remainingClock(pos, p.duration) else ""
                    }
                    Text(right, color = C.labelSecondary())
                }
                Spacer(Modifier.height(TV.sectionGap.d))
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                    val button = Modifier.size(Tok.Space.MinTouchTarget.android.d)
                    NativeMenu({ listOf(PLAYBACK_RATES.map { rate ->
                        MenuItem(if (rate == 1.0) "1×（正常）" else rateLabel(rate), checked = p.rate == rate) { p.changeRate(rate) }
                    }) }) { open -> TvIconButton(open, button, label = "播放速度") { Text(rateLabel(p.rate)) } }
                    TvIconButton({ p.seekBy(-SEEK_BACK_SECONDS) }, button, label = "后退 15 秒") {
                        SeekIcon(false, Tok.Menu.iconSize.d, LocalContentColor.current)
                    }
                    TvIconButton({ p.toggle() }, Modifier.tvEntryFocus().size(Tok.Component.Player.playIcon.d), label = if (p.looksPlaying) "暂停" else "播放") {
                        PlaybackIcon(if (p.looksPlaying) "pause" else "play", Tok.Space.scale[5].d, LocalContentColor.current, p.loadingPlayback)
                    }
                    TvIconButton({ p.seekBy(SEEK_FORWARD_SECONDS) }, button, label = "前进 30 秒") {
                        SeekIcon(true, Tok.Menu.iconSize.d, LocalContentColor.current)
                    }
                    NativeMenu({ listOf(sleepItems(p)) }) { open -> TvIconButton(open, button, label = sleepA11y(p)) {
                        ZIcon(if (p.sleep == SleepSetting.Off) "moon-outline" else "moon", Tok.Menu.iconSize.d, LocalContentColor.current)
                    } }
                }
            }
        }
    }
}
