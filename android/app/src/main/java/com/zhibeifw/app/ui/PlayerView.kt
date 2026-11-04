package com.zhibeifw.app.ui

import android.os.SystemClock
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.zhibeifw.app.AppModel
import com.zhibeifw.app.core.PLAYBACK_RATES
import com.zhibeifw.app.core.SLEEP_CHOICES
import com.zhibeifw.app.core.SleepSetting
import com.zhibeifw.app.core.clock
import com.zhibeifw.app.core.progressRatio
import com.zhibeifw.app.core.remainingClock
import com.zhibeifw.app.core.sleepLabel
import com.zhibeifw.app.design.C
import com.zhibeifw.app.design.SeekIcon
import com.zhibeifw.app.design.ZIcon
import com.zhibeifw.app.design.generated.Tok
import com.zhibeifw.app.design.generated.Tok.Component as CP
import com.zhibeifw.app.design.generated.Tok.Font.Style as S
import com.zhibeifw.app.images.CoverImage
import com.zhibeifw.app.player.PlayerController
import com.zhibeifw.app.player.SEEK_BACK_SECONDS
import com.zhibeifw.app.player.SEEK_FORWARD_SECONDS
import java.math.BigDecimal
import java.math.RoundingMode
import kotlin.math.roundToInt
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** 倍速文字：最多两位小数、去掉末尾的 0（0.8、1.3、2），和 iOS 的 %g 一样。 */
fun rateText(r: Double): String =
    BigDecimal(r).setScale(2, RoundingMode.HALF_UP).stripTrailingZeros().toPlainString()

fun rateLabel(r: Double) = rateText(r) + "×"

/** 全屏播放页。系统的全高底部弹窗（Material 3 ModalBottomSheet，直接全部展开）：系统的拖动条、下拉收起、点外面 / 返回键收起、Android 13+ 返回预览动画都由系统处理。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlayerLayer(model: AppModel) {
    val p = model.player
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    // 别处关掉播放页（比如点课程名去课程页）时，先让系统把弹窗收下去再移除
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(model.playerOpen) {
        if (model.playerOpen) shown = true
        // 收起动画可能被打断（比如同时换了屏幕方向限制）：不管有没有放完都移除弹窗，免得拖动条卡在屏幕底部
        else if (shown) {
            try {
                state.hide()
            } finally {
                shown = false
            }
        }
    }
    if (!shown || p?.current == null) return
    ModalBottomSheet(
        onDismissRequest = { model.closePlayer(); shown = false },
        sheetState = state,
        sheetMaxWidth = Dp.Unspecified, // 横屏也铺满整个宽度（默认最宽 640）
        containerColor = C.background(),
    ) { PlayerView(model, p) }
}

@Composable
private fun PlayerView(model: AppModel, p: PlayerController) {
    var scrub by remember { mutableStateOf<Double?>(null) }
    // 睡眠定时倒计时：只在按分钟定时时每秒刷新显示，其余时候不让整页每秒重组（到点暂停由播放器侧保证）
    var tick by remember { mutableStateOf(0) }
    val counting = p.sleep is SleepSetting.Timer
    LaunchedEffect(counting) {
        while (counting) {
            delay(1000); tick++
        }
    }
    BoxWithConstraints(
        Modifier.fillMaxSize()
            .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom))
    ) {
        val W = maxWidth.value;
        val H = maxHeight.value
        val landscape = W > H
        if (landscape) {
            val tablet = minOf(W, H) >= Tok.Space.tabletBreakpoint
            val coverW = if (tablet) CP.Player.LandscapeTablet.cover else minOf(
                CP.Player.LandscapePhone.cover,
                (H - CP.Player.LandscapePhone.coverHeightInset) * 16f / 9f
            )
            val rightW =
                if (tablet) CP.Player.LandscapeTablet.right else CP.Player.LandscapePhone.right
            val gap = if (tablet) CP.Player.LandscapeTablet.gap else CP.Player.LandscapePhone.gap
            Row(
                Modifier.fillMaxSize(),
                horizontalArrangement = Arrangement.spacedBy(gap.d, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Cover(model, p, coverW)
                Controls(model, p, rightW, tight = !tablet, scrub, { scrub = it }, tick)
            }
        } else {
            val maxW = if (Layout.isTablet(W)) Tok.Player.portraitMaxWidth else W
            val contentW = minOf(W, maxW)
            Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
                Box(
                    Modifier.weight(1f).padding(vertical = CP.Player.coverMinPad.d),
                    contentAlignment = Alignment.Center
                ) {
                    Cover(model, p, contentW - 2 * CP.Player.coverSideMargin)
                }
                Controls(
                    model,
                    p,
                    contentW - 2 * CP.Player.coverSideMargin,
                    false,
                    scrub,
                    { scrub = it },
                    tick
                )
                Spacer(Modifier.height(CP.Player.bottomPad.d))
            }
        }
    }
}

@Composable
private fun Cover(model: AppModel, p: PlayerController, width: Float) {
    val c = p.current ?: return
    val dark = isSystemInDarkTheme()
    val shape = RoundedCornerShape(CP.Player.coverRadius.d)
    CoverImage(
        model.images, c.info.coverPath, c.seriesId, shape,
        Modifier.widthIn(min = (width * CP.Player.coverMinRatio).d, max = width.d)
            .aspectRatio(16f / 9f, matchHeightConstraintsFirst = true)
            .let { if (dark) it else it.shadow(CP.Player.CoverShadow.androidElevation.d, shape) },
        model.files.coverFile(c.seriesId), model.net.originVersion
    )
}

@Composable
private fun Controls(
    model: AppModel,
    p: PlayerController,
    width: Float,
    tight: Boolean,
    scrub: Double?,
    onScrub: (Double?) -> Unit,
    tick: Int
) {
    val c = p.current ?: return
    val pos = scrub ?: p.position
    Column(Modifier.width(width.d)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(
                Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(CP.Player.courseGap.d)
            ) {
                Txt(c.info.episodeTitle, S.playerTitle, C.labelPrimary(), maxLines = 2)
                Row(
                    Modifier.heightIn(min = CP.Player.courseMinHeight.d)
                        .pressable { model.goToSeries(c.seriesId) }
                        .semantics { contentDescription = "${c.info.seriesTitle}，前往课程" },
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(2f.d)
                ) {
                    Txt(c.info.seriesTitle, S.body, C.labelSecondary(), maxLines = 1)
                    ZIcon(
                        "chevron-forward",
                        (CP.SectionTitle.arrowSize * CP.SectionTitle.inlineArrowScale).d,
                        C.labelSecondary()
                    )
                }
            }
            NativeMenu({ moreGroups(model, p) }) { open ->
                Box(
                    Modifier.size(Tok.Space.MinTouchTarget.android.d).pressable(onClick = open)
                        .semantics { contentDescription = "更多操作" },
                    contentAlignment = Alignment.Center
                ) {
                    Box(
                        Modifier.size(CP.Player.moreButton.d).clip(CircleShape)
                            .background(C.backgroundSecondary()),
                        contentAlignment = Alignment.Center
                    ) {
                        ZIcon("ellipsis-horizontal", CP.Player.moreIcon.d, C.labelPrimary())
                    }
                }
            }
        }
        Spacer(Modifier.height((if (tight) CP.Player.LandscapePhone.tightGap else CP.Player.titleToBar).d))
        ProgressBar(
            pos,
            p.duration,
            onScrub = { onScrub(it) },
            onCommit = { p.seekTo(it); onScrub(null) },
            onStep = { p.seekBy(it) })
        Row(Modifier.padding(top = CP.Player.timeTop.d)) {
            Txt(clock(pos), S.caption, C.labelSecondary())
            Spacer(Modifier.weight(1f))
            val now = remember(tick, p.sleep) { SystemClock.elapsedRealtime() } // 每秒刷新一次倒计时；换定时时立刻重取
            val right = when (val s = p.sleep) {
                SleepSetting.End -> sleepLabel(null)
                is SleepSetting.Timer -> sleepLabel(s.secondsLeft(now))
                SleepSetting.Off -> remainingClock(pos, p.duration)
            }
            Txt(right, S.caption, C.labelSecondary())
        }
        Spacer(Modifier.height((if (tight) CP.Player.LandscapePhone.tightGap else CP.Player.barToControls).d))
        Row(
            Modifier.fillMaxWidth()
                .padding(horizontal = (CP.Player.controlsSideMargin - CP.Player.coverSideMargin).d),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            // 倍速：系统下拉菜单单选
            NativeMenu({
                listOf(PLAYBACK_RATES.map { r ->
                    MenuItem(
                        if (r == 1.0) "1×（正常）" else rateLabel(
                            r
                        ), checked = p.rate == r
                    ) { p.changeRate(r) }
                })
            }) { open ->
                Box(
                    Modifier.size(Tok.Space.MinTouchTarget.android.d).pressable(onClick = open)
                    .semantics {
                        contentDescription =
                            "播放速度 ${rateLabel(p.rate).removeSuffix("×")} 倍，点按更改"
                    }, contentAlignment = Alignment.Center
                ) {
                    Txt(
                        rateLabel(p.rate),
                        S.rateLabel,
                        C.labelSecondary(),
                        maxScale = Tok.Font.MaxScale.rateLabel
                    )
                }
            }
            Box(
                Modifier.size(Tok.Space.MinTouchTarget.android.d)
                    .pressable { p.seekBy(-SEEK_BACK_SECONDS) }
                    .semantics { contentDescription = "后退 ${SEEK_BACK_SECONDS.toInt()} 秒" },
                contentAlignment = Alignment.Center
            ) {
                SeekIcon(false, CP.Player.seekIcon.d, C.labelPrimary())
            }
            Box(
                Modifier.size(CP.Player.playIcon.d).pressable { p.toggle() }
                    .semantics { contentDescription = if (p.looksPlaying) "暂停" else "播放" },
                contentAlignment = Alignment.Center
            ) {
                ZIcon(
                    if (p.looksPlaying) "pause" else "play",
                    CP.Player.playIcon.d,
                    C.labelPrimary()
                )
            }
            Box(
                Modifier.size(Tok.Space.MinTouchTarget.android.d)
                    .pressable { p.seekBy(SEEK_FORWARD_SECONDS) }
                    .semantics { contentDescription = "前进 ${SEEK_FORWARD_SECONDS.toInt()} 秒" },
                contentAlignment = Alignment.Center
            ) {
                SeekIcon(true, CP.Player.seekIcon.d, C.labelPrimary())
            }
            NativeMenu({ listOf(sleepItems(p)) }) { open ->
                Box(
                    Modifier.size(Tok.Space.MinTouchTarget.android.d).pressable(onClick = open)
                    .semantics { contentDescription = sleepA11y(p) },
                    contentAlignment = Alignment.Center
                ) {
                    ZIcon(
                        "moon",
                        CP.Player.moonIcon.d,
                        if (p.sleep == SleepSetting.Off) C.labelTertiary() else C.labelPrimary()
                    )
                }
            }
        }
    }
}

private fun sleepA11y(p: PlayerController) = when (val s = p.sleep) {
    SleepSetting.Off -> "睡眠定时，未开启"
    SleepSetting.End -> "睡眠定时，本集结束时"
    is SleepSetting.Timer -> "睡眠定时，剩余 ${
        Math.ceil((s.secondsLeft(SystemClock.elapsedRealtime()) ?: 0.0) / 60).toInt()
    } 分钟"
}

private fun sleepItems(p: PlayerController) = SLEEP_CHOICES.map { ch ->
    MenuItem(ch.title, checked = p.sleep.choiceId == ch.id) {
        when {
            ch.id == "off" -> p.changeSleep(SleepSetting.Off)
            ch.id == "end" -> p.changeSleep(SleepSetting.End)
            ch.minutes != null -> p.changeSleep(
                SleepSetting.Timer(
                    SystemClock.elapsedRealtime() + ch.minutes * 60_000L,
                    ch.minutes
                )
            )
        }
    }
}

private fun moreGroups(model: AppModel, p: PlayerController): List<List<MenuItem>> {
    val c = p.current ?: return emptyList()
    val e = EpisodeItem(
        c.episodeId,
        c.seriesId,
        c.info.episodeTitle,
        runCatching { model.store.loadProgress(c.episodeId) }.getOrNull(),
        null,
        runCatching { model.store.getDownload(c.episodeId)?.state }.getOrNull()
    )
    val fav = runCatching { model.store.isFavorite(c.seriesId) }.getOrDefault(false)
    return listOf(
        model.downloadItems(e) + model.markItem(e),
        listOf(
            MenuItem(
                if (fav) "取消收藏课程" else "收藏课程",
                if (fav) "bookmark" else "bookmark-outline"
            ) { model.toggleFavorite(c.seriesId, c.info.seriesTitle, c.info.coverPath) },
            MenuItem("前往课程", "arrow-forward-circle-outline") { model.goToSeries(c.seriesId) },
        ),
    )
}

/** 播放进度：系统（Material 3）的滑块。拖动时只更新显示的时间，松手才跳转。 */
@OptIn(ExperimentalMaterial3Api::class) // 轨道的参数（缝隙、末端圆点）在 Material 3 里还标着实验性
@Composable
private fun ProgressBar(
    position: Double,
    duration: Double,
    onScrub: (Double) -> Unit,
    onCommit: (Double) -> Unit,
    onStep: (Double) -> Unit
) {
    var dragValue by remember { mutableStateOf<Float?>(null) }
    val max = maxOf(duration, 0.0001).toFloat()
    val colors = SliderDefaults.colors(
        thumbColor = Tok.Color.progressFill.c(),
        activeTrackColor = Tok.Color.progressFill.c(),
        inactiveTrackColor = Tok.Color.progressTrack.c()
    )
    val interaction = remember { MutableInteractionSource() }
    // Material 3 滑块默认是新式样（粗轨道、竖条把手、两边留缝、末端小圆点），更像音量设置；
    // 用它自带的参数配成媒体进度的样子：细轨道 + 圆形把手，不留缝、不画末端圆点
    Slider(
        value = dragValue ?: position.toFloat().coerceIn(0f, max),
        onValueChange = { v -> dragValue = v; onScrub(v.toDouble()) },
        onValueChangeFinished = { dragValue?.let { onCommit(it.toDouble()) }; dragValue = null },
        valueRange = 0f..max,
        enabled = duration > 0,
        colors = colors,
        interactionSource = interaction,
        thumb = {
            SliderDefaults.Thumb(
                interactionSource = interaction, colors = colors, enabled = duration > 0,
                thumbSize = DpSize(Tok.ProgressBar.thumb.d, Tok.ProgressBar.thumb.d)
            )
        },
        track = { st ->
            SliderDefaults.Track(
                sliderState = st,
                colors = colors,
                enabled = duration > 0,
                thumbTrackGapSize = 0.dp,
                drawStopIndicator = null,
                modifier = Modifier.height(Tok.ProgressBar.height.d)
            )
        },
        modifier = Modifier.fillMaxWidth().semantics {
            contentDescription = "播放进度"
            stateDescription =
                "已播放 ${clock(position)}，剩余 ${clock(maxOf(0.0, duration - position))}"
        },
    )
}


