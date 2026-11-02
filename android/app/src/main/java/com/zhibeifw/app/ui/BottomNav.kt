package com.zhibeifw.app.ui

import androidx.compose.material3.Text
import androidx.compose.material3.Surface
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBar
import com.zhibeifw.app.design.generated.Tok.Component as CP
import com.zhibeifw.app.design.generated.Tok.Font.Style as S
import android.provider.Settings
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.zhibeifw.app.AppModel
import com.zhibeifw.app.Tab
import com.zhibeifw.app.design.C
import com.zhibeifw.app.design.SeekIcon
import com.zhibeifw.app.design.ZIcon
import com.zhibeifw.app.design.ZTextStyle
import com.zhibeifw.app.design.generated.Tok
import com.zhibeifw.app.design.hairline
import com.zhibeifw.app.images.CoverImage
import com.zhibeifw.app.player.SEEK_FORWARD_SECONDS
import kotlinx.coroutines.delay

/**
 * 主页 / 分类 / 资料库 / 搜索：系统（Material 3）的 NavigationBar。Android 没有液态玻璃，也没有“正在播放”附件位，
 * 播放胶囊放在导航栏正上方，底用 Material 的 Surface。颜色用我们的令牌。
 */
@Composable
fun BottomNav(model: AppModel) {
    Column(Modifier.fillMaxWidth()) {
        Surface(
            Modifier.padding(horizontal = Tok.Nav.sideMargin.d)
                .padding(bottom = Tok.Nav.bottomMargin.d), shape = CircleShape,
            color = C.background(), shadowElevation = Tok.GlassShadow.androidElevation.d
        ) {
            PlayerCapsule(model, collapsed = false)
        }
        NavigationBar(containerColor = C.background()) {
            for (t in listOf(Tab.HOME, Tab.CATEGORIES, Tab.LIBRARY, Tab.SEARCH)) {
                val on = model.nav.tab == t
                NavigationBarItem(
                    selected = on,
                    onClick = { model.nav.selectTab(t) },
                    icon = { ZIcon(icon(t, on), Tok.Nav.iconGlyph.d, C.labelPrimary()) },
                    label = {
                        Text(
                            when (t) {
                                Tab.HOME -> "主页"; Tab.CATEGORIES -> "分类"; Tab.LIBRARY -> "资料库"; Tab.SEARCH -> "搜索"
                            }
                        )
                    },
                    colors = NavigationBarItemDefaults.colors(
                        selectedTextColor = C.labelPrimary(),
                        unselectedTextColor = C.labelSecondary(),
                        indicatorColor = C.backgroundSecondary(),
                    ),
                )
            }
        }
    }
}

private fun icon(t: Tab, on: Boolean) = when (t) {
    Tab.HOME -> if (on) "home" else "home-outline"
    Tab.CATEGORIES -> if (on) "grid" else "grid-outline"
    Tab.LIBRARY -> if (on) "stack" else "stack-outline"
    Tab.SEARCH -> if (on) "search" else "search-outline"
}

@Composable
fun PlayerCapsule(model: AppModel, collapsed: Boolean) {
    val p = model.player
    val cur = p?.current
    val h = if (collapsed) Tok.Nav.collapsedHeight else Tok.Nav.capsuleHeight
    val thumb = minOf(CP.Capsule.thumb, h - 2 * CP.Capsule.thumbInset)
    val playing = p?.looksPlaying == true
    Row(
        Modifier.fillMaxWidth().height(h.d)
            .padding(start = CP.Capsule.paddingH.d, end = (CP.Capsule.paddingH / 2).d),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(CP.Capsule.textGap.d),
    ) {
        Row(
            Modifier.weight(1f).fillMaxHeight()
                .clickable(enabled = cur != null) { model.openPlayer() }
                .semantics {
                    contentDescription =
                        cur?.let { "正在播放：${it.info.seriesTitle} ${it.info.episodeTitle}，点按打开播放页" }
                            ?: "未在播放"
                },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(CP.Capsule.textGap.d),
        ) {
            if (cur != null) {
                CoverImage(
                    model.images,
                    cur.info.coverPath,
                    cur.seriesId,
                    RoundedCornerShape(CP.Capsule.thumbRadius.d),
                    Modifier.size(thumb.d),
                    model.files.coverFile(cur.seriesId),
                    model.net.originVersion
                )
                Txt(
                    "${cur.info.seriesTitle} ${cur.info.episodeTitle}",
                    S.buttonText,
                    C.labelPrimary(),
                    Modifier.weight(1f),
                    maxLines = 1,
                    maxScale = Tok.Font.MaxScale.capsule
                )
            } else {
                Box(
                    Modifier.size(thumb.d).clip(RoundedCornerShape(CP.Capsule.thumbRadius.d))
                        .background(C.backgroundSecondary()), contentAlignment = Alignment.Center
                ) {
                    ZIcon("musical-notes", CP.Capsule.emptyIcon.d, C.labelSecondary())
                }
                Txt(
                    "未在播放",
                    S.buttonText,
                    C.labelSecondary(),
                    Modifier.weight(1f),
                    maxLines = 1,
                    maxScale = Tok.Font.MaxScale.capsule
                )
            }
        }
        Box(
            Modifier.size(CP.Capsule.iconTouch.d).pressable(enabled = cur != null) { p?.toggle() }
                .semantics { contentDescription = if (playing) "暂停" else "播放" },
            contentAlignment = Alignment.Center
        ) {
            ZIcon(
                if (playing) "pause" else "play",
                CP.Capsule.playIcon.d,
                if (cur == null) C.iconDisabled() else C.labelPrimary()
            )
        }
        if (!collapsed) {
            Box(
                Modifier.size(CP.Capsule.iconTouch.d)
                    .pressable(enabled = cur != null) { p?.seekBy(SEEK_FORWARD_SECONDS) }
                    .semantics { contentDescription = "前进 ${SEEK_FORWARD_SECONDS.toInt()} 秒" },
                contentAlignment = Alignment.Center
            ) {
                SeekIcon(
                    true,
                    CP.Capsule.forwardIcon.d,
                    if (cur == null) C.iconDisabled() else C.labelPrimary()
                )
            }
        }
    }
}
