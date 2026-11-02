package com.zhibeifw.app.core

import com.zhibeifw.app.design.ZColor
import com.zhibeifw.app.design.generated.IconData
import com.zhibeifw.app.design.generated.Tok
import java.text.Normalizer
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// 各处用到的纯逻辑（与 iOS Logic.swift 逐条一致）。

// ---------- 版本号 ----------
private val VERSION_RE = Regex("^[0-9]+(\\.[0-9]+){0,2}$")

fun parseVersion(v: Any?): List<String>? {
    val s = v as? String ?: return null
    if (!VERSION_RE.matches(s)) return null
    val parts = s.split(".").map { p -> p.trimStart('0').ifEmpty { "0" } }.toMutableList()
    while (parts.size < 3) parts.add("0")
    return parts
}

/** -1（a 较旧）、0、1（a 较新）；任一方格式不合法返回 null。每段不设上限：先比位数、再逐位比。 */
fun compareVersions(a: Any?, b: Any?): Int? {
    val pa = parseVersion(a) ?: return null
    val pb = parseVersion(b) ?: return null
    for (i in 0 until 3) {
        val x = pa[i];
        val y = pb[i]
        if (x.length != y.length) return if (x.length < y.length) -1 else 1
        if (x != y) return if (x < y) -1 else 1
    }
    return 0
}

// ---------- 时间与文字格式 ----------
const val MINUS = "−"

/** 全 App 统一的时间写法：分钟:秒，不分小时（113:32）。 */
fun clock(sec: Double): String {
    val s = max(0.0, floor(if (sec.isFinite()) sec else 0.0)).toLong()
    return "%02d:%02d".format(s / 60, s % 60)
}

fun remainingClock(position: Double, duration: Double) =
    MINUS + clock(max(0.0, duration - position))

fun sleepLabel(secondsLeft: Double?) =
    if (secondsLeft == null) "zZ 本集结束" else "zZ ${clock(secondsLeft)}"

enum class PillKind { NEW, HALF, DONE }
data class PillState(val kind: PillKind, val text: String)
data class Prog(val position: Double, val duration: Double, val completed: Boolean)

private fun minutes(sec: Double) = max(1, (sec / 60).roundToInt())

/** 单集播放胶囊的三种状态。 */
fun pillState(p: Prog?, knownDuration: Double = 0.0): PillState {
    val fresh =
        PillState(PillKind.NEW, if (knownDuration > 0) "${minutes(knownDuration)} 分钟" else "播放")
    if (p == null) return fresh
    if (p.completed) return PillState(
        PillKind.DONE,
        if (p.duration > 0) "${minutes(p.duration)} 分钟" else "已听完"
    )
    if (p.position > 0 && p.duration > 0) return PillState(
        PillKind.HALF,
        "剩 ${clock(max(0.0, p.duration - p.position))}"
    )
    return fresh
}

fun progressRatio(position: Double, duration: Double) =
    if (duration > 0) min(1.0, max(0.0, position / duration)) else 0.0

fun seriesStatusText(status: String?) = if (status == "completed") "已完结" else "更新中"

/** 系列页信息行分类名之后的那段：“ · 共 N 节课 · 更新中”（有分类名时前面带“ · ”，没有集时省掉节数）。 */
fun seriesInfoText(category: Boolean, count: Int, status: String?) =
    (if (category) " · " else "") + (if (count > 0) "共 $count 节课 · " else "") + seriesStatusText(
        status
    )

// ---------- 搜索的文字统一 ----------
private val INVISIBLE = listOf(
    0x0000..0x001F,
    0x007F..0x009F,
    0x200B..0x200F,
    0x2028..0x202E,
    0x2060..0x2064,
    0xFEFF..0xFEFF
)

fun normalizeText(s: String): String {
    val sb = StringBuilder()
    var i = 0
    while (i < s.length) {
        val cp = s.codePointAt(i)
        i += Character.charCount(cp)
        if (INVISIBLE.none { cp in it }) sb.appendCodePoint(cp)
    }
    val t = Normalizer.normalize(sb.toString(), Normalizer.Form.NFKC).lowercase()
    return t.split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
}

const val MAX_QUERY_LENGTH = 30

// ---------- 封面占位色、分类方块 ----------
private fun fnv(id: String, salt: Int = 0): Long {
    var h = (0x811c9dc5.toInt() xor salt)
    for (c in id) {
        h = h xor c.code; h *= 0x01000193
    }
    return h.toLong() and 0xFFFFFFFFL
}

fun placeholderIndex(id: String): Int = (fnv(id) % Tok.ContentPalette.colors.size).toInt()
fun placeholderColor(id: String): ZColor = Tok.ContentPalette.colors[placeholderIndex(id)]

val PALETTE_NAMES = listOf("orange", "blue", "purple", "pink", "teal", "olive", "green", "brown")

/** 分类方块多出的 10 种颜色名（顺序对应 Tok.ContentPalette.categoryExtraColors）；封面占位色块不用它们 */
val CATEGORY_EXTRA_COLOR_NAMES = listOf(
    "red",
    "amber",
    "magenta",
    "indigo",
    "slate",
    "forest",
    "cocoa",
    "cyan",
    "wine",
    "charcoal"
)
const val DEFAULT_ICON = "book-outline"
val RANDOM_ICONS = listOf(
    "school-outline",
    "shield-checkmark-outline",
    "planet-outline",
    "infinite-outline",
    "bulb-outline",
    "flower-outline",
    "book-outline",
    "leaf-outline",
    "accessibility-outline",
    "flame-outline",
    "library-outline",
    "chatbubble-ellipses-outline",
    "sunny-outline",
    "moon-outline",
    "star-outline",
    "heart-outline",
    "cloudy-outline",
    "water-outline",
)
private val ICON_RE = Regex("^[a-z0-9]+(-[a-z0-9]+)*$")

fun isPaletteName(v: Any?) = v is String && (v in PALETTE_NAMES || v in CATEGORY_EXTRA_COLOR_NAMES)
fun isValidColorSetting(v: Any?) = v == "random" || isPaletteName(v)
fun isValidIconSetting(v: Any?): Boolean {
    val s = v as? String ?: return false
    if (s == "random") return true
    return s.length in 1..40 && ICON_RE.matches(s)
}

fun resolveCategoryColor(color: String?, id: String): ZColor {
    val i = PALETTE_NAMES.indexOf(color)
    if (i >= 0) return Tok.ContentPalette.colors[i]
    val k = CATEGORY_EXTRA_COLOR_NAMES.indexOf(color)
    return if (k >= 0) Tok.ContentPalette.categoryExtraColors[k] else placeholderColor(id)
}

fun resolveCategoryIcon(
    icon: String?,
    id: String,
    known: (String) -> Boolean = { IconData.get(it) != null }
): String {
    if (icon == "random") return RANDOM_ICONS[(fnv(id, 0x5a) % RANDOM_ICONS.size).toInt()]
    if (icon != null && isValidIconSetting(icon) && known(icon)) return icon
    return DEFAULT_ICON
}

// ---------- 本机文件名（两端逐位一致） ----------
private val SAFE_KEY = Regex("^[A-Za-z0-9_-]{1,64}$")

fun fileKey(id: String): String {
    if (SAFE_KEY.matches(id)) return id
    var a = 0x811c9dc5.toInt()
    var b = 0x9747b28c.toInt()
    for (ch in id) { // Kotlin 的 Char 就是 UTF-16 码元
        val c = ch.code
        a = (a xor c) * 0x01000193
        b = (b xor c) * 0x5bd1e995
        b = b xor (b ushr 15)
    }
    return "h_" + "%08x".format(a.toLong() and 0xFFFFFFFFL) + "%08x".format(b.toLong() and 0xFFFFFFFFL)
}

fun orphanCoverKeys(onDisk: List<String>, seriesWithDownloads: List<String>): List<String> {
    val keep = seriesWithDownloads.map(::fileKey).toSet()
    return onDisk.filter { it !in keep }
}

fun orphanPartKeys(onDisk: List<String>, keepEpisodeIds: List<String>): List<String> {
    val keep = keepEpisodeIds.map(::fileKey).toSet()
    return onDisk.filter { it !in keep }
}

/** 资料库音频目录里没有下载记录对应的文件名（keep：各条记录的本地文件名）。 */
fun orphanAudioNames(onDisk: List<String>, keep: List<String>): List<String> {
    val k = keep.toSet()
    return onDisk.filter { it !in k }
}

/** 写文件出错是不是因为存储空间不足（ENOSPC）；其它错误按普通失败处理。 */
fun isNoSpaceError(e: Throwable): Boolean {
    var c: Throwable? = e
    while (c != null) {
        val m = c.message ?: ""
        if ("ENOSPC" in m || "No space left" in m) return true
        c = c.cause.takeIf { it !== c }
    }
    return false
}


// ---------- 播放 ----------
// 令牌是 Float，直接 toDouble() 会变成 1.2999999523…（存进设置、显示在档位上都会错）；按十进制文字转
val PLAYBACK_RATES: List<Double> = Tok.RatePicker.rates.map { it.toString().toDouble() }
val SLEEP_MINUTES = listOf(60, 45, 30, 15, 10, 5)

sealed class SleepSetting {
    object Off : SleepSetting()
    object End : SleepSetting()
    /** deadline：到点的时刻，开机以来的毫秒数（SystemClock.elapsedRealtime，含休眠，不受改系统时间影响）。 */
    data class Timer(val deadline: Long, val minutes: Int) : SleepSetting()

    val choiceId: String
        get() = when (this) {
            Off -> "off"; End -> "end"; is Timer -> "m$minutes"
        }

    fun secondsLeft(now: Long): Double? =
        if (this is Timer) max(0.0, ceil((deadline - now) / 1000.0)) else null
}

data class SleepChoice(val id: String, val title: String, val minutes: Int?)

val SLEEP_CHOICES: List<SleepChoice> = listOf(SleepChoice("end", "单集结束时", null)) +
        SLEEP_MINUTES.map {
            SleepChoice(
                "m$it",
                if (it == 60) "1 小时" else "$it 分钟",
                it
            )
        } + SleepChoice("off", "关闭", null)

sealed class PlayContext {
    data class Series(val seriesId: String) : PlayContext()
    data class Library(val seriesId: String) : PlayContext()
    object Single : PlayContext()
}

fun pickNext(ordered: List<String>, current: String): String? {
    val i = ordered.indexOf(current)
    return if (i >= 0 && i + 1 < ordered.size) ordered[i + 1] else null
}

const val COMPLETED_TAIL_SECONDS = 30.0
fun isNearEnd(position: Double, duration: Double) =
    duration > 0 && position >= duration - COMPLETED_TAIL_SECONDS

/** 列表里正在播放的这一集用播放器的实时位置。 */
fun liveProgress(
    currentId: String?,
    position: Double,
    duration: Double,
    active: Boolean,
    episodeId: String,
    fromDb: Prog?
): Prog? {
    if (currentId == episodeId && duration > 0) {
        if (fromDb != null && fromDb.completed && !active) return fromDb
        return Prog(position, duration, false)
    }
    return fromDb
}

// ---------- 单集“•••”菜单里的下载项 ----------
enum class DlStatus(val raw: String) {
    QUEUED("queued"), DOWNLOADING("downloading"), PAUSED("paused"), DONE("done");

    companion object {
        fun of(s: String?) = entries.firstOrNull { it.raw == s }
    }
}

enum class DlMenuAction { DOWNLOAD, PAUSE, RESUME, CANCEL, DELETE }
data class DlMenuItem(
    val action: DlMenuAction,
    val title: String,
    val icon: String,
    val destructive: Boolean
)

fun downloadMenuItems(status: DlStatus?, canDownload: Boolean = true): List<DlMenuItem> =
    when (status) {
        DlStatus.DONE -> listOf(DlMenuItem(DlMenuAction.DELETE, "删除下载", "trash-outline", true))
        DlStatus.QUEUED, DlStatus.DOWNLOADING -> listOf(
            DlMenuItem(DlMenuAction.PAUSE, "暂停下载", "pause-circle-outline", false),
            DlMenuItem(DlMenuAction.CANCEL, "取消下载", "close-circle-outline", false)
        )

        DlStatus.PAUSED -> listOf(
            DlMenuItem(DlMenuAction.RESUME, "继续下载", "arrow-down-circle-outline", false),
            DlMenuItem(DlMenuAction.CANCEL, "取消下载", "close-circle-outline", false)
        )

        null -> if (canDownload) listOf(
            DlMenuItem(
                DlMenuAction.DOWNLOAD,
                "下载",
                "arrow-down-circle-outline",
                false
            )
        ) else emptyList()
    }

// ---------- 防双击压两层页面 ----------
class PushGuard(
    private val windowMs: Long = 700,
    private val now: () -> Long = { System.currentTimeMillis() }
) {
    private val lastAt = HashMap<String, Long>()
    private val shown = HashSet<String>()
    fun allow(key: String): Boolean {
        if (key in shown) return false
        val t = now()
        val p = lastAt[key]
        if (p != null && t - p < windowMs) return false
        lastAt[key] = t
        return true
    }

    fun setShown(key: String, on: Boolean) {
        if (on) shown.add(key) else shown.remove(key)
    }
}

// ---------- 同步时机 ----------
const val FOREGROUND_SYNC_MIN_GAP_MS = 60_000L
fun shouldSyncOnForeground(now: Long, lastSyncAt: Long, syncing: Boolean) =
    !syncing && now - lastSyncAt >= FOREGROUND_SYNC_MIN_GAP_MS

const val LAUNCH_FRESH_MAX_MS = 3000L
fun launchFreshWaitMs(online: Boolean, elapsedMs: Long) =
    if (online) max(0L, LAUNCH_FRESH_MAX_MS - elapsedMs) else 0L

// ---------- 更新检查 ----------
const val CHECK_INTERVAL_MS = 24L * 3600 * 1000
const val REMIND_LATER_MS = 7L * 24 * 3600 * 1000

fun shouldAutoCheck(lastCheckedAt: Long?, now: Long): Boolean =
    lastCheckedAt == null || now - lastCheckedAt >= CHECK_INTERVAL_MS || now < lastCheckedAt

enum class UpdateChannel { SITE, STORE }
sealed class UpdateDecision {
    object None : UpdateDecision()
    data class Optional(val version: String, val apkPath: String) : UpdateDecision()
    data class Outdated(val version: String, val apkPath: String) : UpdateDecision()
}

fun decideUpdate(current: String, u: UpgradeFile, channel: UpdateChannel): UpdateDecision {
    val vsMin = compareVersions(current, u.minVersion) ?: return UpdateDecision.None
    val vsLatest = compareVersions(current, u.latestVersion) ?: return UpdateDecision.None
    if (vsMin == -1) return UpdateDecision.Outdated(u.latestVersion, u.apkPath)
    if (channel == UpdateChannel.SITE && vsLatest == -1) return UpdateDecision.Optional(
        u.latestVersion,
        u.apkPath
    )
    return UpdateDecision.None
}

data class RemindLater(val version: String, val at: Long)

fun suppressedByRemindLater(r: RemindLater?, version: String, now: Long) =
    r != null && r.version == version && now >= r.at && now - r.at < REMIND_LATER_MS

// ---------- 域名顺序 ----------
fun orderOrigins(remembered: String?, saved: List<String>, builtin: List<String>): List<String> {
    val out = ArrayList<String>()
    fun add(o: String?) {
        if (o != null && o !in out) out.add(o)
    }
    add(remembered)
    saved.forEach(::add)
    builtin.forEach(::add)
    return out
}

// ---------- 封面解码尺寸档位 ----------
/** 封面按显示宽度解码；宽度按 256 像素一档往上取整，相近的尺寸共用一份解码结果（切换页面时不再先闪色块）。 */
const val COVER_PIXEL_STEP = 256
fun coverBucket(px: Int): Int =
    maxOf(COVER_PIXEL_STEP, (px + COVER_PIXEL_STEP - 1) / COVER_PIXEL_STEP * COVER_PIXEL_STEP)

/** 封面小图（由发布脚本生成，规则和这里一致）：
 *  封面文件名在扩展名前加“-宽度”，如 中观/入中论讲解/cover.jpg → cover-640.jpg。 */
val COVER_THUMB_WIDTHS = listOf(320, 640)
fun coverThumbPath(path: String, width: Int): String {
    val dot = path.lastIndexOf('.')
    if (dot < 0 || path.indexOf('/', dot) >= 0) return path
    return path.substring(0, dot) + "-" + width + path.substring(dot)
}

/** 按显示需要的宽度（像素）挑文件：不超过 320 用 320 小图，不超过 640 用 640 小图，再大用原图（只会挑够大的，不会放大变糊）。 */
fun coverSourcePath(path: String, requestedPx: Int): String =
    COVER_THUMB_WIDTHS.firstOrNull { requestedPx <= it }?.let { coverThumbPath(path, it) } ?: path

/** 视图向加载器要的宽度：用小图的范围里取小图的宽度，再大按 256 一档（尺寸小幅变化时不必重新取图）。 */
fun coverRequestPx(px: Int): Int = COVER_THUMB_WIDTHS.firstOrNull { px <= it } ?: coverBucket(px)

// ---------- 资料库的节数文字 ----------
/** 全部下完：“3 节”；还有在下载 / 排队 / 暂停的：“3 节 · 已下载 1 节”。 */
fun libraryCountText(total: Int, done: Int): String =
    if (done >= total) "$total 节" else "$total 节 · 已下载 $done 节"

/** 资料库列表行用：分成两行（行里文字和封面并排、太窄，放一行会被折断）。全部下完只有“3 节”。 */
fun libraryCountLines(total: Int, done: Int): List<String> =
    if (done >= total) listOf("$total 节") else listOf("$total 节", "已下载 $done 节")
