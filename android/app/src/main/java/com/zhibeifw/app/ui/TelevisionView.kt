package com.zhibeifw.app.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.tv.material3.Tab as TvTab
import androidx.tv.material3.TabRow as TvTabRow
import androidx.tv.material3.TabRowDefaults
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.zhibeifw.app.AppModel
import com.zhibeifw.app.Routes
import com.zhibeifw.app.core.PlayContext
import com.zhibeifw.app.core.pillState
import com.zhibeifw.app.core.seriesInfoText
import com.zhibeifw.app.data.CourseDetails
import com.zhibeifw.app.data.RecentRow
import com.zhibeifw.app.design.C
import com.zhibeifw.app.design.ZIcon
import com.zhibeifw.app.design.generated.Tok
import com.zhibeifw.app.images.CoverImage

/** 导航动画结束、目标页恢复交互时，让遥控器落在页面自己的操作上。 */
@Composable
internal fun Modifier.tvEntryFocus(): Modifier {
    val focus = remember { FocusRequester() }
    androidx.lifecycle.compose.LifecycleEventEffect(androidx.lifecycle.Lifecycle.Event.ON_RESUME) {
        focus.requestFocus()
    }
    return focusRequester(focus)
}

private val televisionTabs = mapOf(
    Routes.SEARCH to "搜索", Routes.HOME to "主页", Routes.CATEGORIES to "分类",
    Routes.LIBRARY_HUB to "资料库", Routes.PLAYING to "正在播放", Routes.ABOUT to "关于"
)

/** 各标签独立保存页面与滚动位置，遥控器只能进入当前标签的内容。 */
@Composable
internal fun TelevisionView(model: AppModel) {
    var selected by rememberSaveable { mutableStateOf(Routes.HOME) }
    var lastBrowse by rememberSaveable { mutableStateOf(Routes.HOME) }
    var pendingSeries by rememberSaveable { mutableStateOf<String?>(null) }
    val holder = rememberSaveableStateHolder()
    val tabFocus = remember { FocusRequester() }
    var tabsFocused by remember { mutableStateOf(false) }
    fun select(target: String) {
        if (target != Routes.PLAYING) lastBrowse = target
        selected = target
    }
    LaunchedEffect(model.playerOpen) {
        if (model.playerOpen) {
            select(Routes.PLAYING)
            model.closePlayer()
        }
    }
    holder.SaveableStateProvider(selected) {
        val nav = rememberNavController()
        val entry by nav.currentBackStackEntryAsState()
        DisposableEffect(nav, selected) {
            model.nav.televisionNav = nav
            model.nav.bottomNavShown = false
            if (selected == Routes.PLAYING) model.nav.leavePlayerForSeries = { id ->
                pendingSeries = id
                select(if (lastBrowse == Routes.ABOUT) Routes.HOME else lastBrowse)
            }
            onDispose {
                model.nav.televisionNav = null
                model.nav.leavePlayerForSeries = null
            }
        }
        LaunchedEffect(nav, entry, pendingSeries) {
            val id = pendingSeries ?: return@LaunchedEffect
            val page = entry ?: return@LaunchedEffect
            if (selected != Routes.PLAYING) {
                if (Routes.seriesIdOf(page) != id) nav.navigate(Routes.series(id))
                pendingSeries = null
            }
        }
        BackHandler(selected != Routes.HOME && entry?.destination?.route == selected) {
            if (selected == Routes.PLAYING && !tabsFocused) tabFocus.requestFocus()
            else select(if (selected == Routes.PLAYING) lastBrowse else Routes.HOME)
        }
        Column(Modifier.fillMaxSize().padding(vertical = Tok.Television.verticalSafeMargin.d)) {
            Row(Modifier.fillMaxWidth().onFocusChanged { tabsFocused = it.hasFocus }
                .padding(top = Tok.Space.scale[3].d, bottom = Tok.Space.scale[1].d), horizontalArrangement = Arrangement.Center) {
                val tabs = televisionTabs
                var focusedTab by remember { mutableStateOf(selected) }
                TvTabRow(
                    selectedTabIndex = tabs.keys.indexOf(selected),
                    indicator = { positions, hasFocus ->
                        val index = tabs.keys.indexOf(if (hasFocus) focusedTab else selected)
                        positions.getOrNull(index)?.let { TabRowDefaults.PillIndicator(it, hasFocus) }
                    }
                ) {
                    tabs.forEach { (target, label) ->
                        TvTab(selected = target == selected, onFocus = { focusedTab = target },
                            onClick = { if (target == selected) nav.popBackStack(target, false) else select(target) },
                            modifier = (if (target == selected) Modifier.focusRequester(tabFocus) else Modifier)
                                .semantics { contentDescription = label }) {
                            Box(Modifier.padding(horizontal = Tok.Space.scale[3].d, vertical = Tok.Space.scale[1].d)) {
                                val color = androidx.tv.material3.LocalContentColor.current
                                when (target) {
                                    Routes.SEARCH -> ZIcon("search-outline", Tok.Menu.iconSize.d, color)
                                    Routes.ABOUT -> ZIcon("information-circle-outline", Tok.Menu.iconSize.d, color)
                                    else -> androidx.tv.material3.Text(label, color = color)
                                }
                            }
                        }
                    }
                }
            }
            Box(Modifier.weight(1f)) { Stack(model, nav, selected, true) { tabFocus.requestFocus() } }
        }
        LaunchedEffect(nav) {
            if (selected != Routes.PLAYING || model.player?.current == null) tabFocus.requestFocus()
        }
        DescriptionSheetLayer(model)
    }
}

@Composable
internal fun TvSeriesView(model: AppModel, id: String) {
    var attempt by remember(id) { mutableIntStateOf(0) }
    val details = courseDetails(model, id, attempt)
    var oldestFirst by rememberSaveable(id) { mutableStateOf(true) }
    val list = rememberLazyListState()
    val listEntry = remember(id) { FocusRequester() }
    if (details == null) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        return
    }
    if (details == CourseDetails.ReadFailed) {
        Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center) {
            Text("课程读取失败")
            TvPill("重试", { attempt++ }, Modifier.tvEntryFocus())
        }
        return
    }
    if (details is CourseDetails.Gone) {
        UnavailableCourseView(details, { model.removeFavorite(id) }, Modifier.fillMaxSize())
        return
    }
    val (header, episodes) = details as CourseDetails.Ready
    Row(Modifier.fillMaxSize().padding(horizontal = Tok.Television.margin.d, vertical = Tok.Television.gap.d),
        horizontalArrangement = Arrangement.spacedBy(Tok.Space.pageMargin.d)) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(Tok.Space.scale[1].d)) {
            CoverImage(model.images, header.coverPath, id, RoundedCornerShape(Tok.Radius.thumbnail.d),
                Modifier.fillMaxWidth().aspectRatio(16f / 9f), originVersion = model.net.originVersion)
            Text(header.title, style = MaterialTheme.typography.headlineSmall)
            header.categoryName?.let {
                TvPill(it, { model.nav.push(Routes.category(header.categoryId)) })
            }
            Text(seriesInfoText(false, episodes.size, header.status))
            Row(horizontalArrangement = Arrangement.spacedBy(Tok.Space.scale[1].d)) {
                TvPill(if (header.favorited) "已收藏" else "收藏", { model.toggleFavorite(id, header.title, header.coverPath) },
                    Modifier.tvEntryFocus(), icon = if (header.favorited) "bookmark" else "bookmark-outline")
                TvPill(if (oldestFirst) "从旧到新" else "从新到旧", {
                    oldestFirst = !oldestFirst
                    list.requestScrollToItem(0)
                }, Modifier.focusProperties { if (episodes.isNotEmpty()) right = listEntry }, icon = "swap-vertical")
            }
            header.description?.takeIf { it.isNotBlank() }?.let { Text(it, Modifier.focusable()) }
        }
        Column(Modifier.weight(2f)) {
            Text("全部课程", style = MaterialTheme.typography.titleMedium)
            LazyColumn(state = list, contentPadding = PaddingValues(Tok.Space.scale[1].d), verticalArrangement = Arrangement.spacedBy(Tok.Space.scale[1].d)) {
                itemsIndexed(if (oldestFirst) episodes else episodes.asReversed(), key = { _, ep -> ep.id }) { index, ep ->
                    val item = EpisodeItem(ep.id, id, ep.title, ep.progress, ep.epDuration, null)
                    TvEpisode(model, item, ep.title, { model.playAndOpen(ep.id, PlayContext.Series(id)) },
                        if (index == list.firstVisibleItemIndex) Modifier.focusRequester(listEntry) else Modifier) {
                        val mark = model.markItem(item)
                        TvIconButton(mark.action, label = mark.title) {
                            mark.icon?.let { ZIcon(it, Tok.Menu.iconSize.d, LocalContentColor.current) }
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun TvRecentRow(model: AppModel, row: RecentRow) {
    val item = row.item()
    val shape = RoundedCornerShape(Tok.Television.coverRadius.d)
    Row(Modifier.fillMaxWidth().padding(horizontal = Tok.Television.margin.d, vertical = Tok.Space.scale[0].d),
        horizontalArrangement = Arrangement.spacedBy(Tok.Space.scale[1].d), verticalAlignment = Alignment.CenterVertically) {
        TvButton({ model.playFromRecent(row, true) }, Modifier.weight(1f), MaterialTheme.shapes.medium,
            scale = androidx.tv.material3.ButtonScale.None) {
            Row(Modifier.fillMaxWidth().padding(Tok.Space.scale[1].d), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Tok.Space.scale[3].d)) {
                CoverImage(model.images, row.coverPath, row.seriesId, shape,
                    Modifier.width((Tok.Space.MinTouchTarget.android * 2).d).aspectRatio(16f / 9f), originVersion = model.net.originVersion)
                Column(Modifier.weight(1f)) {
                    Text(row.seriesTitle, style = MaterialTheme.typography.titleMedium)
                    Text(row.epTitle)
                }
                val progress = model.liveProg(item)
                TvPlaybackIcon(model, item, progress?.completed == true)
                Text(if (row.gone) "已下架" else pillState(progress, row.epDuration ?: 0.0).text)
            }
        }
        TvIconButton({ model.goToSeries(row.seriesId) }, label = "前往课程，${row.seriesTitle}") {
            ZIcon("arrow-forward-circle-outline", Tok.Menu.iconSize.d, LocalContentColor.current)
        }
    }
}

@Composable
private fun TvPlaybackIcon(model: AppModel, item: EpisodeItem, completed: Boolean) {
    val player = model.player
    val current = player?.current?.episodeId == item.episodeId
    if (current && player?.looksPlaying == true && !player.loadingPlayback) AudioWaveformIcon()
    else PlaybackIcon(if (completed) "refresh" else "play", Tok.Menu.iconSize.d, LocalContentColor.current,
        current && player?.loadingPlayback == true)
}

@Composable
private fun TvEpisode(model: AppModel, item: EpisodeItem, title: String, play: () -> Unit, modifier: Modifier, action: @Composable () -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Tok.Space.scale[1].d)) {
        TvButton(play, modifier.weight(1f), MaterialTheme.shapes.medium,
            scale = androidx.tv.material3.ButtonScale.None) {
            Row(Modifier.fillMaxWidth().padding(Tok.Space.scale[2].d), verticalAlignment = Alignment.CenterVertically) {
                val progress = model.liveProg(item)
                TvPlaybackIcon(model, item, progress?.completed == true)
                Text(title, Modifier.weight(1f).padding(horizontal = Tok.Space.scale[1].d))
                Text(pillState(progress, item.epDuration ?: 0.0).text)
            }
        }
        action()
    }
}

@Composable
internal fun TvPlayingView(model: AppModel) {
    val p = model.player
    if (p?.current == null) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(Tok.Space.scale[1].d)) {
                Text("还没有在播放的内容", Modifier.focusable())
                Text("在课程里选一集开始收听", color = C.labelSecondary())
            }
        }
        return
    }
    TvPlayerControls(model, p)
}
