package com.zhibeifw.app.widget

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.state.updateAppWidgetState
import androidx.glance.currentState
import androidx.glance.state.GlanceStateDefinition
import androidx.glance.state.PreferencesGlanceStateDefinition
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.LinearProgressIndicator
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxHeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.semantics.contentDescription
import androidx.glance.semantics.semantics
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.zhibeifw.app.MainActivity
import com.zhibeifw.app.R
import com.zhibeifw.app.ZhibeiApp
import kotlin.math.ceil

// 智悲佛网的桌面小组件：继续播放、最新课程、编辑精选、收藏的课程（和 iOS 的四个一样）。
// 数据都是 App 写好的（WidgetStore），这里只读、只画；App 里内容变了会刷新，这里不自己定时刷新。
// 外观跟系统走（Material You 的小组件底色和文字颜色），按尺寸分中、大两档排（不做小号：只放得下一门，用户定）。

private enum class Family { MEDIUM, LARGE }

private val MEDIUM = DpSize(250.dp, 120.dp)
private val LARGE = DpSize(250.dp, 260.dp)

@Composable
private fun family(): Family = if (LocalSize.current.height >= 240.dp) Family.LARGE else Family.MEDIUM

/** App 每写一次数据加一：小组件开着时（Glance 的会话没结束）不会重新执行 provideGlance，靠它知道要重读 */
private val VersionKey = longPreferencesKey("dataVersion")

/** 所有小组件共用：读数据和封面图，按尺寸画 */
abstract class SnapshotWidget(sizes: Set<DpSize> = setOf(MEDIUM, LARGE)) : GlanceAppWidget() {
    override val sizeMode = SizeMode.Responsive(sizes)
    override val stateDefinition: GlanceStateDefinition<*> = PreferencesGlanceStateDefinition

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            val v = currentState<Preferences>()[VersionKey] ?: 0L
            // 文件很小、封面只有几张小图：版本变了才重读
            val (snap, covers) = remember(v) { load(context) }
            GlanceTheme {
                Box(
                    GlanceModifier.fillMaxSize().background(GlanceTheme.colors.widgetBackground).padding(14.dp)
                ) { Content(snap, covers) }
            }
        }
    }

    private fun load(context: Context): Pair<WidgetSnapshot, Map<String, Bitmap>> {
        val snap = WidgetStore.read(context)
        val covers = covers(snap).mapNotNull { it.cover }.distinct()
            .mapNotNull { n -> WidgetStore.cover(context, n)?.let { n to it } }.toMap()
        return snap to covers
    }

    /** App 写完数据后：每个放在桌面上的这种小组件都加一次版本再刷新 */
    suspend fun refreshAll(context: Context) {
        for (id in GlanceAppWidgetManager(context).getGlanceIds(javaClass)) {
            updateAppWidgetState(context, id) { it[VersionKey] = (it[VersionKey] ?: 0L) + 1 }
            update(context, id)
        }
    }

    /** 这个小组件用到哪些课（只读这些封面） */
    abstract fun covers(s: WidgetSnapshot): List<WidgetItem>

    @Composable
    abstract fun Content(s: WidgetSnapshot, covers: Map<String, Bitmap>)
}

// ---------- 动作 ----------

private val EpisodeKey = ActionParameters.Key<String>("episodeId")

/** 播放某一集（最新课程的每一行）：在 App 里播，不打开 App */
class PlayEpisodeAction : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val id = parameters[EpisodeKey] ?: return
        (context.applicationContext as ZhibeiApp).model.playFromWidget(id, toggle = false)
    }
}

/** 继续播放的播放 / 暂停：这一集正在播就暂停，否则接着播这一集 */
class TogglePlaybackAction : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val id = parameters[EpisodeKey] ?: return
        (context.applicationContext as ZhibeiApp).model.playFromWidget(id, toggle = true)
    }
}

@Composable
private fun open(link: WidgetLink) = actionStartActivity(
    Intent(LocalContext.current, MainActivity::class.java).setAction(Intent.ACTION_VIEW).setData(link.uri)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
)

// ---------- 继续播放 ----------

class NowPlayingWidget : SnapshotWidget() {
    override fun covers(s: WidgetSnapshot) = listOfNotNull(s.nowPlaying?.item)

    @Composable
    override fun Content(s: WidgetSnapshot, covers: Map<String, Bitmap>) {
        val np = s.nowPlaying ?: return EmptyWidget("还没有在听的课程")
        val i = np.item
        val link = if (np.loaded) WidgetLink.Player(i.seriesId) else WidgetLink.Series(i.seriesId)
        val f = family()
        Column(GlanceModifier.fillMaxSize().clickable(open(link))) {
            when (f) {
                Family.MEDIUM -> Row(GlanceModifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
                    // 封面在左边上下居中
                    Cover(i, covers, GlanceModifier.width(140.dp).height(79.dp), 10)
                    Spacer(GlanceModifier.width(12.dp))
                    Column(GlanceModifier.defaultWeight().fillMaxHeight()) {
                        Caption(i.seriesTitle)
                        Title(i.episodeTitle ?: "", 16, 2)
                        Spacer(GlanceModifier.defaultWeight())
                        Progress(np, GlanceModifier.fillMaxWidth())
                        Spacer(GlanceModifier.height(4.dp))
                        Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Caption(remaining(np), GlanceModifier.defaultWeight())
                            PlayButton(np, 38)
                        }
                    }
                }

                Family.LARGE -> {
                    Cover(i, covers, GlanceModifier.fillMaxWidth().defaultWeight(), 12)
                    Spacer(GlanceModifier.height(10.dp))
                    Caption(i.seriesTitle)
                    Title(i.episodeTitle ?: "", 20, 2)
                    Spacer(GlanceModifier.height(10.dp))
                    Progress(np, GlanceModifier.fillMaxWidth())
                    Spacer(GlanceModifier.height(6.dp))
                    Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Caption(remaining(np), GlanceModifier.defaultWeight())
                        PlayButton(np, 48)
                    }
                }
            }
        }
    }

    private fun remaining(np: WidgetNowPlaying): String {
        if (np.duration <= 0) return ""
        val m = ceil((np.duration - np.position) / 60).toInt()
        return if (m <= 0) "即将听完" else "剩余 $m 分钟"
    }
}

class NowPlayingReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = NowPlayingWidget()
}

@Composable
private fun PlayButton(np: WidgetNowPlaying, size: Int) {
    val label = if (np.playing) "暂停" else "播放"
    Image(
        ImageProvider(if (np.playing) R.drawable.ic_widget_pause else R.drawable.ic_widget_play),
        contentDescription = label,
        colorFilter = ColorFilter.tint(GlanceTheme.colors.onSurface),
        modifier = GlanceModifier.size(size.dp).clickable(
            actionRunCallback<TogglePlaybackAction>(actionParametersOf(EpisodeKey to (np.item.episodeId ?: "")))
        ),
    )
}

@Composable
private fun Progress(np: WidgetNowPlaying, modifier: GlanceModifier) {
    val v = if (np.duration > 0) (np.position / np.duration).coerceIn(0.0, 1.0).toFloat() else 0f
    LinearProgressIndicator(
        progress = v, modifier = modifier.height(4.dp),
        color = GlanceTheme.colors.onSurface, backgroundColor = GlanceTheme.colors.surfaceVariant,
    )
}

// ---------- 最新课程 ----------

class LatestWidget : SnapshotWidget() {
    override fun covers(s: WidgetSnapshot) = s.latest

    @Composable
    override fun Content(s: WidgetSnapshot, covers: Map<String, Bitmap>) {
        if (s.latest.isEmpty()) return EmptyWidget("暂时没有新课程")
        val large = family() == Family.LARGE
        val gap = if (large) 8.dp else 6.dp
        // 放得下几行就放几行：各家桌面小组件高度不同，不能写死 3 行、7 行（上下边距 28、标题约 26）
        val room = LocalSize.current.height - 28.dp - 26.dp
        val n = maxOf(1, ((room + gap) / (ROW_HEIGHT + gap)).toInt())
        Column(GlanceModifier.fillMaxSize()) {
            Header("新课程")
            for ((k, i) in s.latest.take(n).withIndex()) {
                if (k > 0) Spacer(GlanceModifier.height(gap))
                // 正在播的是这一集：显示暂停，点了暂停 / 接着播（和“继续播放”的按钮一样）
                val np = s.nowPlaying
                val current = np != null && np.loaded && np.item.episodeId == i.episodeId
                val playing = current && np!!.playing
                val action = if (current) actionRunCallback<TogglePlaybackAction>(actionParametersOf(EpisodeKey to (i.episodeId ?: "")))
                else play(i)
                Row(
                    GlanceModifier.fillMaxWidth().clickable(action)
                        .semantics { contentDescription = "${if (playing) "暂停" else "播放"} ${i.seriesTitle} ${i.episodeTitle ?: ""}" },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Cover(i, covers, GlanceModifier.width(64.dp).height(36.dp), 5)
                    Spacer(GlanceModifier.width(10.dp))
                    Column(GlanceModifier.defaultWeight().height(ROW_HEIGHT), verticalAlignment = Alignment.CenterVertically) {
                        Title(i.seriesTitle, 14, 1)
                        Caption("更新至 ${i.episodeTitle ?: ""}")
                    }
                    PlayIcon(28, playing)
                }
            }
        }
    }

    /** 一行的高度：64dp 宽的 16:9 封面 36dp，右边两行字差不多一样高 */
    private val ROW_HEIGHT = 40.dp

    private fun play(i: WidgetItem) = actionRunCallback<PlayEpisodeAction>(actionParametersOf(EpisodeKey to (i.episodeId ?: "")))
}

class LatestReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = LatestWidget()
}

@Composable
private fun PlayIcon(size: Int, playing: Boolean = false) = Image(
    ImageProvider(if (playing) R.drawable.ic_widget_pause else R.drawable.ic_widget_play), contentDescription = null,
    colorFilter = ColorFilter.tint(GlanceTheme.colors.onSurface), modifier = GlanceModifier.size(size.dp),
)

// ---------- 编辑精选、收藏的课程 ----------

class FeaturedWidget : SnapshotWidget() {
    override fun covers(s: WidgetSnapshot) = s.featured

    @Composable
    override fun Content(s: WidgetSnapshot, covers: Map<String, Bitmap>) =
        CoverGrid("编辑精选", s.featured, "暂时没有编辑精选", covers)
}

class FeaturedReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = FeaturedWidget()
}

class FavoritesWidget : SnapshotWidget() {
    override fun covers(s: WidgetSnapshot) = s.favorites

    @Composable
    override fun Content(s: WidgetSnapshot, covers: Map<String, Bitmap>) =
        CoverGrid("收藏的课程", s.favorites, "还没有收藏的课程", covers)
}

class FavoritesReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = FavoritesWidget()
}

/**
 * 课程封面：点封面打开 App 进这门课的课程页。一行 3 个；放得下几行就放几行（各家桌面小组件宽高不同，
 * 按实际尺寸算：封面 16:9 + 两行标题），中号最多 1 行、大号最多 3 行
 */
@Composable
private fun CoverGrid(title: String, items: List<WidgetItem>, empty: String, covers: Map<String, Bitmap>) {
    if (items.isEmpty()) return EmptyWidget(empty)
    val f = family()
    val cols = 3
    val size = LocalSize.current
    // 上下左右边距各 14、标题约 26、格子间距 10、两行标题约 32
    val tileW = (size.width - 28.dp - 20.dp) / cols
    val coverH = tileW * 9 / 16
    val fit = maxOf(1, ((size.height - 28.dp - 26.dp + 10.dp) / (coverH + 4.dp + 32.dp + 10.dp)).toInt())
    val rows = minOf(if (f == Family.LARGE) 3 else 1, fit, (items.size + cols - 1) / cols)
    Column(GlanceModifier.fillMaxSize()) {
        Header(title)
        // 从上往下排，不满时空在下面
        Column(GlanceModifier.fillMaxWidth().defaultWeight(), verticalAlignment = Alignment.Top) {
            for (r in 0 until rows) {
                if (r > 0) Spacer(GlanceModifier.height(10.dp))
                Row(GlanceModifier.fillMaxWidth()) {
                    for (c in 0 until cols) {
                        if (c > 0) Spacer(GlanceModifier.width(10.dp))
                        val i = items.getOrNull(r * cols + c)
                        Column(
                            GlanceModifier.defaultWeight().let { m ->
                                if (i != null) m.clickable(open(WidgetLink.Series(i.seriesId))) else m
                            }
                        ) {
                            if (i != null) {
                                Cover(i, covers, GlanceModifier.fillMaxWidth().height(coverH), 6)
                                Spacer(GlanceModifier.height(4.dp))
                                Title(i.seriesTitle, 12, 2)
                            }
                        }
                    }
                }
            }
        }
    }
}

// ---------- 公用 ----------

/** 封面；没有图时是这门课的占位色。圆角要 Android 12 起才有 */
@Composable
private fun Cover(i: WidgetItem, covers: Map<String, Bitmap>, modifier: GlanceModifier, radius: Int) {
    val bmp = i.cover?.let { covers[it] }
    val m = modifier.cornerRadius(radius.dp)
    if (bmp != null) {
        Image(ImageProvider(bmp), contentDescription = null, contentScale = ContentScale.Crop, modifier = m)
    } else {
        Box(m.background(ColorProvider(Color(i.color.toInt())))) {}
    }
}

@Composable
private fun Header(title: String) {
    Text(
        title, style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium, color = GlanceTheme.colors.onSurfaceVariant),
        modifier = GlanceModifier.padding(bottom = 8.dp),
    )
}

@Composable
private fun Title(text: String, size: Int, lines: Int) {
    Text(
        text, maxLines = lines,
        style = TextStyle(fontSize = size.sp, fontWeight = FontWeight.Bold, color = GlanceTheme.colors.onSurface),
    )
}

@Composable
private fun Caption(text: String, modifier: GlanceModifier = GlanceModifier) {
    Text(
        text, maxLines = 1, modifier = modifier,
        style = TextStyle(fontSize = 12.sp, color = GlanceTheme.colors.onSurfaceVariant),
    )
}

/** 没有内容时：一句话，点一下打开 App */
@Composable
private fun EmptyWidget(text: String) {
    val ctx = LocalContext.current
    Column(
        GlanceModifier.fillMaxSize().clickable(
            actionStartActivity(Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        ),
        horizontalAlignment = Alignment.CenterHorizontally, verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("智悲佛网", style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium, color = GlanceTheme.colors.onSurfaceVariant))
        Spacer(GlanceModifier.height(6.dp))
        Text(text, style = TextStyle(fontSize = 14.sp, color = GlanceTheme.colors.onSurface))
    }
}
