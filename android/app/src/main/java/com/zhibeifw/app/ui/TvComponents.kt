package com.zhibeifw.app.ui

import androidx.activity.compose.BackHandler
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Dp
import com.zhibeifw.app.AppModel
import com.zhibeifw.app.Routes
import com.zhibeifw.app.data.SeriesCard
import com.zhibeifw.app.design.C
import com.zhibeifw.app.design.generated.Tok
import com.zhibeifw.app.design.generated.Tok.Television as TV
import com.zhibeifw.app.images.CoverImage

@Composable
internal fun TvButton(
    click: () -> Unit, modifier: Modifier = Modifier, shape: Shape = CircleShape,
    color: Color = C.backgroundSecondary(), label: String? = null,
    scale: androidx.tv.material3.ButtonScale = androidx.tv.material3.ButtonDefaults.scale(),
    content: @Composable () -> Unit
) {
    androidx.tv.material3.Button(
        onClick = click,
        modifier = modifier.then(if (label == null) Modifier else Modifier.semantics { contentDescription = label }),
        scale = scale,
        shape = androidx.tv.material3.ButtonDefaults.shape(shape),
        colors = androidx.tv.material3.ButtonDefaults.colors(containerColor = color),
        contentPadding = PaddingValues(0.dp)
    ) {
        CompositionLocalProvider(LocalContentColor provides androidx.tv.material3.LocalContentColor.current) { content() }
    }
}

@Composable
internal fun TvIconButton(click: () -> Unit, modifier: Modifier = Modifier, label: String, content: @Composable () -> Unit) {
    androidx.tv.material3.IconButton(click, modifier.semantics { contentDescription = label }) {
        CompositionLocalProvider(LocalContentColor provides androidx.tv.material3.LocalContentColor.current) { content() }
    }
}

@Composable
internal fun TvPill(text: String, click: () -> Unit, modifier: Modifier = Modifier) {
    TvButton(click, modifier) {
        Text(text, Modifier.padding(horizontal = Tok.Space.scale[3].d, vertical = Tok.Space.scale[1].d),
            maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
internal fun TvCoverCard(model: AppModel, card: SeriesCard, modifier: Modifier = Modifier, removeFavorite: (() -> Unit)? = null) {
    val title = card.featureTitle ?: card.title
    Column(modifier) {
        val shape = RoundedCornerShape(TV.coverRadius.d)
        var menu by remember { mutableStateOf(false) }
        Box {
            androidx.tv.material3.Card(
                onClick = { model.nav.push(Routes.series(card.id)) },
                onLongClick = removeFavorite?.let { { menu = true } },
                modifier = Modifier.fillMaxWidth().aspectRatio(16f / 9f).semantics { contentDescription = title },
                shape = androidx.tv.material3.CardDefaults.shape(shape)
            ) {
                CoverImage(model.images, card.coverPath, card.id, shape, Modifier.fillMaxSize(), originVersion = model.net.originVersion)
            }
            if (removeFavorite != null) DropdownMenu(menu, { menu = false }) {
                DropdownMenuItem(text = { Text("取消收藏") }, onClick = { menu = false; removeFavorite() })
            }
        }
        Text(title, Modifier.padding(top = Tok.Space.scale[1].d), style = MaterialTheme.typography.titleMedium,
            maxLines = 2, overflow = TextOverflow.Ellipsis)
        card.lastTitle?.let { Text("更新至 $it", color = C.labelSecondary(), style = MaterialTheme.typography.bodySmall) }
    }
}

@Composable
private fun TvShelf(model: AppModel, title: String, cards: List<SeriesCard>, width: Dp, category: String? = null) {
    Column {
        if (category == null) Text(title, Modifier.padding(start = TV.margin.d), style = MaterialTheme.typography.titleLarge)
        else TvPill("$title ›", { model.nav.push(Routes.category(category)) }, Modifier.padding(start = TV.margin.d))
        LazyRow(contentPadding = PaddingValues(horizontal = TV.margin.d, vertical = Tok.Space.scale[2].d),
            horizontalArrangement = Arrangement.spacedBy(TV.gap.d)) {
            items(cards, key = { it.id }) { TvCoverCard(model, it, Modifier.width(width)) }
        }
    }
}

@Composable
internal fun TvHome(model: AppModel, focusHomeTab: () -> Unit) {
    val h = model.home
    val list = rememberLazyListState()
    var hasContentFocus by remember { mutableStateOf(false) }
    BackHandler(enabled = hasContentFocus) {
        focusHomeTab()
        list.requestScrollToItem(0)
    }
    LazyColumn(Modifier.onFocusChanged { hasContentFocus = it.hasFocus }, state = list,
        contentPadding = PaddingValues(vertical = TV.gap.d), verticalArrangement = Arrangement.spacedBy(TV.gap.d)) {
        if (model.syncFailed) item { BannerView("无法更新，显示的是上一次更新的内容",
            listOf("重试" to { model.launch { model.syncCatalog(true) }; Unit })) }
        model.upgrade.outdated?.takeUnless { model.upgrade.outdatedDismissed }?.let { update ->
            item { BannerView("此版本过旧，请到官网更新", listOf("关闭" to { model.upgrade.outdatedDismissed = true },
                "更新" to { model.upgrade.openApk(update.apkPath) })) }
        }
        if (h.ongoing.isNotEmpty()) item { TvShelf(model, "新课程", h.ongoing, TV.shelfLarge.d) }
        if (h.featured.isNotEmpty()) item { TvShelf(model, "编辑精选", h.featured, TV.shelfSmall.d) }
        items(h.categories, key = { it.id }) { TvShelf(model, it.name, it.series, TV.shelfSmall.d, it.id) }
    }
}

internal fun LazyListScope.tvCardGrid(model: AppModel, cards: List<SeriesCard>, loadMore: (() -> Unit)? = null, removeFavorite: ((String) -> Unit)? = null) {
    items(cards.chunked(4), key = { it.first().id }) { row ->
        Row(Modifier.fillMaxWidth().padding(horizontal = TV.margin.d, vertical = Tok.Space.scale[2].d),
            horizontalArrangement = Arrangement.spacedBy(TV.gap.d)) {
            row.forEach { card -> TvCoverCard(model, card, Modifier.weight(1f), removeFavorite?.let { remove -> { remove(card.id) } }) }
            repeat(4 - row.size) { Spacer(Modifier.weight(1f)) }
        }
        if (row.last().id == cards.last().id) LaunchedEffect(row.last().id) { loadMore?.invoke() }
    }
}
