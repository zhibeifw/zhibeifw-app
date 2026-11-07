package com.zhibeifw.app.widget

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import com.zhibeifw.app.core.Json
import java.io.File

// App 和桌面小组件之间传的数据（与 iOS WidgetShared/WidgetSnapshot.swift 同样的内容）：
// App 写一份 JSON 和几张小封面到 App 自己的目录，小组件只读、只画，不读数据库、不联网。

/** 一门课（或这门课的某一集） */
data class WidgetItem(
    val seriesId: String,
    val seriesTitle: String,
    /** 要播的那一集 */
    val episodeId: String? = null,
    val episodeTitle: String? = null,
    /** covers 目录里的文件名；还没有封面图时为空，显示占位色 */
    val cover: String? = null,
    /** 没有封面时的占位色（ARGB），和 App 里同一门课的色块一样 */
    val color: Long,
)

/** 继续播放：App 里正在播放的这一集；App 没在播时是最近播放里最近一条没听完的 */
data class WidgetNowPlaying(
    val item: WidgetItem,
    val position: Double,
    val duration: Double,
    val playing: Boolean,
    /** App 里当前载入的就是这一集（点小组件打开播放页；否则进这门课的课程页） */
    val loaded: Boolean,
)

data class WidgetSnapshot(
    val nowPlaying: WidgetNowPlaying? = null,
    /** 最新课程：主页“新课程”里每门课的最新一集 */
    val latest: List<WidgetItem> = emptyList(),
)

object WidgetStore {
    fun dir(ctx: Context) = File(ctx.filesDir, "widgets")
    fun coversDir(ctx: Context) = File(dir(ctx), "covers")
    private fun file(ctx: Context) = File(dir(ctx), "snapshot.json")

    fun read(ctx: Context): WidgetSnapshot = runCatching {
        decode(Json.parse(file(ctx).readText()) as Map<*, *>)
    }.getOrDefault(WidgetSnapshot())

    /** 内容没变就不写，返回 false（不用刷新小组件） */
    fun write(ctx: Context, s: WidgetSnapshot): Boolean {
        val f = file(ctx)
        val text = Json.stringify(encode(s))
        if (f.exists() && runCatching { f.readText() }.getOrNull() == text) return false
        f.parentFile?.mkdirs()
        val tmp = File(f.path + ".tmp")
        tmp.writeText(text)
        return tmp.renameTo(f)
    }

    /** 解码过的封面：刷新小组件（比如点了播放）时不用每张重新解码；文件名就是封面路径的摘要，同名就是同一张图 */
    private val decoded = android.util.LruCache<String, Bitmap>(16)

    fun cover(ctx: Context, name: String?): Bitmap? {
        if (name.isNullOrEmpty()) return null
        decoded.get(name)?.let { return it }
        val f = File(coversDir(ctx), name).takeIf { it.exists() } ?: return null
        return BitmapFactory.decodeFile(f.path)?.also { decoded.put(name, it) }
    }

    private fun encode(i: WidgetItem): Map<String, Any?> = mapOf(
        "seriesId" to i.seriesId, "seriesTitle" to i.seriesTitle, "episodeId" to i.episodeId,
        "episodeTitle" to i.episodeTitle, "cover" to i.cover, "color" to i.color,
    )

    private fun encode(s: WidgetSnapshot): Map<String, Any?> = mapOf(
        "nowPlaying" to s.nowPlaying?.let {
            mapOf(
                "item" to encode(it.item), "position" to it.position, "duration" to it.duration,
                "playing" to it.playing, "loaded" to it.loaded,
            )
        },
        "latest" to s.latest.map(::encode),
    )

    private fun item(m: Map<*, *>) = WidgetItem(
        seriesId = m["seriesId"] as String,
        seriesTitle = m["seriesTitle"] as String,
        episodeId = m["episodeId"] as? String,
        episodeTitle = m["episodeTitle"] as? String,
        cover = m["cover"] as? String,
        color = (m["color"] as Number).toLong(),
    )

    private fun items(v: Any?) = (v as? List<*>)?.mapNotNull { (it as? Map<*, *>)?.let(::item) } ?: emptyList()

    private fun decode(m: Map<*, *>) = WidgetSnapshot(
        nowPlaying = (m["nowPlaying"] as? Map<*, *>)?.let {
            WidgetNowPlaying(
                item(it["item"] as Map<*, *>), (it["position"] as Number).toDouble(),
                (it["duration"] as Number).toDouble(), it["playing"] == true, it["loaded"] == true,
            )
        },
        latest = items(m["latest"]),
    )
}

/** 点小组件打开 App 的链接（App 内部用，只发给自己的 MainActivity） */
sealed class WidgetLink {
    /** 进这门课的课程页 */
    data class Series(val id: String) : WidgetLink()

    /** 打开播放页；App 里已经没有在放的一集时进这门课 */
    data class Player(val seriesId: String) : WidgetLink()

    /** 长按 App 图标菜单：资料库的最近播放、收藏、已下载（res/xml/shortcuts.xml） */
    object Recent : WidgetLink()
    object Favorites : WidgetLink()
    object Downloads : WidgetLink()
    /** 长按图标菜单“分享”：弹出系统分享面板，分享官网链接 */
    object Share : WidgetLink()

    val uri: Uri
        get() = when (this) {
            Recent -> Uri.Builder().scheme(SCHEME).authority("recent").build()
            Favorites -> Uri.Builder().scheme(SCHEME).authority("favorites").build()
            Downloads -> Uri.Builder().scheme(SCHEME).authority("downloads").build()
            Share -> Uri.Builder().scheme(SCHEME).authority("share").build()
            is Series -> Uri.Builder().scheme(SCHEME).authority("series").appendQueryParameter("id", id).build()
            is Player -> Uri.Builder().scheme(SCHEME).authority("player").appendQueryParameter("id", seriesId).build()
        }

    companion object {
        const val SCHEME = "zhibeifw"
        fun parse(uri: Uri?): WidgetLink? {
            if (uri?.scheme != SCHEME) return null
            when (uri.host) {
                "recent" -> return Recent
                "favorites" -> return Favorites
                "downloads" -> return Downloads
                "share" -> return Share
            }
            val id = uri.getQueryParameter("id")?.takeIf { it.isNotEmpty() } ?: return null
            return when (uri.host) {
                "series" -> Series(id)
                "player" -> Player(id)
                else -> null
            }
        }
    }
}
