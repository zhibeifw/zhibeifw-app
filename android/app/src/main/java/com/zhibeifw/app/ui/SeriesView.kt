package com.zhibeifw.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import com.zhibeifw.app.AlertButton
import com.zhibeifw.app.AlertSpec
import com.zhibeifw.app.AppModel
import com.zhibeifw.app.Routes
import com.zhibeifw.app.core.DlStatus
import com.zhibeifw.app.core.PlayContext
import com.zhibeifw.app.core.seriesInfoText
import com.zhibeifw.app.data.DlItem
import com.zhibeifw.app.data.EpisodeRow
import com.zhibeifw.app.data.SeriesHeader
import com.zhibeifw.app.design.C
import com.zhibeifw.app.design.Separator
import com.zhibeifw.app.design.ZIcon
import com.zhibeifw.app.design.generated.Tok
import com.zhibeifw.app.design.generated.Tok.Component as CP
import com.zhibeifw.app.design.generated.Tok.Font.Style as S
import com.zhibeifw.app.design.ts

private enum class LoadState { LOADING, READY, GONE }

/** 系列详情页。 */
@Composable
fun SeriesView(model: AppModel, seriesId: String) {
    var header by remember { mutableStateOf<SeriesHeader?>(null) }
    var episodes by remember { mutableStateOf<List<EpisodeRow>>(emptyList()) }
    var state by remember { mutableStateOf(LoadState.LOADING) }
    var oldestFirst by remember { mutableStateOf(false) }
    val list = rememberLazyListState()
    val W = windowWidth()
    val m = Layout.pageMargin(W)

    fun refreshRows() {
        episodes = runCatching { model.store.loadEpisodes(seriesId) }.getOrDefault(emptyList())
        header = header?.let { h -> h.copy(favorited = runCatching { model.store.isFavorite(seriesId) }.getOrDefault(h.favorited)) }
    }

    // 只看本机目录，不联网（只有启动和下拉刷新取 index.json）。本机目录没有这门课 = 已下架
    fun load() {
        val h = runCatching { model.store.loadSeriesHeader(seriesId) }.getOrNull()
        if (h != null) {
            header = h; refreshRows(); state = LoadState.READY
        } else state = LoadState.GONE
    }
    LaunchedEffect(model.catalogVersion) { load() }
    LaunchedEffect(model.progressVersion, model.favoritesVersion, model.downloadsVersion) {
        if (state == LoadState.READY) refreshRows()
    }

    val coverW = minOf(W, 640f) - 2 * CP.SeriesHeader.coverMargin
    PageScaffold(
        model, header?.title ?: "", largeTitle = false, state = list,
        revealAt = (Tok.PageHeader.rowHeight + CP.SeriesHeader.coverTop + Layout.coverHeight(coverW) + CP.SeriesHeader.titleTop + S.seriesTitle.lineHeight).d,
        trailing = {
            NativeMenu({
                listOf(
                    listOf(
                        MenuItem(
                            "按最新到最旧排序",
                            "arrow-down",
                            checked = !oldestFirst
                        ) { oldestFirst = false },
                        MenuItem(
                            "按最旧到最新排序",
                            "arrow-up",
                            checked = oldestFirst
                        ) { oldestFirst = true },
                    )
                )
            }) { open ->
                // Material 3 切换图标按钮：默认是普通图标，非默认（最旧到最新）时加浅色圆底（FilledTonalIconButton）
                val desc = Modifier.semantics {
                    contentDescription = if (oldestFirst) "排序，当前按最旧到最新" else "排序"
                }
                if (oldestFirst) FilledTonalIconButton(
                    onClick = open,
                    modifier = desc
                ) { ZIcon("swap-vertical", Tok.PageHeader.iconSize.d, C.labelPrimary()) }
                else IconButton(onClick = open, modifier = desc) {
                    ZIcon(
                        "swap-vertical",
                        Tok.PageHeader.iconSize.d,
                        C.labelPrimary()
                    )
                }
            }
        },
    ) {
        when (state) {
            LoadState.LOADING -> item("loading") {
                Box(
                    Modifier.fillMaxWidth().padding(top = (Tok.Space.scale[6] * 3).d),
                    contentAlignment = Alignment.Center
                ) { CircularProgressIndicator(color = C.labelSecondary()) }
            }

            LoadState.GONE -> item("gone") {
                EmptyStateView(
                    "这门课已下架",
                    Modifier.padding(top = (Tok.Space.scale[6] * 3).d)
                )
            }

            LoadState.READY -> {
                val h = header ?: return@PageScaffold
                item("header") { Header(model, h, episodes) }
                val rows = episodes.map {
                    EpisodeItem(
                        it.id,
                        it.seriesId,
                        it.title,
                        it.progress,
                        it.epDuration,
                        it.dlState
                    )
                }.let { if (oldestFirst) it else it.asReversed() }
                items(rows, key = { it.episodeId }) { e ->
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
                        Box(Modifier.widthIn(max = (if (Layout.isTablet(W)) CP.Player.tabletPortraitMaxWidth else W).d)) {
                            EpisodeRowView(
                                model,
                                e,
                                PlayContext.Series(seriesId)
                            ) { listOf(model.downloadItems(it) + model.markItem(it)) }
                        }
                    }
                }
            }
        }
    }
}

private data class DlAll(
    val title: String,
    val icon: String,
    val ring: Double?,
    val kind: Int
) // 0 开始 1 暂停 2 继续 3 已全部下载

@Composable
private fun Header(model: AppModel, h: SeriesHeader, episodes: List<EpisodeRow>) {
    val W = windowWidth()
    val m = Layout.pageMargin(W)
    val dark = isSystemInDarkTheme()
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
        Column(
            Modifier.widthIn(max = (if (Layout.isTablet(W)) CP.Player.tabletPortraitMaxWidth else W).d),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            val shape = RoundedCornerShape(CP.SeriesHeader.coverRadius.d)
            com.zhibeifw.app.images.CoverImage(
                model.images, h.coverPath, h.id, shape,
                Modifier.padding(horizontal = CP.SeriesHeader.coverMargin.d)
                    .padding(top = CP.SeriesHeader.coverTop.d).fillMaxWidth().aspectRatio(16f / 9f)
                    .let {
                        if (dark) it else it.shadow(
                            CP.SeriesHeader.Shadow.androidElevation.d,
                            shape
                        )
                    }, originVersion = model.net.originVersion
            )
            Txt(
                h.title,
                S.seriesTitle,
                C.labelPrimary(),
                Modifier.padding(horizontal = m.d).padding(top = CP.SeriesHeader.titleTop.d)
                    .semantics { heading() },
                align = TextAlign.Center
            )
            // 按钮行：收藏、下载全部
            val dl = downloadAllState(model, episodes)
            Row(
                Modifier.padding(horizontal = m.d).padding(top = CP.SeriesHeader.buttonsTop.d),
                horizontalArrangement = Arrangement.spacedBy(CP.SeriesHeader.buttonGap.d)
            ) {
                PillButton(
                    Modifier.weight(1f),
                    if (h.favorited) "bookmark" else "bookmark-outline",
                    null,
                    if (h.favorited) "已收藏" else "收藏",
                    if (h.favorited) "取消收藏" else "收藏这门课"
                ) {
                    model.toggleFavorite(h.id, h.title, h.coverPath)
                }
                PillButton(
                    Modifier.weight(1f),
                    dl.icon,
                    dl.ring,
                    dl.title,
                    dl.title
                ) { tapDownloadAll(model, h, episodes, dl) }
            }
            if (h.description != null) DescriptionBlock(
                h.description,
                Modifier.padding(horizontal = m.d).padding(top = CP.SeriesHeader.descTop.d)
            ) {
                model.sheet = SheetSpec(h.title, h.categoryName, h.description)
            }
            // 信息行：分类名 › · 共 N 节课 · 更新中
            Row(
                Modifier.fillMaxWidth().padding(horizontal = m.d)
                    .padding(top = CP.SeriesHeader.infoTop.d),
                verticalAlignment = Alignment.CenterVertically
            ) {
                if (h.categoryName != null) {
                    // 不用 heightIn(min = 48) 撑高这一行（看着像空了一行）；Compose 会把小于 48dp 的可点元素的触控区自动扩到 48dp
                    Row(
                        Modifier.pressable { model.nav.push(Routes.category(h.categoryId)) }.semantics {
                        contentDescription = "${h.categoryName}，点按查看全部课程"
                    },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Tok.Space.textGap.d)
                    ) {
                        Txt(h.categoryName, S.captionStrong, C.labelPrimary())
                        ZIcon(
                            "chevron-forward",
                            (S.caption.size * CP.SectionTitle.inlineArrowScale).d,
                            C.labelPrimary()
                        )
                    }
                }
                // 分类名后面是一整段文字：大字号放不下时整段换行，不拆成几块各自折行
                Txt(
                    seriesInfoText(h.categoryName != null, episodes.size, h.status),
                    S.caption,
                    C.labelSecondary(),
                    Modifier.weight(1f)
                )
            }
            Separator(
                Modifier.padding(horizontal = m.d).padding(top = CP.SeriesHeader.separatorTop.d)
            )
            Txt(
                "全部课程",
                S.sectionTitle,
                C.labelPrimary(),
                Modifier.fillMaxWidth().padding(horizontal = m.d).padding(
                    top = CP.SeriesHeader.sectionTop.d,
                    bottom = CP.SeriesHeader.sectionBottom.d
                ).semantics { heading() })
        }
    }
}

private fun downloadAllState(model: AppModel, episodes: List<EpisodeRow>): DlAll {
    if (episodes.isEmpty()) return DlAll("下载全部", "arrow-down-circle-outline", null, 0)
    var done = 0;
    var active = 0;
    var paused = 0
    for (e in episodes) when (model.downloads?.items?.get(e.id)?.status ?: e.dlState) {
        DlStatus.DONE -> done++
        DlStatus.QUEUED, DlStatus.DOWNLOADING -> active++
        DlStatus.PAUSED -> paused++
        null -> {}
    }
    return when {
        active > 0 -> DlAll("暂停全部", "", done.toDouble() / episodes.size, 1)
        paused > 0 -> DlAll("继续下载", "arrow-down-circle-outline", null, 2)
        done == episodes.size -> DlAll("已全部下载", "checkmark-circle", null, 3)
        else -> DlAll("下载全部", "arrow-down-circle-outline", null, 0)
    }
}

private fun tapDownloadAll(model: AppModel, h: SeriesHeader, episodes: List<EpisodeRow>, s: DlAll) {
    when (s.kind) {
        0 -> model.download(episodes.filter {
            (model.downloads?.items?.get(it.id)?.status ?: it.dlState) == null
        }
            .map { DlItem(it.id, h.id, h.title, it.title, it.pos, it.audioPath) })

        1 -> model.downloads?.pauseAll(h.id)
        2 -> model.resumeDownloads(h.id)
        else -> model.alert = AlertSpec(
            "删除“${h.title}”的下载？",
            "将删除这门课已下载的 ${episodes.size} 节内容。课程仍可在线收听，也可以重新下载。",
            listOf(
                AlertButton("取消", cancel = true),
                AlertButton("删除", destructive = true) {
                    model.player?.current?.let { c ->
                        if (c.seriesId == h.id) model.player?.stopIfCurrent(
                            c.episodeId
                        )
                    }
                    model.downloads?.removeSeries(h.id)
                },
            )
        )
    }
}

@Composable
private fun PillButton(
    modifier: Modifier,
    icon: String,
    ring: Double?,
    title: String,
    label: String,
    onClick: () -> Unit
) {
    Row(
        modifier.heightIn(min = CP.SeriesHeader.buttonHeight.d).clip(CircleShape)
            .background(C.backgroundSecondary()).pressable(onClick = onClick)
            .semantics { contentDescription = label },
        horizontalArrangement = Arrangement.spacedBy(
            CP.SeriesHeader.buttonIconGap.d,
            Alignment.CenterHorizontally
        ), verticalAlignment = Alignment.CenterVertically,
    ) {
        if (ring != null) ProgressRing(ring, false, CP.SeriesHeader.buttonIcon.d) else ZIcon(
            icon,
            CP.SeriesHeader.buttonIcon.d,
            C.labelPrimary()
        )
        Txt(title, S.buttonLarge, C.labelPrimary(), maxLines = 1)
    }
}

/** 简介：最多 3 行；超过时第 3 行末尾叠一个“更多”（左边一小段渐隐），点“更多”或简介弹出完整简介。 */
@Composable
private fun DescriptionBlock(text: String, modifier: Modifier, onMore: () -> Unit) {
    var truncated by remember(text) { mutableStateOf(false) }
    Box(
        modifier.fillMaxWidth().pressable(enabled = truncated, onClick = onMore)
            .semantics { contentDescription = text }) {
        BasicText(
            text,
            style = S.description.ts(C.labelSecondary()),
            maxLines = CP.SeriesHeader.descLines.toInt(),
            overflow = TextOverflow.Clip,
            onTextLayout = { truncated = it.hasVisualOverflow })
        if (truncated) {
            val bg = C.background()
            Row(Modifier.align(Alignment.BottomEnd)) {
                Box(
                    Modifier.width(CP.SeriesHeader.moreFade.d).height(S.description.lineHeight.d)
                        .background(fadeBrush(bg))
                )
                Box(Modifier.background(bg)) { Txt("更多", S.moreLink, C.labelPrimary()) }
            }
        }
    }
}
