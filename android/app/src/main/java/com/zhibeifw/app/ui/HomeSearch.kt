package com.zhibeifw.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.material3.SearchBarDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.rememberTextMeasurer
import com.zhibeifw.app.AppModel
import com.zhibeifw.app.Routes
import com.zhibeifw.app.Tab
import com.zhibeifw.app.core.AppNotice
import com.zhibeifw.app.core.MAX_QUERY_LENGTH
import com.zhibeifw.app.core.normalizeText
import com.zhibeifw.app.core.resolveCategoryColor
import com.zhibeifw.app.core.resolveCategoryIcon
import com.zhibeifw.app.core.seriesStatusText
import com.zhibeifw.app.data.CategoryTile
import com.zhibeifw.app.data.SearchResult
import com.zhibeifw.app.data.SeriesCard
import com.zhibeifw.app.design.C
import com.zhibeifw.app.design.ZIcon
import com.zhibeifw.app.design.generated.Tok
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import com.zhibeifw.app.design.generated.Tok.Component as CP
import com.zhibeifw.app.design.generated.Tok.Font.Style as S
import com.zhibeifw.app.design.ts

/** 主页。 */
@Composable
fun HomeView(model: AppModel) {
    val h = model.home
    val noticeAnchorHeight = with(LocalDensity.current) { 1.toDp() }
    // 后台自动检查更新时，顶部栏正中显示转圈 + “正在更新…”（居中、圈在左字在右）；
    // 放在顶部栏那一行里，出现、消失都不挤动内容
    PageScaffold(
        model,
        "主页",
        showBack = false,
        onRefresh = { model.syncCatalog(true) },
        topCenter = { if (model.autoUpdating) UpdatingHint() },
        trailing = {
            if (model.isTelevision) {
                androidx.compose.material3.TextButton({ model.launch { model.syncCatalog(true) } }) { Text("刷新") }
            } else IconButton(
                onClick = { model.nav.push(Routes.ABOUT) },
                modifier = Modifier.semantics { contentDescription = "关于智悲佛网" }) {
                ZIcon("information-circle-outline", Tok.PageHeader.iconSize.d, C.labelPrimary())
            }
        }) {
        item("pills") {
            // 让尚未加载提示时的首项仍可被列表测量，避免后到的提示出现在当前滚动位置上方。
            Column(Modifier.heightIn(min = noticeAnchorHeight)) {
                if (model.syncFailed) {
                    BannerView(
                        "无法更新，显示的是上一次更新的内容",
                        listOf("重试" to { model.launch { model.syncCatalog(true) }; Unit })
                    )
                    Spacer(Modifier.height(CP.Banner.bottomGap.d))
                }
                val od = model.upgrade.outdated
                if (od != null && !model.upgrade.outdatedDismissed) {
                    BannerView(
                        "此版本过旧，已无法获得最新的内容更新，请更新应用",
                        listOf(
                            "关闭" to { model.upgrade.outdatedDismissed = true },
                            "更新" to { model.upgrade.installUpdate(od.version, od.apkPath) })
                    )
                    Spacer(Modifier.height(CP.Banner.bottomGap.d))
                }
                if (!model.isTelevision) {
                    model.appNotice?.let { notice ->
                        AppNoticeBanner(notice, model::openExternal, model::dismissAppNotice)
                        Spacer(Modifier.height(CP.Banner.bottomGap.d))
                    }
                }
            }
        }
        if (h.ongoing.isNotEmpty()) item("ongoing") {
            Section("新课程", null) {
                CardRow(
                    model,
                    h.ongoing,
                    true,
                    subtitleOf = { c -> c.lastTitle?.let { "更新至 $it" } }) {
                    model.nav.push(
                        Routes.series(
                            it.id
                        )
                    )
                }
            }
        }
        if (h.featured.isNotEmpty()) item("featured") {
            Section("编辑精选", null) {
                CardRow(
                    model,
                    h.featured,
                    false,
                    titleOf = { it.featureTitle ?: it.title }) { model.nav.push(Routes.series(it.id)) }
            }
        }
        items(h.categories, key = { "cat-" + it.id }) { c ->
            Section(c.name, { model.nav.push(Routes.category(c.id)) }) {
                CardRow(
                    model,
                    c.series,
                    false
                ) { model.nav.push(Routes.series(it.id)) }
            }
        }
    }
}

@Composable
private fun AppNoticeBanner(notice: AppNotice, openExternal: (String) -> Unit, dismiss: () -> Unit) {
    val foreground = Tok.Color.appNoticeForeground.c()
    val margin = Layout.pageMargin(windowWidth())
    val gap = CP.AppNotice.actionGap.d
    val closeSize = Tok.Space.MinTouchTarget.android.d
    val measurer = rememberTextMeasurer()
    BoxWithConstraints(
        Modifier.padding(horizontal = margin.d).fillMaxWidth()
            .heightIn(min = CP.Banner.height.d)
            .clip(RoundedCornerShape(CP.Banner.radius.d))
            .background(Tok.Color.appNoticeBackground.c())
            .padding(start = CP.Banner.paddingH.d, top = CP.AppNotice.paddingV.d, bottom = CP.AppNotice.paddingV.d),
        contentAlignment = Alignment.CenterStart
    ) {
        val link = notice.link
        val inline = link != null && with(LocalDensity.current) {
            val message = measurer.measure(notice.message, S.appNoticeText.ts(foreground))
            val label = measurer.measure(link.label, S.captionStrong.ts(foreground))
            val buttonWidth = maxOf(ButtonDefaults.MinWidth, label.size.width.toDp() + gap * 2)
            message.lineCount == 1 && label.lineCount == 1 &&
                message.size.width.toDp() + buttonWidth + closeSize + gap * 2 <= maxWidth
        }
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = if (link == null || inline) Alignment.CenterVertically else Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(gap)
        ) {
            if (link != null && !inline) {
                Column(Modifier.weight(1f)) {
                    Txt(notice.message, S.appNoticeText, foreground)
                    AppNoticeLink(link, foreground, openExternal, inline = false)
                }
            } else {
                Txt(notice.message, S.appNoticeText, foreground, Modifier.weight(1f))
                if (link != null) AppNoticeLink(link, foreground, openExternal, inline = true)
            }
            IconButton(
                onClick = dismiss,
                modifier = Modifier.size(closeSize)
                    .semantics { contentDescription = "关闭公告" }
            ) {
                ZIcon("close", CP.AppNotice.closeIconSize.d, foreground)
            }
        }
    }
}

@Composable
private fun AppNoticeLink(link: AppNotice.Link, color: Color, openExternal: (String) -> Unit, inline: Boolean) {
    TextButton(
        onClick = { openExternal(link.url) },
        modifier = if (inline) Modifier else Modifier.widthIn(min = Tok.Space.MinTouchTarget.android.d),
        contentPadding = if (inline) PaddingValues(horizontal = CP.AppNotice.actionGap.d) else PaddingValues()
    ) {
        Txt(link.label, S.captionStrong, color)
    }
}

/** 主页顶部正中的“正在更新…”：Material 3 转圈在左 + 小字在右。 */
@Composable
private fun UpdatingHint() {
    Row(
        Modifier.semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CircularProgressIndicator(
            Modifier.size(CP.UpdatingHint.indicatorSize.d),
            color = C.labelSecondary(),
            strokeWidth = CP.UpdatingHint.strokeWidth.d
        )
        Spacer(Modifier.size(CP.UpdatingHint.gap.d))
        Txt("正在更新…", S.caption, C.labelSecondary())
    }
}

/** 右上角“i”（关于智悲佛网）：与大标题同一行。 */
@Composable
private fun Section(title: String, onClick: (() -> Unit)?, row: @Composable () -> Unit) {
    Column(
        Modifier.padding(bottom = Tok.Space.sectionGap.d),
        verticalArrangement = Arrangement.spacedBy(Tok.Space.sectionTitleToRow.d)
    ) {
        SectionTitle(title, onClick)
        row()
    }
}

@Composable
private fun BrowseTabList(
    model: AppModel,
    title: String,
    state: LazyListState = rememberLazyListState(),
    content: LazyListScope.() -> Unit
) {
    if (model.isTelevision) {
        LazyColumn(state = state, content = content)
    } else {
        PageScaffold(model, title, showBack = false, state = state, content = content)
    }
}

/** 电视停止输入后搜索，手机和平板由键盘提交。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SearchView(model: AppModel) {
    val W = windowWidth()
    val m = if (model.isTelevision) Tok.Television.margin else Layout.pageMargin(W)
    var text by rememberSaveable { mutableStateOf("") }
    var result by remember { mutableStateOf<SearchResult?>(null) }
    // 按“搜索”时的词：页面重建（深色模式切换、窗口大小变化、进程被回收后回来）后按它把结果重新搜出来，不退回空提示
    var submitted by rememberSaveable { mutableStateOf<String?>(null) }
    var submitCount by remember { mutableIntStateOf(0) }
    val query = if (model.isTelevision) text else submitted.orEmpty()
    LaunchedEffect(query, submitCount, model.catalogVersion) {
        if (normalizeText(query).isEmpty()) {
            result = null
            return@LaunchedEffect
        }
        if (model.isTelevision) kotlinx.coroutines.delay(400)
        result = withContext(Dispatchers.IO) { runCatching { model.store.searchSeries(query) }.getOrNull() }
    }
    var focused by remember { mutableStateOf(false) }
    val focus = LocalFocusManager.current
    val kb = LocalSoftwareKeyboardController.current
    val state = rememberLazyListState()
    LaunchedEffect(state) {
        snapshotFlow { state.isScrollInProgress }.collect {
            if (it && !model.isTelevision) {
                kb?.hide(); focus.clearFocus()
            }
        }
    } // 滚动时键盘收起，输入框也失焦（和 iOS 一致）
    fun run() {
        if (normalizeText(text).isEmpty()) return
        submitted = text
        if (!model.isTelevision) submitCount++
        kb?.hide()
        if (model.isTelevision) focus.moveFocus(FocusDirection.Down) else focus.clearFocus()
    }
    BrowseTabList(model, "搜索", state) {
        item("field") {
            // 系统（Material 3）的搜索输入框。放大镜、清除键沿用项目里的图标（Android 系统没有自带图标库）
            Row(
                Modifier.padding(horizontal = m.d)
                    .padding(top = (if (model.isTelevision) CP.Tile.topGap else CP.SearchField.topGap - CP.PageTitle.bottomGap).d),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(CP.SearchField.cancelGap.d)
            ) {
                SearchBarDefaults.InputField(
                    query = text,
                    onQueryChange = { v ->
                        text =
                            if (v.codePointCount(0, v.length) > MAX_QUERY_LENGTH) v.substring(0, v.offsetByCodePoints(0, MAX_QUERY_LENGTH)) else v
                        if (text.isEmpty()) { result = null; submitted = null }
                    },
                    onSearch = { run() },
                    expanded = false,
                    onExpandedChange = {},
                    modifier = Modifier.weight(1f).onFocusChanged { focused = it.isFocused }
                        .onPreviewKeyEvent { event ->
                            if (!model.isTelevision || event.key != Key.DirectionDown || result?.rows.isNullOrEmpty())
                                return@onPreviewKeyEvent false
                            if (event.type == KeyEventType.KeyDown) {
                                kb?.hide()
                                focus.moveFocus(FocusDirection.Down)
                            }
                            true
                        }
                        .semantics { contentDescription = "搜索课程名或拼音首字母" },
                    placeholder = { Text("课程名或拼音首字母", style = S.body.ts(C.labelSecondary())) },
                    // 底色、文字、光标用我们的颜色令牌，不用 Material 默认的紫色
                    colors = SearchBarDefaults.inputFieldColors(
                        focusedContainerColor = C.backgroundSecondary(),
                        unfocusedContainerColor = C.backgroundSecondary(),
                        focusedTextColor = C.labelPrimary(),
                        unfocusedTextColor = C.labelPrimary(),
                        cursorColor = C.labelPrimary()
                    ),
                    leadingIcon = {
                        ZIcon(
                            "search-outline",
                            CP.SearchField.iconSize.d,
                            C.labelSecondary()
                        )
                    },
                    trailingIcon = if (text.isEmpty()) null else ({
                        Box(
                            Modifier.size(Tok.Space.MinTouchTarget.android.d)
                                .pressable { text = ""; result = null; submitted = null }
                                .semantics { contentDescription = "清除" },
                            contentAlignment = Alignment.Center
                        ) {
                            ZIcon(
                                "close-circle-outline",
                                CP.SearchField.iconSize.d,
                                C.labelSecondary()
                            )
                        }
                    }),
                )
                if (focused || text.isNotEmpty()) TextButton(onClick = {
                    text = ""; result = null; submitted = null; focus.clearFocus()
                }) { Text("取消", style = S.body.ts(C.labelPrimary())) }
            }
            Spacer(Modifier.height(CP.Tile.topGap.d))
        }
        val r = result
        if (r != null) {
            if (r.rows.isEmpty()) item("none") {
                EmptyStateView(
                    "未找到相关内容",
                    Modifier.padding(top = (Tok.Space.scale[6] * 3).d)
                )
            }
            else {
                if (r.fallback) item("hint") {
                    Txt(
                        "已显示“${r.matched}”的结果",
                        S.caption,
                        C.labelSecondary(),
                        Modifier.padding(horizontal = m.d)
                    )
                }
                if (model.isTelevision) tvCardGrid(model, r.rows) else items(r.rows, key = { "r-" + it.id }) { c ->
                    ListRowView(model, c) {
                        model.nav.push(
                            Routes.series(c.id)
                        )
                    }
                }
            }
        } else {
            // 没搜之前：空状态提示
            item("start") {
                EmptyStateView(
                    "输入课程名搜索",
                    Modifier.padding(top = (Tok.Space.scale[6] * 3).d)
                )
            }
        }
    }
}

/** 分类页（一级页）：分类磁贴，点进分类完整课程列表。 */
@Composable
fun CategoriesView(model: AppModel) {
    val W = windowWidth()
    val m = if (model.isTelevision) Tok.Television.margin else Layout.pageMargin(W)
    var tiles by remember { mutableStateOf<List<CategoryTile>>(emptyList()) }
    val largeText = Layout.isLargeText(fontScale())
    LaunchedEffect(model.catalogVersion) {
        tiles = withContext(Dispatchers.IO) {
            runCatching { model.store.loadCategories() }.getOrDefault(emptyList())
        }
    }
    BrowseTabList(model, "分类") {
        item("gap") { Spacer(Modifier.height(CP.Tile.topGap.d)) }
        val cols = if (model.isTelevision) 4 else if (largeText) 1 else Layout.tileColumns(W)
        items(tiles.chunked(cols), key = { "t-" + it.first().id }) { row ->
            Row(
                Modifier.padding(horizontal = m.d).padding(bottom = CP.Tile.gap.d),
                horizontalArrangement = Arrangement.spacedBy(CP.Tile.gap.d)
            ) {
                row.forEach { t -> Box(Modifier.weight(1f)) { Tile(model, t, largeText) } }
                repeat(cols - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
    }
}

@Composable
private fun Tile(model: AppModel, t: CategoryTile, large: Boolean) {
    if (model.isTelevision) {
        TvButton({ model.nav.push(Routes.category(t.id)) }, Modifier.fillMaxWidth(),
            RoundedCornerShape(Tok.Radius.tile.d), resolveCategoryColor(t.color, t.id).c(), t.name) {
            Row(Modifier.fillMaxWidth().padding(Tok.Space.scale[3].d),
                horizontalArrangement = Arrangement.spacedBy(Tok.Space.scale[1].d)) {
                ZIcon(resolveCategoryIcon(t.icon, t.id), Tok.Menu.iconSize.d, androidx.compose.material3.LocalContentColor.current)
                Text(t.name)
            }
        }
        return
    }
    Box(
        Modifier.fillMaxWidth().heightIn(min = CP.Tile.height.d)
            .clip(RoundedCornerShape(Tok.Radius.tile.d))
            .background(resolveCategoryColor(t.color, t.id).c())
            .pressable { model.nav.push(Routes.category(t.id)) }
            .semantics { contentDescription = "${t.name}，点按查看全部课程" }
            .padding(CP.Tile.padding.d),
    ) {
        Box(Modifier.align(Alignment.TopEnd)) {
            ZIcon(
                resolveCategoryIcon(t.icon, t.id),
                CP.Tile.iconSize.d,
                C.onColor().copy(alpha = CP.Tile.iconOpacity)
            )
        }
        Txt(
            t.name,
            S.tileText,
            C.onColor(),
            Modifier.align(Alignment.BottomStart),
            maxLines = if (large) Int.MAX_VALUE else 1
        )
    }
}

/** 分类完整课程列表：无限下拉加载。 */
@Composable
fun CategoryView(model: AppModel, categoryId: String) {
    val pageSize = 40
    var rows by remember(categoryId, model.catalogVersion) { mutableStateOf<List<SeriesCard>>(emptyList()) }
    var done by remember(categoryId, model.catalogVersion) { mutableStateOf(false) }
    var loaded by remember(categoryId, model.catalogVersion) { mutableStateOf(false) }
    var title by remember(categoryId) { mutableStateOf(categoryId) }
    suspend fun loadPage(offset: Int) = withContext(Dispatchers.IO) {
        runCatching { model.store.loadCategorySeries(categoryId, pageSize, offset) }.getOrDefault(emptyList())
    }
    LaunchedEffect(categoryId, model.catalogVersion) {
        title = withContext(Dispatchers.IO) { runCatching { model.store.categoryName(categoryId) }.getOrNull() } ?: categoryId
        rows = loadPage(0)
        done = rows.size < pageSize
        loaded = true
    }
    suspend fun more() {
        if (done) return
        val offset = rows.size
        val next = loadPage(offset)
        val seen = rows.map { it.id }.toHashSet()
        rows = rows + next.filter { seen.add(it.id) }
        if (next.size < pageSize) done = true
    }
    PageScaffold(model, title) {
        if (loaded && rows.isEmpty()) item("empty") {
            EmptyStateView(
                "暂无课程",
                Modifier.padding(top = (Tok.Space.scale[6] * 3).d)
            )
        }
        if (model.isTelevision) tvCardGrid(model, rows, ::more) else items(rows, key = { it.id }) { c ->
            Column(Modifier.padding(bottom = CP.SeriesRow.gap.d)) {
                SeriesRowView(
                    model,
                    c.id,
                    c.title,
                    listOf(seriesStatusText(c.status)),
                    c.coverPath
                ) { model.nav.push(Routes.series(c.id)) }
            }
            if (c.id == rows.lastOrNull()?.id) LaunchedEffect(c.id) { more() }
        }
    }
}
