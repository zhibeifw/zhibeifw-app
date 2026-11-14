package com.zhibeifw.app.design

import androidx.compose.ui.draw.drawWithCache
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.BasicText
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.CommandButton
import com.zhibeifw.app.R
import com.zhibeifw.app.design.generated.IconData
import com.zhibeifw.app.design.generated.Tok
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** 一个颜色令牌：浅色、深色两个值（ARGB），跟随系统深浅模式。 */
data class ZColor(val light: Long, val dark: Long) {
    companion object {
        fun both(v: Long) = ZColor(v, v)
    }

    @Composable
    @ReadOnlyComposable
    fun c(): Color = Color(if (LocalDark.current) dark else light)
}

/** 字号令牌：字号、字重、行高。随系统字体大小缩放（sp）。 */
data class ZTextStyle(val size: Float, val weight: Int, val lineHeight: Float)

val LocalDark = staticCompositionLocalOf { false }

/** 字体：用手机系统自己的字体（不再打包思源黑体；各品牌手机字体可能不同）。 */
val AppFont: FontFamily = FontFamily.Default

fun fontWeight(w: Int): FontWeight = when {
    w < 450 -> FontWeight.Normal
    w < 550 -> FontWeight.Medium
    w < 650 -> FontWeight.SemiBold
    else -> FontWeight.Bold
}

/** 把字号令牌变成 Compose 的 TextStyle。maxScale：给固定尺寸的外壳（悬浮导航）封顶。 */
@Composable
fun ZTextStyle.ts(color: Color, maxScale: Float? = null): TextStyle {
    val fs = LocalDensity.current.fontScale
    val k = if (maxScale != null && fs > maxScale) maxScale / fs else 1f
    return TextStyle(
        color = color,
        fontFamily = AppFont,
        fontWeight = fontWeight(weight),
        fontSize = (size * k).sp,
        lineHeight = (lineHeight * k).sp,
        lineHeightStyle = LineHeightStyle(
            LineHeightStyle.Alignment.Center,
            LineHeightStyle.Trim.None
        ),
    )
}

/** 简写：界面代码里用 C.labelPrimary()。 */
object C {
    @Composable
    @ReadOnlyComposable
    fun background() = Tok.Color.background.c()
    @Composable
    @ReadOnlyComposable
    fun backgroundSecondary() = Tok.Color.backgroundSecondary.c()
    @Composable
    @ReadOnlyComposable
    fun labelPrimary() = Tok.Color.labelPrimary.c()
    @Composable
    @ReadOnlyComposable
    fun labelSecondary() = Tok.Color.labelSecondary.c()
    @Composable
    @ReadOnlyComposable
    fun labelTertiary() = Tok.Color.labelTertiary.c()
    @Composable
    @ReadOnlyComposable
    fun separator() = Tok.Color.separator.c()
    @Composable
    @ReadOnlyComposable
    fun danger() = Tok.Color.danger.c()
    @Composable
    @ReadOnlyComposable
    fun onColor() = Tok.Color.onColor.c()
    @Composable
    @ReadOnlyComposable
    fun iconDisabled() = Tok.Color.iconDisabled.c()
}

@Composable
fun ZTheme(dark: Boolean, content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalDark provides dark) {
        // Material 主题：系统组件用 Material 的，颜色和字号用我们的设计令牌，顶部栏、按钮、菜单、滑块、导航栏和页面内容一致
        MaterialTheme(
            colorScheme = materialColors(dark),
            typography = materialType(),
            content = content
        )
    }
}

private fun materialColors(dark: Boolean): ColorScheme {
    fun c(z: ZColor) = Color(if (dark) z.dark else z.light)
    val t = Tok.Color
    val base =
        if (dark) androidx.compose.material3.darkColorScheme() else androidx.compose.material3.lightColorScheme()
    return base.copy(
        primary = c(t.labelPrimary),
        onPrimary = c(t.background),
        primaryContainer = c(t.backgroundSecondary),
        onPrimaryContainer = c(t.labelPrimary),
        secondary = c(t.labelSecondary),
        onSecondary = c(t.background),
        secondaryContainer = c(t.backgroundSecondary),
        onSecondaryContainer = c(t.labelPrimary),
        tertiary = c(t.labelSecondary),
        onTertiary = c(t.background),
        background = c(t.background),
        onBackground = c(t.labelPrimary),
        surface = c(t.background),
        onSurface = c(t.labelPrimary),
        surfaceVariant = c(t.backgroundSecondary),
        onSurfaceVariant = c(t.labelSecondary),
        surfaceTint = Color.Transparent,
        surfaceContainerLowest = c(t.background),
        surfaceContainerLow = c(t.background),
        surfaceContainer = c(t.background),
        surfaceContainerHigh = c(t.backgroundSecondary),
        surfaceContainerHighest = c(t.backgroundSecondary),
        inverseSurface = c(t.labelPrimary),
        inverseOnSurface = c(t.background),
        outline = c(t.separator),
        outlineVariant = c(t.separator),
        error = c(t.danger),
        onError = Color.White,
    )
}

private fun ZTextStyle.plain() = TextStyle(
    fontFamily = AppFont,
    fontWeight = fontWeight(weight),
    fontSize = size.sp,
    lineHeight = lineHeight.sp
)

private fun materialType(): Typography {
    val st = Tok.Font.Style
    return Typography(
        headlineMedium = st.pageTitle.plain(),   // LargeTopAppBar 展开时的大标题
        titleLarge = st.navTitle.plain(),        // 顶部栏（收起后）的小标题
        titleMedium = st.listRowTitle.plain(),
        bodyLarge = st.body.plain(),             // 搜索框、菜单项
        bodyMedium = st.description.plain(),
        bodySmall = st.caption.plain(),
        labelLarge = st.buttonText.plain(),      // 按钮
        labelMedium = TextStyle(
            fontFamily = AppFont,
            fontWeight = fontWeight(Tok.Font.Style.NavLabel.weightNormal.toInt()),
            fontSize = Tok.Font.Style.NavLabel.size.sp,
            lineHeight = Tok.Font.Style.NavLabel.lineHeight.sp
        ), // 底部导航栏文字
    )
}

/** 1pt/1dp 取整到整数物理像素，两端一样粗。 */
@Composable
fun hairline(): Dp {
    val d = LocalDensity.current.density
    return (max(1f, (1f * d).roundToInt().toFloat()) / d).dp
}

@Composable
fun Separator(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().height(hairline()).background(C.separator()))
}

// ---------------- 图标 ----------------

/** 图标的一笔（由 tools/gen_design.py 从 doc/icons.json 生成）。ops：0 移到；1 直线；2 三次曲线；3 闭合。 */
class IconElement(val fill: Boolean, val evenOdd: Boolean, val width: Float, val ops: FloatArray) {
    fun path(k: Float): Path {
        val p = Path()
        var i = 0
        val o = ops
        while (i < o.size) {
            when (o[i].toInt()) {
                0 -> {
                    p.moveTo(o[i + 1] * k, o[i + 2] * k); i += 3
                }

                1 -> {
                    p.lineTo(o[i + 1] * k, o[i + 2] * k); i += 3
                }

                2 -> {
                    p.cubicTo(
                        o[i + 1] * k,
                        o[i + 2] * k,
                        o[i + 3] * k,
                        o[i + 4] * k,
                        o[i + 5] * k,
                        o[i + 6] * k
                    ); i += 7
                }

                else -> {
                    p.close(); i += 1
                }
            }
        }
        if (evenOdd) p.fillType = PathFillType.EvenOdd
        return p
    }
}

/** 两端一样的矢量图标（与 iOS 的 ZIcon 同一份数据）。没有的名字什么都不画。 */
@Composable
fun ZIcon(name: String, size: Dp, color: Color, modifier: Modifier = Modifier) {
    val els = IconData.get(name)
    // 路径只在尺寸变了时重建：列表里图标多，动画期间每帧新建会给垃圾回收添负担
    Spacer(modifier.size(size).clearAndSetSemantics { }.drawWithCache {
        val k = min(this.size.width, this.size.height) / 24f
        val paths = els.orEmpty().map { it to it.path(k) }
        onDrawBehind {
            for ((e, path) in paths) {
                if (e.fill) drawPath(path, color, style = Fill)
                else drawPath(
                    path,
                    color,
                    style = Stroke(width = e.width * k, cap = StrokeCap.Round, join = StrokeJoin.Round)
                )
            }
        }
    })
}

/** 后退 15 / 前进 30 秒：用系统媒体库 Media3 自带的图标（和锁屏、通知栏同一套）。 */
@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
@Composable
fun SeekIcon(forward: Boolean, size: Dp, color: Color) {
    val icon = if (forward) CommandButton.ICON_SKIP_FORWARD_30 else CommandButton.ICON_SKIP_BACK_15
    Image(
        androidx.compose.ui.res.painterResource(CommandButton.getIconResIdForIconConstant(icon)),
        contentDescription = null,
        modifier = Modifier.size(size).clearAndSetSemantics { },
        colorFilter = ColorFilter.tint(color),
    )
}
