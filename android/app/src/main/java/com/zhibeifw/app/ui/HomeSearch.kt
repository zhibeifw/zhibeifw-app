package com.zhibeifw.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
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
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import com.zhibeifw.app.AppModel
import com.zhibeifw.app.Routes
import com.zhibeifw.app.Tab
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
    // 后台自动检查更新时，顶部栏正中显示转圈 + “正在更新…”（居中、圈在左字在右）；
    // 放在顶部栏那一行里，出现、消失都不挤动内容
    PageScaffold(
        model,
        "主页",
        showBack = false,
        onRefresh = { model.syncCatalog(true) },
        topCenter = { if (model.autoUpdating) UpdatingHint() },
        trailing = {
            IconButton(
                onClick = { model.nav.push(Routes.ABOUT) },
                modifier = Modifier.semantics { contentDescription = "关于智悲佛网" }) {
                ZIcon("information-circle-outline", Tok.PageHeader.iconSize.d, C.labelPrimary())
            }
        }) {
        item("pills") {
            Column {
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
                        "此版本过旧，已无法获得最新的内容更新，请到官网更新",
                        listOf(
                            "关闭" to { model.upgrade.outdatedDismissed = true },
                            "更新" to { model.upgrade.openApk(od.apkPath) })
                    )
                    Spacer(Modifier.height(CP.Banner.bottomGap.d))
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

/** 搜索页：按键盘上的“搜索”才开始搜；没搜之前显示“输入课程名搜索”（分类磁贴在“分类”标签）。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SearchView(model: AppModel) {
    val W = windowWidth()
    val m = Layout.pageMargin(W)
    var text by rememberSaveable { mutableStateOf("") }
    var result by remember { mutableStateOf<SearchResult?>(null) }
    // 按“搜索”时的词：页面重建（深色模式切换、窗口大小变化、进程被回收后回来）后按它把结果重新搜出来，不退回空提示
    var submitted by rememberSaveable { mutableStateOf<String?>(null) }
    // 每次搜索加一：查询在后台做，只用最后一次的结果
    var searchSeq by remember { mutableIntStateOf(0) }
    // 搜不到整句时会从开头逐字加长多查几次，放到后台，不卡输入
    fun search(q: String) {
        val seq = ++searchSeq
        model.launch {
            val r = withContext(Dispatchers.IO) { runCatching { model.store.searchSeries(q) }.getOrNull() }
            if (seq == searchSeq) result = r
        }
    }
    LaunchedEffect(Unit) {
        submitted?.let { q -> if (result == null) search(q) }
    }
    var focused by remember { mutableStateOf(false) }
    val focus = LocalFocusManager.current
    val kb = LocalSoftwareKeyboardController.current
    val state = rememberLazyListState()
    LaunchedEffect(state) {
        snapshotFlow { state.isScrollInProgress }.collect {
            if (it) {
                kb?.hide(); focus.clearFocus()
            }
        }
    } // 滚动时键盘收起，输入框也失焦（和 iOS 一致）
    fun run() {
        if (normalizeText(text).isEmpty()) return
        search(text)
        submitted = text
        kb?.hide()
        focus.clearFocus() // 搜完输入框失焦（和 iOS 一致）
    }
    PageScaffold(model, "搜索", showBack = false, state = state) {
        item("field") {
            // 系统（Material 3）的搜索输入框。放大镜、清除键沿用项目里的图标（Android 系统没有自带图标库）
            Row(
                Modifier.padding(horizontal = m.d)
                    .padding(top = (CP.SearchField.topGap - CP.PageTitle.bottomGap).d),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(CP.SearchField.cancelGap.d)
            ) {
                SearchBarDefaults.InputField(
                    query = text,
                    onQueryChange = { v ->
                        text =
                            if (v.length > MAX_QUERY_LENGTH) v.take(MAX_QUERY_LENGTH) else v; if (text.isEmpty()) {
                        searchSeq++; result = null; submitted = null
                    }
                    },
                    onSearch = { run() },
                    expanded = false,
                    onExpandedChange = {},
                    modifier = Modifier.weight(1f).onFocusChanged { focused = it.isFocused }
                        .semantics { contentDescription = "搜索课程名" },
                    placeholder = { Text("课程名", style = S.body.ts(C.labelSecondary())) },
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
                                .pressable { text = ""; searchSeq++; result = null; submitted = null }
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
                    text = ""; searchSeq++; result = null; submitted = null; focus.clearFocus()
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
                items(r.rows, key = { "r-" + it.id }) { c ->
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
    val m = Layout.pageMargin(W)
    var tiles by remember { mutableStateOf<List<CategoryTile>>(emptyList()) }
    val largeText = Layout.isLargeText(fontScale())
    LaunchedEffect(model.catalogVersion) {
        tiles = runCatching { model.store.loadCategories() }.getOrDefault(emptyList())
    }
    PageScaffold(model, "分类", showBack = false) {
        item("gap") { Spacer(Modifier.height(CP.Tile.topGap.d)) }
        val cols = if (largeText) 1 else Layout.tileColumns(W)
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
    var rows by remember { mutableStateOf<List<SeriesCard>>(emptyList()) }
    var done by remember { mutableStateOf(false) }
    var loaded by remember { mutableStateOf(false) }
    // 分类名在目录变了时查一次，不在每次重画时查库
    val title = remember(model.catalogVersion) {
        runCatching { model.store.categoryName(categoryId) }.getOrNull() ?: categoryId
    }
    LaunchedEffect(model.catalogVersion) {
        rows = runCatching { model.store.loadCategorySeries(categoryId, pageSize, 0) }.getOrDefault(emptyList())
        done = rows.size < pageSize
        loaded = true
    }
    fun more() {
        if (done) return
        val next = runCatching { model.store.loadCategorySeries(categoryId, pageSize, rows.size) }.getOrDefault(emptyList())
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
        items(rows, key = { it.id }) { c ->
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
