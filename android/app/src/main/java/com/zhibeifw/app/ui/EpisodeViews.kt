package com.zhibeifw.app.ui

import com.zhibeifw.app.design.generated.Tok.Component as CP
import com.zhibeifw.app.design.generated.Tok.Font.Style as S
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import com.zhibeifw.app.AppModel
import com.zhibeifw.app.core.DlMenuAction
import com.zhibeifw.app.core.DlStatus
import com.zhibeifw.app.core.PlayContext
import com.zhibeifw.app.core.Prog
import com.zhibeifw.app.core.downloadMenuItems
import com.zhibeifw.app.core.liveProgress
import com.zhibeifw.app.core.pillState
import com.zhibeifw.app.core.progressRatio
import com.zhibeifw.app.data.RecentRow
import com.zhibeifw.app.design.C
import com.zhibeifw.app.design.Separator
import com.zhibeifw.app.design.generated.Tok
import com.zhibeifw.app.images.CoverImage

/** 一集在列表里需要的全部信息（系列页、资料库第二层、最近共用）。 */
data class EpisodeItem(
    val episodeId: String,
    val seriesId: String,
    val title: String,
    val progress: Prog?,
    val epDuration: Double?,
    val dlState: DlStatus?,
    val canDownload: Boolean = true
)

/** 正在播放的这一集用播放器的实时位置。 */
fun AppModel.liveProg(e: EpisodeItem): Prog? {
    val p = player ?: return e.progress
    // 先看是不是正在播的这一集：不是的话不读位置，列表里其它行不会跟着播放进度每半秒重画
    if (p.current?.episodeId != e.episodeId) return e.progress
    return liveProgress(
        p.current?.episodeId,
        p.position,
        p.duration,
        p.looksPlaying,
        e.episodeId,
        e.progress
    )
}

fun AppModel.dlStatus(e: EpisodeItem): Pair<DlStatus?, Double> {
    downloads?.let { dm -> dm.items[e.episodeId]?.let { return it.status to dm.ratio(e.episodeId) } }
    return e.dlState to (if (e.dlState == DlStatus.DONE) 1.0 else 0.0)
}

/** 下载状态图标的点按：下载中＝暂停这一集；已暂停＝继续。 */
fun AppModel.tapDownloadIndicator(e: EpisodeItem) {
    when (dlStatus(e).first) {
        DlStatus.QUEUED, DlStatus.DOWNLOADING -> downloads?.pause(e.episodeId)
        DlStatus.PAUSED -> resumeDownloads(e.seriesId, episodeId = e.episodeId)
        else -> {}
    }
}

fun AppModel.downloadItems(e: EpisodeItem): List<MenuItem> =
    downloadMenuItems(dlStatus(e).first, e.canDownload).map { d ->
        MenuItem(
            d.title,
            d.icon,
            d.destructive
        ) { runDownloadAction(d.action, e) }
    }

fun AppModel.runDownloadAction(a: DlMenuAction, e: EpisodeItem) {
    when (a) {
        // 资料库里的集可能已不在目录里：用下载记录里存的信息重新下（v1.0 这里误落到“标记已听完”的分支过）
        DlMenuAction.DOWNLOAD -> (dlItem(e.episodeId)
            ?: runCatching { store.getDownload(e.episodeId) }.getOrNull()?.item)?.let { download(listOf(it)) }

        DlMenuAction.PAUSE -> downloads?.pause(e.episodeId)
        DlMenuAction.RESUME -> resumeDownloads(e.seriesId, episodeId = e.episodeId)
        DlMenuAction.CANCEL -> downloads?.cancel(e.episodeId)
        DlMenuAction.DELETE -> deleteDownload(e.episodeId)
    }
}

fun AppModel.completedNow(e: EpisodeItem) = liveProg(e)?.completed ?: false

fun AppModel.markItem(e: EpisodeItem): MenuItem {
    val done = completedNow(e)
    return MenuItem(
        if (done) "标记为未听完" else "标记为已听完",
        "checkmark-circle-outline"
    ) { markCompleted(e.episodeId, e.seriesId, !done) }
}

fun AppModel.goCourseItem(seriesId: String) = MenuItem("前往课程", "arrow-forward-circle-outline") {
    nav.push(com.zhibeifw.app.Routes.series(seriesId))
}


/** 集数行：标题 + 操作行（播放胶囊、下载状态、“•••”）。 */
@Composable
fun EpisodeRowView(
    model: AppModel,
    item: EpisodeItem,
    ctx: PlayContext,
    showDownloadedIcon: Boolean = true,
    menuGroups: (EpisodeItem) -> List<List<MenuItem>>
) {
    val prog = model.liveProg(item)
    val state = pillState(prog, item.epDuration ?: 0.0)
    val p = model.player
    val playing = p?.current?.episodeId == item.episodeId && p.looksPlaying
    val (dl, ratio) = model.dlStatus(item)
    val m = Layout.pageMargin(windowWidth())
    Box {
        Column(Modifier.fillMaxWidth().pressable { model.playAndOpen(item.episodeId, ctx) }
            .padding(horizontal = m.d, vertical = CP.EpisodeRow.paddingV.d)) {
            Txt(item.title, S.listRowTitle, C.labelPrimary(), maxLines = 2)
            Spacer(Modifier.height(CP.EpisodeRow.titleToActions.d))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(CP.EpisodeRow.statusGap.d)
            ) {
                PlayPill(
                    state,
                    prog?.let { progressRatio(it.position, it.duration) } ?: 0.0,
                    playing,
                    onIcon = { model.togglePlay(item.episodeId, ctx) },
                    onBody = { model.playAndOpen(item.episodeId, ctx) })
                if (dl != DlStatus.DONE || showDownloadedIcon) DownloadIndicator(
                    dl,
                    ratio
                ) { model.tapDownloadIndicator(item) }
                Spacer(Modifier.weight(1f))
                MoreButton { menuGroups(item) }
            }
        }
        Separator(Modifier.align(Alignment.BottomStart).padding(horizontal = m.d))
    }
}

fun RecentRow.item() = EpisodeItem(
    episodeId,
    seriesId,
    epTitle,
    progress,
    epDuration,
    dlState,
    canDownload = !gone && audioPath != null
)

/** 单集行 H3（最近）：封面缩略图 + “课程名 单集标题” + 操作行。 */
@Composable
fun RecentRowView(model: AppModel, row: RecentRow) {
    val it = row.item()
    val prog = model.liveProg(it)
    val state = pillState(prog, it.epDuration ?: 0.0)
    val p = model.player
    val playing = p?.current?.episodeId == row.episodeId && p.looksPlaying
    val (dl, ratio) = model.dlStatus(it)
    val m = Layout.pageMargin(windowWidth())
    Box {
        Row(
            Modifier.fillMaxWidth().pressable { model.playFromRecent(row, true) }
                .padding(horizontal = m.d, vertical = CP.RecentRow.paddingV.d),
            horizontalArrangement = Arrangement.spacedBy(CP.RecentRow.gap.d)
        ) {
            CoverImage(
                model.images,
                row.coverPath,
                row.seriesId,
                RoundedCornerShape(Tok.Radius.thumbnail.d),
                Modifier.width(CP.RecentRow.thumbWidth.d).height(CP.RecentRow.thumbHeight.d),
                model.files.coverFile(row.seriesId),
                model.net.originVersion
            )
            Column(Modifier.weight(1f)) {
                Txt(
                    "${row.seriesTitle} ${row.epTitle}",
                    S.listRowTitle,
                    C.labelPrimary(),
                    maxLines = 2
                )
                Spacer(Modifier.height(CP.RecentRow.actionsTop.d))
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(CP.EpisodeRow.statusGap.d)
                ) {
                    PlayPill(
                        state,
                        prog?.let { progressRatio(it.position, it.duration) } ?: 0.0,
                        playing,
                        onIcon = { model.playFromRecent(row, false) },
                        onBody = { model.playFromRecent(row, true) })
                    DownloadIndicator(dl, ratio) { model.tapDownloadIndicator(it) }
                    Spacer(Modifier.weight(1f))
                    MoreButton {
                        listOf(
                            model.downloadItems(it) + listOf(
                                model.markItem(it),
                                model.goCourseItem(row.seriesId)
                            ),
                            listOf(
                                MenuItem(
                                    "删除记录",
                                    "trash-outline",
                                    destructive = true
                                ) { model.hideRecent(row.episodeId) })
                        )
                    }
                }
            }
        }
        Separator(Modifier.align(Alignment.BottomStart))
    }
}
