package com.zhibeifw.app.widget

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import androidx.compose.runtime.snapshotFlow
import com.zhibeifw.app.AppModel
import com.zhibeifw.app.Phase
import com.zhibeifw.app.core.placeholderColor
import com.zhibeifw.app.images.ImageLoader
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * 给桌面小组件备数据（与 iOS WidgetFeeder.swift 同样的规则）：把继续播放、最新课程、编辑精选、收藏写进 App 目录，再刷新小组件。
 * 什么时候写：主页目录、收藏变了，换了一集、播放 / 暂停变了、读到这一集的时长（等 1 秒合并成一次），退到后台时，小组件的按钮执行完时。
 * 播放进度不跟着每 5 秒的保存写，退到后台、暂停时会带上最新进度。
 */
class WidgetFeeder(private val ctx: Context, private val model: AppModel, private val scope: CoroutineScope) {
    private var started = false
    private val lock = Mutex()

    /** 进入主页后开始（数据库和目录都好了） */
    @OptIn(FlowPreview::class)
    fun start() {
        if (started) return
        started = true
        // 启动时刷新一次：数据没变时不会刷新，App 升级后桌面上可能还是旧版画出来的样子
        scope.launch { runCatching { updateAllWidgets(ctx) } }
        scope.launch {
            snapshotFlow {
                val p = model.player
                listOf(model.catalogVersion, model.favoritesVersion, p?.current?.episodeId, p?.looksPlaying, (p?.duration ?: 0.0) > 0)
            }.distinctUntilChanged().debounce(1000).collect { write() }
        }
    }

    /**
     * 小组件按钮执行完：只改“继续播放”这一条，只刷新有播放按钮的两个小组件（继续播放、最新课程），按钮马上变；
     * 完整的数据随后照常再写一次（等 1 秒那次）。
     * 封面用已经存好的（换成最新课程里的一集时，它的封面在那里已经存过）
     */
    suspend fun quickUpdateNowPlaying(playing: Boolean) {
        if (!started) return
        val p = model.player ?: return
        val c = p.current ?: return
        val i = c.info
        val name = ImageLoader.diskName(i.coverPath) + ".jpg"
        val changed = withContext(Dispatchers.IO) {
            val cover = name.takeIf { File(WidgetStore.coversDir(ctx), it).exists() }
            val np = WidgetNowPlaying(
                WidgetItem(i.seriesId, i.seriesTitle, i.episodeId, i.episodeTitle, cover, placeholderColor(i.seriesId).light),
                // 写按钮要切到的状态：刚发出暂停 / 播放时播放器的状态还没变过来
                p.position, p.duration, playing, true,
            )
            WidgetStore.write(ctx, WidgetStore.read(ctx).copy(nowPlaying = np))
        }
        if (changed) {
            NowPlayingWidget().refreshAll(ctx)
            LatestWidget().refreshAll(ctx)
        }
    }

    /** 马上写（退到后台） */
    suspend fun writeNow() {
        if (started) write()
    }

    private suspend fun write() = lock.withLock {
        if (model.phase != Phase.Ready) return@withLock
        try {
            val snap = withCovers(build())
            if (withContext(Dispatchers.IO) { WidgetStore.write(ctx, snap) }) updateAllWidgets(ctx)
        } catch (e: Exception) {
            Log.w("WidgetFeeder", "写小组件数据出错", e)
        }
    }

    private suspend fun build(): WidgetSnapshot {
        val store = model.store
        val home = model.home
        val p = model.player
        val c = p?.current
        // 读当前播放状态在主线程，读库在 IO 线程
        val loaded = c?.let {
            WidgetNowPlaying(
                item(it.info.seriesId, it.info.seriesTitle, it.info.coverPath, it.info.episodeId, it.info.episodeTitle),
                p.position, p.duration, p.looksPlaying, true,
            )
        }
        return withContext(Dispatchers.IO) {
            val now = loaded ?: store.loadRecent(20).firstOrNull { !it.gone && !it.progress.completed }?.let { r ->
                WidgetNowPlaying(
                    item(r.seriesId, r.seriesTitle, r.coverPath, r.episodeId, r.epTitle),
                    r.progress.position, r.progress.duration, playing = false, loaded = false,
                )
            }
            WidgetSnapshot(
                nowPlaying = now,
                latest = home.ongoing.take(LATEST_LIMIT).mapNotNull { s ->
                    store.lastEpisode(s.id)?.let { (id, title) -> item(s.id, s.title, s.coverPath, id, title) }
                },
                featured = home.featured.take(GRID_LIMIT).map { item(it.id, it.featureTitle ?: it.title, it.coverPath) },
                favorites = store.loadFavorites().filter { !it.gone }.take(GRID_LIMIT).map { item(it.id, it.title, it.coverPath) },
            )
        }
    }

    /** cover 先放原路径，withCovers 换成 covers 目录里的文件名 */
    private fun item(seriesId: String, title: String, coverPath: String, episodeId: String? = null, episodeTitle: String? = null) =
        WidgetItem(seriesId, title, episodeId, episodeTitle, coverPath.ifEmpty { null }, placeholderColor(seriesId).light)

    /** 把用到的封面缩小存进 covers 目录（已有的跳过），删掉不再用的；取不到的封面留空，小组件显示占位色 */
    private suspend fun withCovers(s: WidgetSnapshot): WidgetSnapshot {
        val dir = WidgetStore.coversDir(ctx)
        withContext(Dispatchers.IO) { dir.mkdirs() }
        val all = listOfNotNull(s.nowPlaying?.item) + s.latest + s.featured + s.favorites
        val names = HashMap<String, String?>()
        for (path in all.mapNotNull { it.cover }.toSet()) {
            val name = ImageLoader.diskName(path) + ".jpg"
            val f = File(dir, name)
            names[path] = if (withContext(Dispatchers.IO) { f.exists() }) name else {
                val bmp = model.images.load(path, COVER_PX)
                if (bmp != null && withContext(Dispatchers.IO) { save(bmp, f) }) name else null
            }
        }
        fun fix(i: WidgetItem) = i.copy(cover = i.cover?.let { names[it] })
        val keep = names.values.filterNotNull().toSet()
        withContext(Dispatchers.IO) { dir.listFiles()?.forEach { if (it.name !in keep) it.delete() } }
        return s.copy(
            nowPlaying = s.nowPlaying?.let { it.copy(item = fix(it.item)) },
            latest = s.latest.map(::fix), featured = s.featured.map(::fix), favorites = s.favorites.map(::fix),
        )
    }

    /** 缩到 COVER_PX 宽再存 JPEG：桌面小组件的图片走进程间传递，总大小有限 */
    private fun save(bmp: Bitmap, f: File): Boolean = runCatching {
        val w = minOf(COVER_PX, bmp.width)
        val small = if (bmp.width > w) Bitmap.createScaledBitmap(bmp, w, bmp.height * w / bmp.width, true) else bmp
        val tmp = File(f.path + ".tmp")
        tmp.outputStream().use { small.compress(Bitmap.CompressFormat.JPEG, 85, it) }
        tmp.renameTo(f)
    }.getOrDefault(false)

    companion object {
        /** 每种列表最多几条：大号小组件放得下的数量 */
        const val LATEST_LIMIT = 7
        const val GRID_LIMIT = 9
        const val COVER_PX = 360

        suspend fun updateAllWidgets(ctx: Context) {
            NowPlayingWidget().refreshAll(ctx)
            LatestWidget().refreshAll(ctx)
            FeaturedWidget().refreshAll(ctx)
            FavoritesWidget().refreshAll(ctx)
        }
    }
}
