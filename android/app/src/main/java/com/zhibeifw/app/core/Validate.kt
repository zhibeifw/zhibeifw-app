package com.zhibeifw.app.core

import java.text.Normalizer

// 外部数据（服务器 JSON）的校验。一律当作不可信输入——只当数据，先校验大小、类型、长度，再入库。
// 规则与 v1.0 validate.ts、iOS Validate.swift 逐条一致。JSON 解析用自己写的 Json.kt。

enum class FileKind(val limit: Int) {
    DOMAINS(10 * 1024), INDEX(10 * 1024 * 1024), UPGRADE(10 * 1024)
}

object Limits {
    const val MAX_ID_LENGTH = 100
    const val MAX_TITLE_LENGTH = 200
    const val MAX_DESCRIPTION_LENGTH = 5000
    const val MAX_PATH_LENGTH = 300
    const val MAX_DOMAIN_ITEMS = 10
    const val MAX_EPISODE_DURATION = 24 * 3600
    const val MAX_UPDATED_AT = 1e11
    const val MAX_FEATURED = 50
}

fun utf8ByteLength(s: String): Int = s.toByteArray(Charsets.UTF_8).size

/** 课程 ID、集 ID：文字、十进制数字、下划线、连字符，NFC 标准写法，1–100 个字符（UTF-16 码元）。 */
fun isValidId(v: Any?): Boolean {
    val s = v as? String ?: return false
    if (s.isEmpty() || s.length > Limits.MAX_ID_LENGTH) return false
    if (!Normalizer.isNormalized(s, Normalizer.Form.NFC)) return false
    var i = 0
    while (i < s.length) {
        val cp = s.codePointAt(i)
        i += Character.charCount(cp)
        if (cp == '_'.code || cp == '-'.code) continue
        when (Character.getType(cp)) {
            Character.UPPERCASE_LETTER.toInt(), Character.LOWERCASE_LETTER.toInt(), Character.TITLECASE_LETTER.toInt(),
            Character.MODIFIER_LETTER.toInt(), Character.OTHER_LETTER.toInt(), Character.DECIMAL_DIGIT_NUMBER.toInt() -> continue

            else -> return false
        }
    }
    return true
}

private val SCHEME_RE = Regex("^[A-Za-z][A-Za-z0-9+.-]*:")

/** 相对路径：不带协议和域名、不以“/”开头、不含“..”；不允许反斜杠、控制字符、空白、?、#。 */
fun isValidRelativePath(v: Any?): Boolean {
    val s = v as? String ?: return false
    if (s.isEmpty() || s.length > Limits.MAX_PATH_LENGTH) return false
    if (s.startsWith("/") || s.contains("..") || s.contains("\\")) return false
    if (SCHEME_RE.containsMatchIn(s) || s.contains("//")) return false
    for (c in s) if (c.code <= 0x20 || c.code == 0x7F || c == '?' || c == '#') return false
    return true
}

private fun title(v: Any?): String? {
    val s = v as? String ?: return null
    if (s.isEmpty() || s.length > Limits.MAX_TITLE_LENGTH || s.isBlank()) return null
    return s
}

private val ORIGIN_RE =
    Regex("^https://(\\[[0-9A-Fa-f:.]{2,45}\\]|[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*)(?::[0-9]{1,5})?$")

/** https://域名[:端口]，不带路径、不带结尾斜杠、不带账号密码。IPv6 须带方括号。 */
fun isHttpsOrigin(v: Any?): Boolean {
    val s = v as? String ?: return false
    return s.length <= 253 && ORIGIN_RE.matches(s)
}

private fun parseJson(text: String, kind: FileKind): Any? {
    if (utf8ByteLength(text) > kind.limit) return null
    return try {
        Json.parse(text)
    } catch (e: Exception) {
        null
    }
}

private typealias JObj = Map<*, *>
private typealias JArr = List<*>

private fun JObj.raw(k: String): Any? = this[k].takeIf { it != JsonNull }
private fun number(v: Any?): Double? = v as? Double

// ---------- domains.json ----------
data class Domains(val domains: List<String>) {
    fun toJson(): String = Json.stringify(mapOf("domains" to domains))
}

fun parseDomains(text: String): Domains? {
    val o = parseJson(text, FileKind.DOMAINS) as? JObj ?: return null
    val arr = o.raw("domains") as? JArr ?: return null
    val out = ArrayList<String>()
    for (v in arr.take(Limits.MAX_DOMAIN_ITEMS)) {
        if (isHttpsOrigin(v) && !out.contains(v as String)) out.add(v)
    }
    return if (out.isEmpty()) null else Domains(out)
}

// ---------- index.json ----------
data class CategoryEntry(val id: String, val name: String, val icon: String?, val color: String?)
data class EpisodeEntry(
    val id: String,
    val title: String,
    val audioPath: String,
    val duration: Int?
)

data class SeriesEntry(
    val id: String,
    val title: String,
    val categoryId: String,
    val coverPath: String,
    val status: String,
    val description: String?,
    val episodes: List<EpisodeEntry>,
    val updatedAt: Long?,
)

data class FeaturedEntry(val title: String, val seriesId: String)

/** categoryOrder：分类页（方块网格）的先后，分类 ID 列表；只给分类页用，主页仍按 categories 的先后。没有就跟 categories 一样。 */
data class IndexFile(
    val categories: List<CategoryEntry>,
    val series: List<SeriesEntry>,
    val featured: List<FeaturedEntry>,
    val categoryOrder: List<String> = emptyList()
)

fun parseIndex(text: String): IndexFile? {
    val o = parseJson(text, FileKind.INDEX) as? JObj ?: return null
    val cats = o.raw("categories") as? JArr ?: return null
    val categories = ArrayList<CategoryEntry>()
    val series = ArrayList<SeriesEntry>()
    val catIds = HashSet<String>();
    val seriesSeen = HashSet<String>();
    val episodeSeen = HashSet<String>()
    var rawSeries = 0
    for (cv in cats) {
        val c = cv as? JObj ?: continue
        val cid = c.raw("id")
        if (!isValidId(cid)) continue
        val name = title(c.raw("name")) ?: continue
        cid as String
        if (!catIds.add(cid)) continue
        val icon = c.raw("icon");
        val color = c.raw("color")
        categories.add(
            CategoryEntry(
                cid,
                name,
                if (isValidIconSetting(icon)) icon as String else null,
                if (isValidColorSetting(color)) color as String else null
            )
        )
        val list = c.raw("series") as? JArr ?: continue
        for (sv in list) {
            rawSeries++
            val s = sv as? JObj ?: continue
            val sid = s.raw("id")
            if (!isValidId(sid)) continue
            sid as String
            if (seriesSeen.contains(sid)) continue
            val st = title(s.raw("title")) ?: continue
            val cover = s.raw("coverPath")
            if (!isValidRelativePath(cover)) continue
            val status = s.raw("status") as? String
            if (status != "ongoing" && status != "completed") continue
            seriesSeen.add(sid)
            val episodes = ArrayList<EpisodeEntry>()
            (s.raw("episodes") as? JArr)?.let { eps ->
                for (ev in eps) {
                    val e = ev as? JObj ?: continue
                    val eid = e.raw("id")
                    if (!isValidId(eid)) continue
                    eid as String
                    if (episodeSeen.contains(eid)) continue
                    val et = title(e.raw("title")) ?: continue
                    val ap = e.raw("audioPath")
                    if (!isValidRelativePath(ap)) continue
                    episodeSeen.add(eid)
                    val d = number(e.raw("duration"))
                    val duration =
                        if (d != null && d.isFinite() && d > 0 && d <= Limits.MAX_EPISODE_DURATION) Math.round(
                            d
                        ).toInt() else null
                    episodes.add(EpisodeEntry(eid, et, ap as String, duration))
                }
            }
            val desc = (s.raw("description") as? String)?.takeIf { it.isNotBlank() }
                ?.let { if (it.length > Limits.MAX_DESCRIPTION_LENGTH) it.take(Limits.MAX_DESCRIPTION_LENGTH) else it }
            val u = number(s.raw("updatedAt"))
            val updatedAt =
                if (u != null && u == Math.floor(u) && u > 0 && u < Limits.MAX_UPDATED_AT) u.toLong() else null
            series.add(
                SeriesEntry(
                    sid,
                    st,
                    cid,
                    cover as String,
                    status,
                    desc,
                    episodes,
                    updatedAt
                )
            )
        }
    }
    if (categories.isEmpty()) return null
    if (rawSeries > 0 && series.isEmpty()) return null
    val featured = ArrayList<FeaturedEntry>()
    (o.raw("featured") as? JArr)?.let { fs ->
        for (fv in fs) {
            if (featured.size >= Limits.MAX_FEATURED) break
            val f = fv as? JObj ?: continue
            val t = title(f.raw("title")) ?: continue
            val sid = f.raw("seriesId")
            if (isValidId(sid)) featured.add(FeaturedEntry(t, sid as String))
        }
    }
    val order = ArrayList<String>()
    (o.raw("categoryOrder") as? JArr)?.let { os ->
        for (v in os) if (isValidId(v) && v as String !in order) order.add(
            v
        )
    }
    return IndexFile(categories, series, featured, order)
}

// ---------- upgrade.json ----------
data class UpgradeFile(val latestVersion: String, val minVersion: String, val apkPath: String)

fun parseUpgrade(text: String): UpgradeFile? {
    val o = parseJson(text, FileKind.UPGRADE) as? JObj ?: return null
    val min = o.raw("minVersion");
    val latest = o.raw("latestVersion")
    val cmp = compareVersions(min, latest) ?: return null
    if (cmp == 1) return null
    val apk = o.raw("apkPath")
    if (!isValidRelativePath(apk) || !(apk as String).startsWith("releases/")) return null
    return UpgradeFile(latest as String, min as String, apk)
}
