package com.zhibeifw.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.graphics.Color
import com.zhibeifw.app.AlertButton
import com.zhibeifw.app.AlertSpec
import com.zhibeifw.app.AppModel
import com.zhibeifw.app.Routes
import com.zhibeifw.app.core.DlStatus
import com.zhibeifw.app.core.PlayContext
import com.zhibeifw.app.core.libraryCountLines
import com.zhibeifw.app.core.libraryCountText
import com.zhibeifw.app.core.seriesStatusText
import com.zhibeifw.app.data.FavoriteRow
import com.zhibeifw.app.data.LibraryEpisode
import com.zhibeifw.app.data.LibrarySeries
import com.zhibeifw.app.data.RecentRow
import com.zhibeifw.app.design.C
import com.zhibeifw.app.design.ZIcon
import com.zhibeifw.app.design.generated.Tok
import com.zhibeifw.app.design.generated.Tok.Component as CP
import com.zhibeifw.app.design.generated.Tok.Font.Style as S
import com.zhibeifw.app.design.ts

/** 最近。 */

/** 资料库标签：Material 列表行，三行进三个子页。 */
@Composable
fun LibraryHubView(model: AppModel) {
    PageScaffold(model, "资料库", showBack = false) {
        listOf(
            Triple("最近播放", "time-outline", Routes.RECENT),
            Triple("收藏", "bookmark-outline", Routes.FAVORITES),
            Triple("已下载", "arrow-down-circle-outline", Routes.LIBRARY)
        )
            .forEach { (title, icon, route) ->
                item(route) {
                    ListItem(
                        headlineContent = { Text(title, style = S.body.ts(C.labelPrimary())) },
                        leadingContent = { ZIcon(icon, Tok.Menu.iconSize.d, C.labelPrimary()) },
                        trailingContent = {
                            ZIcon(
                                "chevron-forward",
                                CP.SectionTitle.arrowSize.d,
                                C.labelTertiary()
                            )
                        },
                        colors = ListItemDefaults.colors(containerColor = C.background()),
                        modifier = Modifier.clickable { model.push(route) },
                    )
                }
            }
    }
}

@Composable
fun RecentView(model: AppModel) {
    var rows by remember { mutableStateOf<List<RecentRow>>(emptyList()) }
    val list = rememberLazyListState()
    LaunchedEffect(model.dataVersion) {
        rows = runCatching { model.store.loadRecent() }.getOrDefault(emptyList())
    }
    PageScaffold(
        model,
        "最近播放",
        subtitle = if (rows.isEmpty()) null else "${rows.size} 条记录",
        state = list,
        trailing = {
            TextButton(enabled = rows.isNotEmpty(), onClick = {
                model.alert = AlertSpec(
                    "清空最近列表？",
                    "列表中的记录会被移除。各课程的收听进度、已听完标记和已下载内容不受影响。",
                    listOf(
                        AlertButton("取消", cancel = true),
                        AlertButton(
                            "清空",
                            destructive = true
                        ) { model.store.clearRecent(); model.dataVersion++ },
                    )
                )
            }) {
                Text(
                    "清空",
                    color = if (rows.isNotEmpty()) C.labelPrimary() else C.labelTertiary()
                )
            }
        }) {
        if (rows.isEmpty()) item("empty") {
            EmptyStateView(
                "暂无收听记录",
                Modifier.padding(top = (Tok.Space.scale[6] * 4).d)
            )
        }
        items(rows, key = { it.episodeId }) { r ->
            RecentRowView(model, r)
        }
    }
}

/** 收藏夹。 */
@Composable
fun FavoritesView(model: AppModel) {
    var rows by remember { mutableStateOf<List<FavoriteRow>>(emptyList()) }
    val list = rememberLazyListState()
    LaunchedEffect(model.dataVersion) {
        rows = runCatching { model.store.loadFavorites() }.getOrDefault(emptyList())
    }
    PageScaffold(
        model,
        "收藏",
        subtitle = if (rows.isEmpty()) null else "${rows.size} 门课",
        state = list
    ) {
        if (rows.isEmpty()) item("empty") {
            EmptyStateView(
                "暂无收藏",
                Modifier.padding(top = (Tok.Space.scale[6] * 4).d)
            )
        }
        items(rows, key = { it.id }) { f ->
            Box(Modifier.padding(bottom = CP.SeriesRow.gap.d)) {
                SeriesRowView(
                    model,
                    f.id,
                    f.title,
                    listOf(if (f.gone) "已下架" else seriesStatusText(f.status)),
                    f.coverPath,
                    menu = {
                        listOf(
                            listOf(
                                MenuItem(
                                    "取消收藏",
                                    "bookmark-outline",
                                    destructive = true
                                ) { model.store.removeFavorite(f.id); model.dataVersion++ })
                        )
                    }) { model.push(Routes.series(f.id)) }
            }
        }
    }
}

/** 资料库第一层：下载过的课程，按添加先后倒序。 */
@Composable
fun LibraryView(model: AppModel) {
    var rows by remember { mutableStateOf<List<LibrarySeries>>(emptyList()) }
    val list = rememberLazyListState()
    LaunchedEffect(model.dataVersion) {
        rows = runCatching { model.store.loadLibrary() }.getOrDefault(emptyList())
    }
    val items = model.downloads?.items ?: emptyMap()
    val activeAny =
        items.values.any { it.status == DlStatus.QUEUED || it.status == DlStatus.DOWNLOADING }
    val pausedAny = items.values.any { it.status == DlStatus.PAUSED }
    val lessons = rows.sumOf { it.n }
    val doneAll = rows.sumOf { it.done }
    PageScaffold(
        model,
        "已下载",
        subtitle = if (rows.isEmpty()) null else "${rows.size} 门课 · " + libraryCountText(
            lessons,
            doneAll
        ),
        state = list
    ) {
        if (rows.isEmpty()) item("empty") {
            EmptyStateView(
                "暂无下载",
                Modifier.padding(top = (Tok.Space.scale[6] * 4).d)
            )
        }
        if (activeAny || pausedAny) item("top") {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = Tok.Space.pageMargin.d)
                    .padding(bottom = CP.SeriesRow.gap.d),
                horizontalArrangement = Arrangement.spacedBy(CP.QuickPill.gap.d)
            ) {
                TopButton(
                    Modifier.weight(1f),
                    if (activeAny) "暂停全部" else "继续全部"
                ) { if (activeAny) model.downloads?.pauseAll() else model.resumeDownloads(null) }
                TopButton(Modifier.weight(1f), "取消全部") { model.downloads?.cancelSeries(null) }
            }
        }
        items(rows, key = { it.seriesId }) { s ->
            val mine = items.values.filter { it.seriesId == s.seriesId }
            val active =
                mine.any { it.status == DlStatus.QUEUED || it.status == DlStatus.DOWNLOADING }
            val paused = mine.any { it.status == DlStatus.PAUSED }
            // 一门课的“•••”菜单：下载中 → 暂停、取消；已暂停 → 继续、取消；最后是删除下载（要确认）
            val menu = {
                val dl = buildList {
                    if (active) add(
                        MenuItem(
                            "暂停下载",
                            "pause-circle-outline"
                        ) { model.downloads?.pauseAll(s.seriesId) })
                    else if (paused) add(
                        MenuItem(
                            "继续下载",
                            "arrow-down-circle-outline"
                        ) { model.resumeDownloads(s.seriesId) })
                    if (active || paused) add(
                        MenuItem(
                            "取消下载",
                            "close-circle-outline"
                        ) { model.downloads?.cancelSeries(s.seriesId) })
                }
                val del = MenuItem("删除下载", "trash-outline", destructive = true) {
                    model.alert = AlertSpec(
                        "删除“${s.seriesTitle}”的下载？",
                        "将删除这门课已下载的 ${s.done} 节内容。课程仍可在线收听，也可以重新下载。",
                        listOf(
                            AlertButton("取消", cancel = true),
                            AlertButton("删除", destructive = true) {
                                model.player?.current?.let { c ->
                                    if (c.seriesId == s.seriesId) model.player?.stopIfCurrent(
                                        c.episodeId
                                    )
                                }
                                model.downloads?.removeSeries(s.seriesId)
                            },
                        )
                    )
                }
                if (dl.isEmpty()) listOf(listOf(del)) else listOf(dl, listOf(del))
            }
            Box(Modifier.padding(bottom = CP.SeriesRow.gap.d)) {
                SeriesRowView(
                    model,
                    s.seriesId,
                    s.seriesTitle,
                    libraryCountLines(s.n, s.done) + listOfNotNull(if (active) "下载中…" else null),
                    model.store.seriesCoverPath(s.seriesId) ?: "",
                    model.files.coverFile(s.seriesId),
                    menu = menu
                ) { model.push(Routes.libraryCourse(s.seriesId)) }
            }
        }
    }
}

@Composable
private fun TopButton(modifier: Modifier, title: String, onClick: () -> Unit) {
    Box(
        modifier.heightIn(min = CP.QuickPill.height.d).clip(CircleShape)
            .background(C.backgroundSecondary()).pressable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Txt(title, S.buttonText, C.labelPrimary())
    }
}

/** 资料库第二层：这门课已下载的集，按课程顺序。 */
@Composable
fun LibraryCourseView(model: AppModel, seriesId: String) {
    var rows by remember { mutableStateOf<List<LibraryEpisode>>(emptyList()) }
    val list = rememberLazyListState()
    LaunchedEffect(model.dataVersion) {
        rows = runCatching { model.store.loadLibraryEpisodes(seriesId) }.getOrDefault(emptyList())
    }
    val downloading = rows.any {
        (model.downloads?.items?.get(it.row.episodeId)?.status
            ?: it.row.state).let { s -> s == DlStatus.QUEUED || s == DlStatus.DOWNLOADING }
    }
    val done = rows.count {
        (model.downloads?.items?.get(it.row.episodeId)?.status ?: it.row.state) == DlStatus.DONE
    }
    PageScaffold(
        model,
        rows.firstOrNull()?.row?.seriesTitle ?: "",
        subtitle = if (rows.isEmpty()) null else libraryCountText(
            rows.size,
            done
        ) + (if (downloading) " · 下载中" else ""),
        state = list
    ) {
        if (rows.isEmpty()) item("empty") {
            EmptyStateView(
                "暂无下载",
                Modifier.padding(top = (Tok.Space.scale[6] * 4).d)
            )
        }
        items(rows, key = { it.row.episodeId }) { r ->
            val e = EpisodeItem(
                r.row.episodeId,
                r.row.seriesId,
                r.row.episodeTitle,
                r.progress,
                null,
                r.row.state
            )
            EpisodeRowView(model, e, PlayContext.Library(seriesId), showDownloadedIcon = false) {
                listOf(
                    listOf(model.markItem(it), model.goCourseItem(it.seriesId)),
                    model.downloadItems(it)
                        .map { mi -> if (mi.title == "删除下载") mi.copy(destructive = true) else mi })
            }
        }
    }
}
