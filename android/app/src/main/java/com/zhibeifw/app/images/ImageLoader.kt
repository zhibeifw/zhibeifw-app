package com.zhibeifw.app.images

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import com.zhibeifw.app.core.coverBucket
import com.zhibeifw.app.core.coverRequestPx
import com.zhibeifw.app.core.coverSourcePath
import com.zhibeifw.app.core.placeholderColor
import com.zhibeifw.app.design.C
import com.zhibeifw.app.design.generated.Tok
import com.zhibeifw.app.net.NetConfig
import com.zhibeifw.app.net.Network
import com.zhibeifw.app.net.buildUrl
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext

// 封面图加载（自己写，不用 Coil / Glide）。与 iOS ImageLoader.swift 同样的规则：
// 按相对路径作缓存键；内存缓存 LruCache（按字节数限额）+ 磁盘缓存（系统缓存目录，不设上限）；
// 网络走当前线路；BitmapFactory + inSampleSize 降采样到显示尺寸；离开屏幕的请求随协程取消。
// 列表里的小图先下发布脚本生成的 320 / 640 小图（coverSourcePath），服务器上没有就改用原图。
class ImageLoader(private val net: Network, val diskDir: File) {
    private val memory = object : LruCache<String, Bitmap>(48 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.byteCount
    }
    private val inflight = HashMap<String, Deferred<Fetch>>()

    enum class Fetch { OK, NOT_FOUND, FAILED }

    /** 每张图（按原图路径）在内存里解码过的最大一份：换尺寸时先拿它顶上，不闪色块。 */
    private val largest = ConcurrentHashMap<String, Pair<String, Int>>()

    /** 服务器上没有小图的封面（老课程、漏传）：本次运行里直接用原图，不再白请求。 */
    private val noThumbs = ConcurrentHashMap.newKeySet<String>()

    /** 小图请求的结果计数：开头连续 3 张都“不存在”、一张都没成功，就认为服务器还没传小图，这次运行里全部直接用原图 */
    private val thumbHits = AtomicInteger()
    private val thumbMisses = AtomicInteger()
    private val thumbsOff get() = thumbHits.get() == 0 && thumbMisses.get() >= 3

    init {
        diskDir.mkdirs()
    }

    companion object {
        fun diskName(path: String): String =
            MessageDigest.getInstance("SHA-256").digest(path.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }

        fun decode(file: File, maxPixel: Int): Bitmap? {
            val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.path, o)
            if (o.outWidth <= 0) return null
            var sample = 1
            while (maxOf(o.outWidth, o.outHeight) / (sample * 2) >= maxPixel) sample *= 2
            return BitmapFactory.decodeFile(
                file.path,
                BitmapFactory.Options().apply { inSampleSize = sample })
        }
    }

    /** 这个显示宽度该用哪个文件（小图 / 原图） */
    private fun source(path: String, requested: Int) =
        if (thumbsOff || path in noThumbs) path else coverSourcePath(path, requested)

    private fun key(src: String, px: Int) = "$src#$px"
    private fun diskFile(src: String) = File(diskDir, diskName(src))

    fun cached(path: String, requested: Int): Bitmap? =
        memory.get(key(source(path, requested), coverBucket(requested)))

    /** 这张图在内存里已有的任一尺寸（取最大的）：正确尺寸还在解码时先用它显示。 */
    fun anyCached(path: String): Bitmap? = largest[path]?.let { memory.get(it.first) }

    private fun put(k: String, path: String, bmp: Bitmap) {
        memory.put(k, bmp)
        val w = maxOf(bmp.width, bmp.height)
        largest.merge(path, k to w) { a, b -> if (b.second > a.second) b else a }
    }

    /** 取图：内存 → 本地文件（资料库离线封面）→ 磁盘缓存 → 网络。 */
    suspend fun load(path: String, requested: Int, localFile: File? = null): Bitmap? {
        val px = coverBucket(requested)
        return withContext(Dispatchers.IO) {
            if (localFile != null && localFile.exists()) {
                val k = key(path, px)
                memory.get(k)?.let { return@withContext it }
                decode(localFile, px)?.let { put(k, path, it); return@withContext it }
            }
            if (path.isEmpty() || path.startsWith("local:")) return@withContext null // 只有本地封面的键：本地文件没了就没有，不去网上取
            memory.get(key(source(path, requested), px))?.let { return@withContext it }
            if (!ensureOnDisk(path, requested)) return@withContext null
            val src = source(path, requested) // 小图不存在时，上一步已改成原图
            val bmp = decode(diskFile(src), px) ?: run { diskFile(src).delete(); null }
            bmp?.also { put(key(src, px), path, it) }
        }
    }

    /** 保证这个尺寸要用的文件在磁盘上（小图没有就下原图）。预先下载也用它。 */
    suspend fun ensureOnDisk(path: String, requested: Int): Boolean {
        val src = source(path, requested)
        if (diskFile(src).exists()) return true
        val r = fetch(src)
        if (src != path) {
            if (r == Fetch.OK) thumbHits.incrementAndGet() else if (r == Fetch.NOT_FOUND) thumbMisses.incrementAndGet()
        }
        if (r == Fetch.OK) return true
        // 只有服务器明确说“没有这张小图”（404）才改用原图；网络失败不算
        if (src == path || r != Fetch.NOT_FOUND) return false
        noThumbs.add(path)
        return diskFile(path).exists() || fetch(path) == Fetch.OK
    }

    /** 下载一个文件到磁盘缓存；同一个文件并发只下一次。 */
    private suspend fun fetch(src: String): Fetch {
        val d: Deferred<Fetch>
        val mine: Boolean
        synchronized(inflight) {
            val existing = inflight[src]
            if (existing != null) {
                d = existing; mine = false
            } else {
                d = CompletableDeferred(); inflight[src] = d; mine = true
            }
        }
        if (mine) {
            val ok = try {
                download(src, diskFile(src))
            } catch (e: Throwable) {
                Fetch.FAILED
            }
            synchronized(inflight) { inflight.remove(src) }
            (d as CompletableDeferred).complete(ok)
        }
        return d.await()
    }

    private suspend fun download(src: String, file: File): Fetch {
        val origin = withContext(NonCancellable) { net.ensureRoutes() } ?: return Fetch.FAILED
        return try {
            val c = URL(buildUrl(origin, src)).openConnection() as HttpURLConnection
            c.connectTimeout = NetConfig.IDLE_TIMEOUT_MS
            c.readTimeout = NetConfig.IDLE_TIMEOUT_MS
            try {
                val code = c.responseCode
                if (code == 404 || code == 403) return Fetch.NOT_FOUND // R2 公开桶不存在的文件回 404（个别配置回 403）
                if (code != 200) return Fetch.FAILED
                val tmp = File(file.path + ".tmp")
                // 下到一半断了、被取消或改名失败：删掉半截的临时文件，不在缓存目录里留碎片
                try {
                    c.inputStream.use { ins -> tmp.outputStream().use { ins.copyTo(it) } }
                    if (tmp.renameTo(file)) Fetch.OK else {
                        tmp.delete(); Fetch.FAILED
                    }
                } catch (e: Exception) {
                    tmp.delete(); throw e
                }
            } finally {
                c.disconnect()
            }
        } catch (e: Exception) {
            Fetch.FAILED
        }
    }

    /** 预先下载（只存磁盘、不解码），最多同时 3 张：主页刷新后把主页上的封面先下好。 */
    fun prefetch(scope: CoroutineScope, items: List<Pair<String, Int>>) {
        val list = items.filter { it.first.isNotEmpty() }
        if (list.isEmpty()) return
        val gate = Semaphore(3)
        scope.launch(Dispatchers.IO) {
            list.forEach { (p, r) ->
                launch {
                    gate.withPermit {
                        ensureOnDisk(
                            p,
                            r
                        )
                    }
                }
            }
        }
    }

    /** 关于页“清除缓存”：清内存和磁盘两层（不碰已下载课程另存的封面）。 */
    fun clear(): Boolean {
        memory.evictAll()
        largest.clear()
        noThumbs.clear(); thumbHits.set(0); thumbMisses.set(0)
        diskDir.listFiles()?.forEach { it.delete() }
        return diskDir.exists() || diskDir.mkdirs()
    }
}

/** 封面视图：加载中是淡灰底，图到了淡入；没有封面或加载失败时显示内容色块。 */
@Composable
fun CoverImage(
    loader: ImageLoader,
    coverPath: String,
    colorId: String,
    shape: Shape,
    modifier: Modifier = Modifier,
    localFile: File? = null,
    originVersion: Int = 0
) {
    // 取图和缓存用的键。已下架的课目录里没有封面路径，但下载时存过本地封面：用“local:课程 ID”当键，
    // 否则几门这样的课都用空字符串当键，会互相串图
    val path = if (coverPath.isEmpty() && localFile != null) "local:$colorId" else coverPath
    var failed by remember(path) { mutableStateOf(false) }
    // 没有封面、或确实取不到：内容色块；还在加载：淡灰底（不像色块那样显眼）
    val bg =
        if ((path.isEmpty() && localFile == null) || failed) Color(placeholderColor(colorId).light) else C.backgroundSecondary()
    BoxWithConstraints(modifier.clip(shape).background(bg).clearAndSetSemantics { }) {
        val px = coverRequestPx(with(LocalDensity.current) { maxWidth.roundToPx() })
        // 换尺寸（播放页弹出、横竖屏）时不清空：正确尺寸解码好之前，先用内存里这张图的任一尺寸顶上，不闪色块
        val first =
            remember(path) { (loader.cached(path, px) ?: loader.anyCached(path))?.asImageBitmap() }
        var img by remember(path) { mutableStateOf(first) }
        val alpha = remember(path) { Animatable(if (first != null) 1f else 0f) }
        LaunchedEffect(path, px, originVersion) {
            val exact = loader.cached(path, px)
            if (exact != null) {
                img = exact.asImageBitmap(); failed = false; alpha.snapTo(1f); return@LaunchedEffect
            }
            if (path.isEmpty() && localFile == null) return@LaunchedEffect
            val bmp = loader.load(path, px, localFile)
            if (bmp != null) {
                img = bmp.asImageBitmap(); failed = false
                alpha.animateTo(1f, tween(Tok.Motion.fadeMs.toInt()))
            } else if (img == null) failed = true
        }
        img?.let {
            Image(
                it,
                contentDescription = null,
                modifier = Modifier.fillMaxSize().graphicsLayer { this.alpha = alpha.value },
                contentScale = ContentScale.Crop
            )
        }
    }
}
