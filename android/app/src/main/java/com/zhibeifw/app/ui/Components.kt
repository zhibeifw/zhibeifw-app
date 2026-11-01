package com.zhibeifw.app.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.snapping.rememberSnapFlingBehavior
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.hideFromAccessibility
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.zhibeifw.app.AppModel
import com.zhibeifw.app.core.DlStatus
import com.zhibeifw.app.core.PillKind
import com.zhibeifw.app.core.PillState
import com.zhibeifw.app.core.seriesStatusText
import com.zhibeifw.app.data.SeriesCard
import com.zhibeifw.app.design.C
import com.zhibeifw.app.design.Separator
import com.zhibeifw.app.design.ZIcon
import com.zhibeifw.app.design.ZTextStyle
import com.zhibeifw.app.design.generated.Tok
import com.zhibeifw.app.design.generated.Tok.Component as CP
import com.zhibeifw.app.design.generated.Tok.Font.Style as S
import com.zhibeifw.app.design.ts
import com.zhibeifw.app.images.CoverImage
import java.io.File
import kotlin.math.floor
import kotlin.math.roundToInt
import kotlinx.coroutines.launch


val Float.d: Dp get() = this.dp

// ---------------- 尺寸（与 iOS Layout.swift 一致） ----------------
object Layout {
    fun isTablet(w: Float) = w >= Tok.Space.tabletBreakpoint
    fun pageMargin(w: Float) = if (isTablet(w)) Tok.Space.pageMarginTablet else Tok.Space.pageMargin
    /** 手机：大卡（新课程）1 张完整 + 右侧 36 露边，小卡一屏 1.5 张。
     *  平板：一屏固定张数（竖屏、横屏各一套），卡宽随屏幕变，大屏上是大图少张，不是满屏小图。 */
    fun cardWidths(w: Float, h: Float): Pair<Float, Float> {
        if (!isTablet(w)) return (w - 68f) to floor((w - 32f) / 1.5f)
        val portrait = h >= w
        val nl = if (portrait) Tok.Card.largePerScreenTabletPortrait else Tok.Card.largePerScreenTabletLandscape
        val ns = if (portrait) Tok.Card.smallPerScreenTabletPortrait else Tok.Card.smallPerScreenTabletLandscape
        val avail = w - pageMargin(w)
        return floor(avail / nl - Tok.Space.cardGap) to floor(avail / ns - Tok.Space.cardGap)
    }

    fun coverHeight(width: Float) = (width * 9f / 16f).roundToInt().toFloat()
    fun seriesRowCoverWidth(w: Float) = (w * CP.SeriesRow.coverRatio).roundToInt().toFloat()
    fun tileColumns(w: Float) =
        if (isTablet(w)) Tok.Card.TileColumns.tablet.toInt() else Tok.Card.TileColumns.phone.toInt()

    fun isLargeText(scale: Float) = scale >= Tok.Font.largeTextScale

    /** 页面内容底部给悬浮导航留的空白：展开时两层的总高度 + 8 + 16（安全区另加）。 */
    // 列表底部要让出：播放胶囊 + 系统导航栏（Material NavigationBar 高 80）+ 间距
    val navReserve get() = Tok.Nav.capsuleHeight + Tok.Nav.bottomMargin + Tok.Nav.androidBarHeight + 16f
}

@Composable
fun windowWidth(): Float = LocalConfiguration.current.screenWidthDp.toFloat()

/** 窗口高度，只用来分平板的竖屏、横屏。 */
@Composable
fun windowHeight(): Float = LocalConfiguration.current.screenHeightDp.toFloat()
@Composable
fun fontScale(): Float = LocalDensity.current.fontScale

@Composable
fun Txt(
    text: String,
    style: ZTextStyle,
    color: Color,
    modifier: Modifier = Modifier,
    maxLines: Int = Int.MAX_VALUE,
    maxScale: Float? = null,
    align: TextAlign? = null
) {
    BasicText(
        text,
        modifier,
        style = style.ts(color, maxScale)
            .let { if (align != null) it.copy(textAlign = align) else it },
        maxLines = maxLines,
        overflow = TextOverflow.Ellipsis
    )
}

/** 按下态：整块不透明度 0.7。 */
@Composable
fun Modifier.pressable(
    enabled: Boolean = true,
    label: String? = null,
    role: Role = Role.Button,
    onClick: () -> Unit
): Modifier =
    // 按下反馈用 Material 的水波纹
    this.clickable(enabled = enabled, onClickLabel = label, role = role, onClick = onClick)

fun Modifier.minTouch() =
    this.defaultMinSize(Tok.Space.MinTouchTarget.android.d, Tok.Space.MinTouchTarget.android.d)

// ---------------- 页面骨架：自绘页头 ----------------

/**
 * 页面骨架：页头用系统（Material 3）的顶部栏——有大标题的页面是 LargeTopAppBar（往上滑收成小标题），
 * 系列页、关于页是普通 TopAppBar；返回键、右边按钮都放在系统顶部栏里。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PageScaffold(
    model: AppModel,
    title: String,
    subtitle: String? = null,
    showBack: Boolean = true,
    largeTitle: Boolean = true,
    centeredTitle: Boolean = false,
    revealAt: Dp? = null,
    onRefresh: (suspend () -> Unit)? = null,
    state: LazyListState = rememberLazyListState(),
    /** 顶部栏那一行正中的内容（主页的“正在更新…”），叠在顶部栏上、不占位置 */
    topCenter: @Composable () -> Unit = {},
    trailing: @Composable () -> Unit = {},
    overlay: @Composable () -> Unit = {},
    content: LazyListScope.() -> Unit,
) {
    val m = Layout.pageMargin(windowWidth())
    val density = LocalDensity.current
    val behavior =
        if (largeTitle && !showBack) TopAppBarDefaults.exitUntilCollapsedScrollBehavior() else TopAppBarDefaults.pinnedScrollBehavior()
    // 系列页没有大标题：封面和课程名滚出去之后，顶部栏才显示课程名
    val revealed by remember(revealAt) {
        derivedStateOf { revealAt == null || state.firstVisibleItemIndex > 0 || state.firstVisibleItemScrollOffset / density.density > revealAt.value }
    }
    val colors = TopAppBarDefaults.topAppBarColors(
        containerColor = C.background(),
        scrolledContainerColor = C.background(),
        titleContentColor = C.labelPrimary(),
        navigationIconContentColor = C.labelPrimary(),
        actionIconContentColor = C.labelPrimary()
    )
    val nav: @Composable () -> Unit = {
        if (showBack) IconButton(
            onClick = { model.navController?.popBackStack() },
            modifier = Modifier.semantics { contentDescription = "返回" }) {
            ZIcon("chevron-back", Tok.PageHeader.iconSize.d, C.labelPrimary())
        }
    }
    val actions: @Composable RowScope.() -> Unit = { trailing() }
    var refreshing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    Box(Modifier.fillMaxSize().background(C.background())) {
        Scaffold(
            modifier = Modifier.nestedScroll(behavior.nestedScrollConnection),
            containerColor = C.background(),
            contentWindowInsets = WindowInsets(0),
            topBar = {
                // 一级页（主页、搜索，没有返回键）用大标题；子页（有返回键）用小标题顶部栏，副标题放在小标题下面
                val sub = showBack && largeTitle
                Box {
                    when {
                        sub -> TopAppBar(
                            title = {
                                Column {
                                    Text(title, maxLines = 1)
                                    if (subtitle != null) Txt(
                                        subtitle,
                                        S.caption,
                                        C.labelSecondary(),
                                        maxLines = 1
                                    )
                                }
                            },
                            navigationIcon = nav,
                            actions = actions,
                            colors = colors,
                            scrollBehavior = behavior
                        )

                        largeTitle -> LargeTopAppBar(
                            title = { Text(title, maxLines = 1) },
                            navigationIcon = nav,
                            actions = actions,
                            colors = colors,
                            scrollBehavior = behavior,
                            expandedHeight = Tok.PageHeader.androidLargeExpanded.d
                        )

                        centeredTitle -> CenterAlignedTopAppBar(title = {
                            Text(
                                title,
                                maxLines = 1
                            )
                        }, navigationIcon = nav, actions = actions, colors = colors)

                        else -> TopAppBar(
                            title = { if (revealed) Text(title, maxLines = 1) },
                            navigationIcon = nav,
                            actions = actions,
                            colors = colors,
                            scrollBehavior = behavior
                        )
                    }
                    // 顶部栏那一行（系统的小顶栏高度）正中叠一层：主页的“正在更新…”。不占位置，出现、消失都不挤动内容
                    Box(
                        Modifier.align(Alignment.TopCenter)
                            .windowInsetsPadding(TopAppBarDefaults.windowInsets)
                            .height(TopAppBarDefaults.TopAppBarExpandedHeight),
                        contentAlignment = Alignment.Center
                    ) { topCenter() }
                }
            },
        ) { pad ->
            val list: @Composable (Modifier) -> Unit = { mod ->
                LazyColumn(Modifier.fillMaxSize().then(mod), state = state) {
                    if (subtitle != null && !(showBack && largeTitle)) item("__subtitle") {
                        Txt(
                            subtitle,
                            S.caption,
                            C.labelSecondary(),
                            Modifier.padding(
                                start = m.d,
                                end = m.d,
                                bottom = CP.PageTitle.bottomGap.d
                            )
                        )
                    }
                    content()
                    item("__bottom") {
                        Spacer(
                            Modifier.height(
                                Layout.navReserve.d + WindowInsets.safeDrawing.asPaddingValues()
                                    .calculateBottomPadding()
                            )
                        )
                    }
                }
            }
            if (onRefresh != null) {
                // 顶部留白放在下拉刷新这一层，不放在列表上：下拉区域从顶部栏下面算起，转圈才不会藏在大标题顶部栏后面
                PullToRefreshBox(
                    isRefreshing = refreshing, onRefresh = {
                        scope.launch {
                            refreshing = true; try {
                            onRefresh()
                        } finally {
                            refreshing = false
                        }
                        }
                    },
                    modifier = Modifier.padding(top = pad.calculateTopPadding())
                ) { list(Modifier) }
            } else list(Modifier.padding(top = pad.calculateTopPadding()))
        }
        overlay()
    }
}


// ---------------- 板块标题 ----------------

@Composable
fun SectionTitle(title: String, onClick: (() -> Unit)? = null) {
    val m = Layout.pageMargin(windowWidth())
    val mod = Modifier.padding(horizontal = m.d)
    Row(
        (if (onClick != null) mod.pressable(label = "查看全部课程", onClick = onClick).semantics {
            contentDescription = "$title，点按查看全部课程"
        } else mod.semantics { heading() }),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(CP.SectionTitle.arrowGap.d),
    ) {
        Txt(title, S.sectionTitle, C.labelPrimary())
        if (onClick != null) ZIcon(
            "chevron-forward",
            CP.SectionTitle.arrowSize.d,
            C.labelTertiary()
        )
    }
}

// ---------------- 内容卡片与横滑行 ----------------

@Composable
fun ContentCard(
    model: AppModel,
    card: SeriesCard,
    width: Float,
    large: Boolean,
    title: String,
    subtitle: String? = null,
    onClick: () -> Unit
) {
    Column(
        Modifier.width(width.d).pressable(onClick = onClick).clearAndSetSemantics {
            contentDescription = "$title${subtitle?.let { "，$it" } ?: ""}，点按进入系列详情"
        }) {
        CoverImage(
            model.images,
            card.coverPath,
            card.id,
            RoundedCornerShape((if (large) Tok.Radius.cardLarge else Tok.Radius.cardSmall).d),
            Modifier.width(width.d).height(Layout.coverHeight(width).d),
            originVersion = model.net.originVersion
        )
        Spacer(Modifier.height(Tok.Space.cardImageToTitle.d))
        Txt(title, S.cardTitle, C.labelPrimary(), maxLines = 2)
        if (subtitle != null) {
            Spacer(Modifier.height(Tok.Space.textGap.d)); Txt(
                subtitle,
                S.caption,
                C.labelSecondary(),
                maxLines = 1
            )
        }
    }
}

@Composable
fun CardRow(
    model: AppModel,
    cards: List<SeriesCard>,
    large: Boolean,
    titleOf: (SeriesCard) -> String = { it.title },
    subtitleOf: (SeriesCard) -> String? = { null },
    onTap: (SeriesCard) -> Unit
) {
    val W = windowWidth()
    val (lw, sw) = Layout.cardWidths(W, windowHeight())
    val w = if (large || Layout.isLargeText(fontScale())) lw else sw
    val st = rememberLazyListState()
    LazyRow(
        state = st,
        flingBehavior = rememberSnapFlingBehavior(st),
        contentPadding = PaddingValues(horizontal = Layout.pageMargin(W).d),
        horizontalArrangement = Arrangement.spacedBy(Tok.Space.cardGap.d),
        verticalAlignment = Alignment.Top,
    ) {
        items(cards, key = { it.id }) { c ->
            ContentCard(
                model,
                c,
                w,
                large,
                titleOf(c),
                subtitleOf(c)
            ) { onTap(c) }
        }
    }
}

// ---------------- 大图列表行 H2 ----------------

@Composable
fun SeriesRowView(
    model: AppModel,
    id: String,
    title: String,
    meta: List<String>,
    coverPath: String,
    localCover: File? = null,
    menu: (() -> List<List<MenuItem>>)? = null,
    onClick: () -> Unit
) {
    val W = windowWidth()
    val m = Layout.pageMargin(W)
    val cw = Layout.seriesRowCoverWidth(minOf(W, Tok.Card.seriesRowMaxWidth))
    val large = Layout.isLargeText(fontScale())
    val sem = Modifier.clearAndSetSemantics {
        contentDescription = (listOf(title) + meta).joinToString("，") + "，点按进入系列详情"
    }
    // 有菜单时（收藏夹、资料库）右边是“•••”（去掉滑动后，操作都放这里），放在行的点按区外面
    if (menu != null) Box {
        SeriesRowBody(
            model,
            id,
            title,
            meta,
            coverPath,
            localCover,
            large,
            cw,
            m,
            sem,
            hasMenu = true,
            onClick
        )
        Box(
            Modifier.align(if (large) Alignment.BottomEnd else Alignment.CenterEnd)
                .padding(end = (m - (CP.EpisodeRow.moreTouch - CP.EpisodeRow.moreIcon) / 2).d)
        ) { MoreButton(items = menu) }
    } else SeriesRowBody(
        model,
        id,
        title,
        meta,
        coverPath,
        localCover,
        large,
        cw,
        m,
        sem,
        hasMenu = false,
        onClick
    )
}

@Composable
private fun SeriesRowBody(
    model: AppModel,
    id: String,
    title: String,
    meta: List<String>,
    coverPath: String,
    localCover: File?,
    large: Boolean,
    cw: Float,
    m: Float,
    sem: Modifier,
    hasMenu: Boolean,
    onClick: () -> Unit
) {
    if (large) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = m.d).pressable(onClick = onClick)
                .then(sem), verticalArrangement = Arrangement.spacedBy(CP.SeriesRow.textGap.d)
        ) {
            CoverImage(
                model.images,
                coverPath,
                id,
                RoundedCornerShape(Tok.Radius.cardSmall.d),
                Modifier.fillMaxWidth().aspectRatio(16f / 9f),
                localCover,
                model.net.originVersion
            )
            Column(verticalArrangement = Arrangement.spacedBy(CP.SeriesRow.metaGap.d)) {
                Txt(title, S.listRowTitle, C.labelPrimary())
                meta.forEach { Txt(it, S.caption, C.labelSecondary()) }
            }
        }
    } else {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = m.d).pressable(onClick = onClick)
                .then(sem),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(CP.SeriesRow.textGap.d)
        ) {
            CoverImage(
                model.images,
                coverPath,
                id,
                RoundedCornerShape(Tok.Radius.cardSmall.d),
                Modifier.width(cw.d).height(Layout.coverHeight(cw).d),
                localCover,
                model.net.originVersion
            )
            Column(
                Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(CP.SeriesRow.metaGap.d)
            ) {
                Txt(title, S.listRowTitle, C.labelPrimary(), maxLines = 2)
                meta.forEach { Txt(it, S.caption, C.labelSecondary()) }
            }
            if (hasMenu) Spacer(Modifier.width(CP.EpisodeRow.moreTouch.d)) // 给“•••”留位置
            else ZIcon("chevron-forward", CP.SectionTitle.arrowSize.d, C.labelTertiary())
        }
    }
}

// ---------------- 列表行 H（搜索结果） ----------------

@Composable
fun ListRowView(model: AppModel, card: SeriesCard, onClick: () -> Unit) {
    val m = Layout.pageMargin(windowWidth())
    Box {
        Row(
            Modifier.fillMaxWidth().heightIn(min = CP.ListRow.minHeight.d)
                .pressable(onClick = onClick)
                .clearAndSetSemantics {
                    contentDescription =
                        "${card.title}，${seriesStatusText(card.status)}，点按进入系列详情"
                }
                .padding(horizontal = m.d, vertical = CP.ListRow.paddingV.d),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(CP.ListRow.gap.d),
        ) {
            CoverImage(
                model.images,
                card.coverPath,
                card.id,
                RoundedCornerShape(Tok.Radius.thumbnail.d),
                Modifier.width(CP.ListRow.thumbWidth.d).height(CP.ListRow.thumbHeight.d),
                originVersion = model.net.originVersion
            )
            Column(
                Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(Tok.Space.textGap.d)
            ) {
                Txt(card.title, S.listRowTitle, C.labelPrimary(), maxLines = 2)
                Txt(seriesStatusText(card.status), S.caption, C.labelSecondary())
            }
        }
        Separator(
            Modifier.align(Alignment.BottomStart)
                .padding(start = (m + CP.ListRow.thumbWidth + CP.ListRow.gap).d)
        )
    }
}

// ---------------- 播放胶囊 ----------------

@Composable
fun PlayPill(
    state: PillState,
    ratio: Double,
    playing: Boolean,
    onIcon: () -> Unit,
    onBody: () -> Unit
) {
    Row(
        Modifier.clip(CircleShape).background(C.backgroundSecondary())
            .height(CP.EpisodeRow.pillHeight.d), verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier.width(CP.EpisodeRow.pillIconTouch.d).height(CP.EpisodeRow.pillHeight.d)
                .pressable(onClick = onIcon).semantics {
                    contentDescription =
                        if (playing) "暂停" else if (state.kind == PillKind.DONE) "已听完，点按重新播放" else "播放，${state.text}"
                },
            contentAlignment = Alignment.Center,
        ) {
            when {
                playing -> ZIcon("pause", CP.EpisodeRow.playIcon.d, C.labelPrimary())
                state.kind == PillKind.DONE -> ZIcon(
                    "refresh",
                    CP.EpisodeRow.replayIcon.d,
                    C.labelPrimary()
                )

                else -> ZIcon("play", CP.EpisodeRow.playIcon.d, C.labelPrimary())
            }
        }
        // 读屏只读左边的播放按钮（已含“剩 N 分钟”），这一块藏起来，和 iOS 一致
        Row(
            Modifier.height(CP.EpisodeRow.pillHeight.d).pressable(onClick = onBody)
                .clearAndSetSemantics { hideFromAccessibility() }
                .padding(end = CP.EpisodeRow.pillPaddingH.d),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(CP.EpisodeRow.pillGap.d),
        ) {
            if (state.kind == PillKind.HALF) {
                val track = C.separator();
                val fill = C.labelPrimary()
                Canvas(
                    Modifier.width(CP.EpisodeRow.miniBarWidth.d)
                        .height(CP.EpisodeRow.miniBarHeight.d)
                ) {
                    val h = size.height
                    drawLine(
                        track,
                        Offset(h / 2, h / 2),
                        Offset(size.width - h / 2, h / 2),
                        h,
                        StrokeCap.Round
                    )
                    if (ratio > 0) drawLine(
                        fill,
                        Offset(h / 2, h / 2),
                        Offset(h / 2 + (size.width - h) * ratio.toFloat(), h / 2),
                        h,
                        StrokeCap.Round
                    )
                }
            }
            Txt(state.text, S.buttonText, C.labelPrimary(), maxLines = 1)
        }
    }
}

/** 下载状态图标：已下载、下载中（进度环，环内方块，点＝暂停）、已暂停（灰色环两竖线，点＝继续）。 */
@Composable
fun DownloadIndicator(status: DlStatus?, ratio: Double, onTap: () -> Unit) {
    when (status) {
        DlStatus.DONE -> Box(Modifier.semantics {
            contentDescription = "已下载"
        }) { ZIcon("arrow-down-circle", CP.EpisodeRow.statusIcon.d, C.labelSecondary()) }

        DlStatus.QUEUED, DlStatus.DOWNLOADING -> Box(
            Modifier.minTouch().pressable(onClick = onTap)
                .semantics { contentDescription = "下载中，点按暂停" },
            contentAlignment = Alignment.Center
        ) { ProgressRing(ratio, false) }

        DlStatus.PAUSED -> Box(
            Modifier.minTouch().pressable(onClick = onTap)
                .semantics { contentDescription = "已暂停，点按继续下载" },
            contentAlignment = Alignment.Center
        ) { ProgressRing(ratio, true) }

        null -> {}
    }
}

/** 下载进度环：系统（Material 3）的圆形进度；中间是系统图标（下载中：停止方块；已暂停：暂停）。 */
@Composable
fun ProgressRing(ratio: Double, paused: Boolean, size: Dp = CP.EpisodeRow.ring.d) {
    val col = if (paused) C.labelTertiary() else C.labelPrimary()
    Box(Modifier.size(size), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(
            progress = { maxOf(CP.EpisodeRow.ringMinArc.toDouble(), ratio).toFloat() },
            modifier = Modifier.size(size),
            color = col,
            trackColor = C.separator(),
            strokeWidth = CP.EpisodeRow.ringLine.d,
        )
        ZIcon(if (paused) "pause" else "stop", CP.EpisodeRow.ringIcon.d, col)
    }
}

/** “•••”按钮（20 labelTertiary，触控区 44），点了弹系统下拉菜单。 */
@Composable
fun MoreButton(label: String = "更多操作", items: () -> List<List<MenuItem>>) {
    NativeMenu(items) { open ->
        Box(
            Modifier.size(CP.EpisodeRow.moreTouch.d).pressable(onClick = open)
                .semantics { contentDescription = label },
            contentAlignment = Alignment.Center,
        ) { ZIcon("ellipsis-horizontal", CP.EpisodeRow.moreIcon.d, C.labelTertiary()) }
    }
}

// ---------------- 空状态、错误、提示条 ----------------

@Composable
fun EmptyStateView(text: String, modifier: Modifier = Modifier, retry: (() -> Unit)? = null) {
    Column(
        modifier.fillMaxWidth().padding(horizontal = CP.EmptyState.paddingH.d),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(CP.RetryButton.topGap.d)
    ) {
        Txt(text, S.body, C.labelSecondary(), align = TextAlign.Center)
        if (retry != null) RetryButton("重试", retry)
    }
}

@Composable
fun RetryButton(title: String, onClick: () -> Unit) {
    Box(
        Modifier.heightIn(min = CP.RetryButton.height.d).clip(CircleShape)
            .background(C.backgroundSecondary()).pressable(onClick = onClick)
            .padding(horizontal = CP.RetryButton.paddingH.d), contentAlignment = Alignment.Center
    ) {
        Txt(title, S.buttonLarge, C.labelPrimary())
    }
}

@Composable
fun BannerView(text: String, actions: List<Pair<String, () -> Unit>>) {
    val m = Layout.pageMargin(windowWidth())
    Row(
        Modifier.padding(horizontal = m.d).fillMaxWidth().heightIn(min = CP.Banner.height.d)
            .clip(RoundedCornerShape(CP.Banner.radius.d)).background(C.backgroundSecondary())
            .padding(horizontal = CP.Banner.paddingH.d),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(CP.Banner.paddingH.d),
    ) {
        Txt(text, S.bannerText, C.labelSecondary(), Modifier.weight(1f))
        actions.forEach { (t, a) ->
            Box(
                Modifier.heightIn(min = CP.Banner.height.d).pressable(onClick = a),
                contentAlignment = Alignment.Center
            ) { Txt(t, S.bannerAction, C.labelPrimary()) }
        }
    }
}

@Composable
fun Fade(visible: Boolean, content: @Composable () -> Unit) =
    AnimatedVisibility(visible, enter = fadeIn(), exit = fadeOut()) { content() }

@Composable
fun widthOf(maxW: Float, content: @Composable () -> Unit) =
    BoxWithConstraints(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
        Box(Modifier.widthIn(max = maxW.d)) { content() }
    }

/** 简介右下角“更多”左边的一小段渐隐。 */
@Composable
fun fadeBrush(bg: Color) = Brush.horizontalGradient(listOf(bg.copy(alpha = 0f), bg))
