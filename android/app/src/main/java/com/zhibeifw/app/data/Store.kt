package com.zhibeifw.app.data

import com.zhibeifw.app.core.DlStatus
import com.zhibeifw.app.core.EpisodeEntry
import com.zhibeifw.app.core.IndexFile
import com.zhibeifw.app.core.Json
import com.zhibeifw.app.core.JsonNull
import com.zhibeifw.app.core.MAX_QUERY_LENGTH
import com.zhibeifw.app.core.Prog
import com.zhibeifw.app.core.isNearEnd
import com.zhibeifw.app.core.normalizeText
import kotlin.math.max
import kotlin.math.min

// 目录写库、各页面的读取查询、用户表写入、下载记录（与 v1.0、iOS Store.swift 同样的 SQL）。全部参数绑定。

data class SeriesCard(
    val id: String,
    val title: String,
    val coverPath: String,
    val status: String,
    val lastTitle: String? = null,
    val featureTitle: String? = null
)

data class CategoryRow(val id: String, val name: String, val series: List<SeriesCard>)
data class HomeData(
    val ongoing: List<SeriesCard> = emptyList(),
    val featured: List<SeriesCard> = emptyList(),
    val categories: List<CategoryRow> = emptyList()
)

data class CategoryTile(val id: String, val name: String, val icon: String?, val color: String?)
data class SeriesHeader(
    val id: String,
    val title: String,
    val coverPath: String,
    val status: String,
    val description: String?,
    val categoryId: String,
    val categoryName: String?,
    val favorited: Boolean
)

data class EpisodeRow(
    val id: String,
    val seriesId: String,
    val title: String,
    val audioPath: String,
    val pos: Int,
    val epDuration: Double?,
    val progress: Prog?,
    val dlState: DlStatus?
)

data class FavoriteRow(
    val id: String,
    val title: String,
    val coverPath: String,
    val status: String?,
    val gone: Boolean
)

data class RecentRow(
    val episodeId: String,
    val seriesId: String,
    val epTitle: String,
    val seriesTitle: String,
    val coverPath: String,
    val audioPath: String?,
    val progress: Prog,
    val dlState: DlStatus?,
    val pos: Int?,
    val gone: Boolean,
    val epDuration: Double?
)

data class EpisodeInfo(
    val episodeId: String,
    val seriesId: String,
    val seriesTitle: String,
    val episodeTitle: String,
    val coverPath: String,
    val audioPath: String,
    val pos: Int
)

data class DlItem(
    val episodeId: String,
    val seriesId: String,
    val seriesTitle: String,
    val episodeTitle: String,
    val pos: Int,
    val audioPath: String
)

data class DlRow(
    val episodeId: String,
    val seriesId: String,
    val seriesTitle: String,
    val episodeTitle: String,
    val pos: Int,
    val audioPath: String,
    val localFile: String?,
    val state: DlStatus,
    val retries: Int,
    val requestedAt: Long,
    val bytes: Long,
    val total: Long,
    val validator: String?
) {
    val item get() = DlItem(episodeId, seriesId, seriesTitle, episodeTitle, pos, audioPath)
}

data class LibrarySeries(
    val seriesId: String,
    val seriesTitle: String,
    val n: Int,
    val done: Int,
    val paused: Int,
    val firstRequested: Long,
    val coverPath: String = ""
)

data class LibraryEpisode(val row: DlRow, val progress: Prog?)
data class SearchResult(val rows: List<SeriesCard>, val matched: String, val fallback: Boolean)

const val HOME_LIMIT = 10
const val INDEX_PATH = "index.json"
const val UPGRADE_PATH = "upgrade.json"
const val DOMAINS_PATH = "domains.json"

class Store(val db: Db) {
    private fun now() = System.currentTimeMillis()

    companion object {
        private const val CATEGORY_ORDER_KEY = "category_order"
        fun episodesSig(eps: List<EpisodeEntry>): String = Json.stringify(eps.map {
            listOf(
                it.id,
                it.title,
                it.audioPath,
                it.duration ?: JsonNull
            )
        })

        fun seriesSig(
            title: String,
            categoryId: String,
            coverPath: String,
            status: String,
            description: String?,
            updatedAt: Long?
        ): String =
            Json.stringify(
                listOf(
                    title,
                    categoryId,
                    coverPath,
                    status,
                    description ?: JsonNull,
                    updatedAt ?: JsonNull
                )
            )
    }

    // ---------- 目录写入 ----------

    /** 用 index.json 替换整个目录（一个事务），只写变了的课。 */
    fun replaceIndex(index: IndexFile) = db.transaction {
        val oldRow = HashMap<String, Pair<String?, String?>>()
        for (r in db.all("SELECT id, series_sig, episodes_sig FROM catalog_series")) oldRow[r.str("id")] =
            r.optStr("series_sig") to r.optStr("episodes_sig")
        db.exec("DELETE FROM catalog_category; DELETE FROM catalog_home_featured")
        index.categories.forEachIndexed { i, c ->
            db.run(
                "INSERT INTO catalog_category (id, name, pos, icon, color) VALUES (?,?,?,?,?)",
                c.id,
                c.name,
                i,
                c.icon,
                c.color
            )
        }
        val keep = index.series.map { it.id }.toSet()
        for (id in oldRow.keys) if (id !in keep) db.run(
            "DELETE FROM catalog_series WHERE id = ?",
            id
        )
        index.series.forEachIndexed { i, s ->
            val epSig = episodesSig(s.episodes)
            val rowSig = seriesSig(
                s.title,
                s.categoryId,
                s.coverPath,
                s.status,
                s.description,
                s.updatedAt
            )
            val prev = oldRow[s.id]
            // 先后（pos）不进签名：前面插进一门新课时，后面的课只改先后，不整行重写
            if (prev != null && prev.first == rowSig && prev.second == epSig) {
                db.run("UPDATE catalog_series SET pos = ? WHERE id = ? AND pos <> ?", i, s.id, i)
                return@forEachIndexed
            }
            if (prev != null) {
                db.run(
                    "UPDATE catalog_series SET title = ?, title_norm = ?, category_id = ?, cover_path = ?, status = ?, pos = ?, description = ?, updated_at = ?, series_sig = ?, episodes_sig = ? WHERE id = ?",
                    s.title,
                    normalizeText(s.title),
                    s.categoryId,
                    s.coverPath,
                    s.status,
                    i,
                    s.description,
                    s.updatedAt,
                    rowSig,
                    epSig,
                    s.id
                )
            } else {
                db.run(
                    "INSERT INTO catalog_series (id, title, title_norm, category_id, cover_path, status, pos, description, updated_at, series_sig, episodes_sig) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                    s.id,
                    s.title,
                    normalizeText(s.title),
                    s.categoryId,
                    s.coverPath,
                    s.status,
                    i,
                    s.description,
                    s.updatedAt,
                    rowSig,
                    epSig
                )
            }
            if (prev != null && prev.second == epSig) return@forEachIndexed
            db.run("DELETE FROM catalog_episode WHERE series_id = ?", s.id)
            s.episodes.forEachIndexed { k, e ->
                db.run(
                    "INSERT OR REPLACE INTO catalog_episode (id, series_id, title, audio_path, pos, duration) VALUES (?,?,?,?,?,?)",
                    e.id,
                    s.id,
                    e.title,
                    e.audioPath,
                    k,
                    e.duration
                )
            }
        }
        db.exec("DELETE FROM catalog_episode WHERE series_id NOT IN (SELECT id FROM catalog_series)")
        index.featured.forEachIndexed { i, f ->
            db.run(
                "INSERT OR REPLACE INTO catalog_home_featured (pos, title, series_id) VALUES (?,?,?)",
                i,
                f.title,
                f.seriesId
            )
        }
        // 分类页的先后（只给分类页用）：存成 JSON 数组；index.json 里没有就删掉，分类页回到 categories 的先后
        if (index.categoryOrder.isEmpty()) db.run(
            "DELETE FROM catalog_meta WHERE key = ?",
            CATEGORY_ORDER_KEY
        )
        else db.run(
            "INSERT OR REPLACE INTO catalog_meta (key, value) VALUES (?,?)",
            CATEGORY_ORDER_KEY,
            Json.stringify(index.categoryOrder)
        )
    }

    fun etag(path: String): String? =
        db.first("SELECT etag FROM catalog_sync WHERE path = ?", path)?.optStr("etag")

    fun setEtag(path: String, etag: String?) {
        if (etag != null) db.run(
            "INSERT OR REPLACE INTO catalog_sync (path, etag) VALUES (?,?)",
            path,
            etag
        )
        else db.run("DELETE FROM catalog_sync WHERE path = ?", path)
    }

    val isInitialized: Boolean
        get() = db.first(
            "SELECT 1 AS x FROM catalog_meta WHERE key = ?",
            "initialized"
        ) != null

    fun markInitialized() {
        db.run("INSERT OR REPLACE INTO catalog_meta (key, value) VALUES (?, '1')", "initialized")
    }

    // ---------- 读取 ----------

    private fun card(r: Row) = SeriesCard(
        r.str("id"),
        r.str("title"),
        r.str("cover_path"),
        r.str("status"),
        r.optStr("last_title"),
        r.optStr("feature_title")
    )

    fun loadHome(): HomeData {
        val ongoing = db.all(
            """
            SELECT s.id, s.title, s.cover_path, s.status,
                   (SELECT e.title FROM catalog_episode e WHERE e.series_id = s.id ORDER BY e.pos DESC LIMIT 1) AS last_title
            FROM catalog_series s WHERE s.status = 'ongoing'
            ORDER BY (s.updated_at IS NULL), s.updated_at DESC, s.pos LIMIT $HOME_LIMIT"""
        ).map(::card)
        val seen = HashSet<String>()
        val featured =
            db.all("SELECT s.id, s.title, s.cover_path, s.status, f.title AS feature_title FROM catalog_home_featured f JOIN catalog_series s ON s.id = f.series_id ORDER BY f.pos")
                .map(::card).filter { seen.add(it.id) }
        val cats = db.all("SELECT id, name FROM catalog_category ORDER BY pos").mapNotNull { c ->
            val series = db.all(
                "SELECT id, title, cover_path, status FROM catalog_series WHERE category_id = ? ORDER BY pos LIMIT $HOME_LIMIT",
                c.str("id")
            ).map(::card)
            if (series.isEmpty()) null else CategoryRow(c.str("id"), c.str("name"), series)
        }
        return HomeData(ongoing, featured, cats)
    }

    /** 分类页的方块：按 index.json 的 categoryOrder 排（只给分类页用）；清单里没有的分类排在后面，保持 categories 的先后。 */
    fun loadCategories(): List<CategoryTile> {
        val tiles = db.all("SELECT id, name, icon, color FROM catalog_category ORDER BY pos").map {
            CategoryTile(
                it.str("id"),
                it.str("name"),
                it.optStr("icon"),
                it.optStr("color")
            )
        }
        val order = (db.first("SELECT value FROM catalog_meta WHERE key = ?", CATEGORY_ORDER_KEY)
            ?.optStr("value")
            ?.let { runCatching { Json.parse(it) }.getOrNull() } as? List<*>)?.filterIsInstance<String>()
            .orEmpty()
        if (order.isEmpty()) return tiles
        val rank =
            HashMap<String, Int>().apply { order.forEachIndexed { i, id -> putIfAbsent(id, i) } }
        return tiles.withIndex()
            .sortedWith(compareBy({ rank[it.value.id] ?: (order.size + it.index) }, { it.index }))
            .map { it.value }
    }

    fun categoryName(id: String) =
        db.first("SELECT name FROM catalog_category WHERE id = ?", id)?.optStr("name")

    fun loadCategorySeries(categoryId: String, limit: Int, offset: Int) =
        db.all(
            "SELECT id, title, cover_path, status FROM catalog_series WHERE category_id = ? ORDER BY pos LIMIT ? OFFSET ?",
            categoryId,
            limit,
            offset
        ).map(::card)

    fun loadSeriesHeader(id: String): SeriesHeader? {
        val r = db.first(
            """
            SELECT s.id, s.title, s.cover_path, s.status, s.description, s.category_id, c.name AS category_name,
                   EXISTS (SELECT 1 FROM user_favorite f WHERE f.series_id = s.id) AS favorited
            FROM catalog_series s LEFT JOIN catalog_category c ON c.id = s.category_id WHERE s.id = ?""",
            id
        ) ?: return null
        return SeriesHeader(
            r.str("id"),
            r.str("title"),
            r.str("cover_path"),
            r.str("status"),
            r.optStr("description"),
            r.str("category_id"),
            r.optStr("category_name"),
            r.bool("favorited")
        )
    }

    private fun prog(r: Row): Prog? =
        r.optDouble("position")?.let { Prog(it, r.double("duration"), r.bool("completed")) }

    fun loadEpisodes(seriesId: String) = db.all(
        """
        SELECT e.id, e.series_id, e.title, e.audio_path, e.pos, e.duration AS ep_duration, p.position, p.duration, p.completed, d.state AS dl_state
        FROM catalog_episode e LEFT JOIN user_progress p ON p.episode_id = e.id LEFT JOIN user_download d ON d.episode_id = e.id
        WHERE e.series_id = ? ORDER BY e.pos""", seriesId
    ).map { r ->
        EpisodeRow(
            r.str("id"),
            r.str("series_id"),
            r.str("title"),
            r.str("audio_path"),
            r.int("pos").toInt(),
            r.optDouble("ep_duration"),
            prog(r),
            DlStatus.of(r.optStr("dl_state"))
        )
    }

    fun loadFavorites() = db.all(
        """
        SELECT f.series_id AS id, COALESCE(s.title, NULLIF(f.series_title, ''), '已下架的课程') AS title,
               COALESCE(s.cover_path, NULLIF(f.cover_path, ''), '') AS cover_path, s.status AS status, (s.id IS NULL) AS gone
        FROM user_favorite f LEFT JOIN catalog_series s ON s.id = f.series_id ORDER BY f.added DESC"""
    ).map {
        FavoriteRow(
            it.str("id"),
            it.str("title"),
            it.str("cover_path"),
            it.optStr("status"),
            it.bool("gone")
        )
    }

    fun loadRecent(limit: Int = 500) = db.all(
        """
        SELECT p.episode_id, p.series_id,
               COALESCE(e.title, NULLIF(p.episode_title, ''), '') AS ep_title,
               COALESCE(s.title, NULLIF(p.series_title, ''), '已下架的课程') AS series_title,
               COALESCE(s.cover_path, NULLIF(p.cover_path, ''), '') AS cover_path,
               e.audio_path AS audio_path, e.pos AS pos, e.duration AS ep_duration,
               p.position, p.duration, p.completed, d.state AS dl_state, (e.id IS NULL) AS gone
        FROM user_progress p
        LEFT JOIN catalog_episode e ON e.id = p.episode_id
        LEFT JOIN catalog_series s ON s.id = p.series_id
        LEFT JOIN user_download d ON d.episode_id = p.episode_id
        WHERE p.hidden = 0 ORDER BY p.last_played DESC LIMIT ?""", limit
    ).map { r ->
        RecentRow(
            r.str("episode_id"),
            r.str("series_id"),
            r.str("ep_title"),
            r.str("series_title"),
            r.str("cover_path"),
            r.optStr("audio_path"),
            Prog(r.double("position"), r.double("duration"), r.bool("completed")),
            DlStatus.of(r.optStr("dl_state")),
            r.optInt("pos")?.toInt(),
            r.bool("gone"),
            r.optDouble("ep_duration")
        )
    }

    fun loadProgress(episodeId: String): Prog? =
        db.first(
            "SELECT position, duration, completed FROM user_progress WHERE episode_id = ?",
            episodeId
        )?.let { Prog(it.double("position"), it.double("duration"), it.bool("completed")) }

    fun getEpisodeInfo(episodeId: String): EpisodeInfo? {
        fun info(r: Row) = EpisodeInfo(
            r.str("episodeId"),
            r.str("seriesId"),
            r.str("seriesTitle"),
            r.str("episodeTitle"),
            r.str("coverPath"),
            r.str("audioPath"),
            r.int("pos").toInt()
        )
        db.first(
            """
            SELECT e.id AS episodeId, e.series_id AS seriesId, s.title AS seriesTitle, e.title AS episodeTitle, s.cover_path AS coverPath, e.audio_path AS audioPath, e.pos AS pos
            FROM catalog_episode e JOIN catalog_series s ON s.id = e.series_id WHERE e.id = ?""",
            episodeId
        )?.let { return info(it) }
        return db.first(
            """
            SELECT d.episode_id AS episodeId, d.series_id AS seriesId, COALESCE(s.title, NULLIF(d.series_title, ''), '已下架的课程') AS seriesTitle,
                   d.episode_title AS episodeTitle, COALESCE(s.cover_path, NULLIF(p.cover_path, ''), '') AS coverPath, d.audio_path AS audioPath, d.pos AS pos
            FROM user_download d LEFT JOIN catalog_series s ON s.id = d.series_id LEFT JOIN user_progress p ON p.episode_id = d.episode_id
            WHERE d.episode_id = ? AND d.state = 'done' AND d.local_file IS NOT NULL""", episodeId
        )?.let(::info)
    }

    fun seriesExists(id: String) =
        db.first("SELECT 1 AS x FROM catalog_series WHERE id = ?", id) != null

    /** 一门课的最后一集（新课程“更新至”的那一集）：集 ID 和集名 */
    fun lastEpisode(seriesId: String): Pair<String, String>? =
        db.first("SELECT id, title FROM catalog_episode WHERE series_id = ? ORDER BY pos DESC LIMIT 1", seriesId)
            ?.let { it.str("id") to it.str("title") }

    fun seriesEpisodeIds(seriesId: String) =
        db.all("SELECT id FROM catalog_episode WHERE series_id = ? ORDER BY pos", seriesId)
            .map { it.str("id") }

    fun seriesCoverPath(seriesId: String) =
        db.first("SELECT cover_path FROM catalog_series WHERE id = ?", seriesId)
            ?.optStr("cover_path")

    /** 搜索：先整句，搜不到就从开头 2 个字起逐个加长。instr()，不用 LIKE。 */
    fun searchSeries(input: String): SearchResult {
        val empty = SearchResult(emptyList(), "", false)
        val norm = normalizeText(input)
        val cps = norm.codePoints().toArray().take(MAX_QUERY_LENGTH)
        if (cps.isEmpty()) return empty
        fun str(n: Int) = String(cps.toIntArray(), 0, n)
        val maxLen =
            db.first("SELECT max(length(title_norm)) AS m FROM catalog_series")?.int("m")?.toInt()
                ?: 0
        if (maxLen == 0) return empty
        fun query(k: String) = db.all(
            "SELECT id, title, cover_path, status FROM catalog_series WHERE instr(title_norm, ?) > 0 ORDER BY (instr(title_norm, ?) = 1) DESC, pos LIMIT 500",
            k,
            k
        ).map(::card)
        if (cps.size <= maxLen) {
            val whole = str(cps.size)
            val rows = query(whole)
            if (rows.isNotEmpty()) return SearchResult(rows, whole, false)
        }
        var best = empty
        val top = min(cps.size, maxLen)
        for (n in 2..top) {
            val prefix = str(n)
            val rows = query(prefix)
            if (rows.isEmpty()) break
            best = SearchResult(rows, prefix, true)
        }
        return best
    }

    // ---------- 用户表 ----------

    fun recordPlayback(
        episodeId: String,
        seriesId: String,
        position: Double,
        duration: Double,
        seriesTitle: String = "",
        episodeTitle: String = "",
        coverPath: String = "",
        at: Long? = null
    ): Boolean {
        val t = at ?: now()
        val completed = isNearEnd(position, duration)
        val pos = if (completed) 0.0 else max(0.0, position)
        // 不用 UPSERT（INSERT … DO UPDATE）：要 SQLite 3.24，Android 10 自带的是 3.22。
        // 同一个事务里先插入（已有就跳过），再按同样的规则更新
        db.transaction {
            db.run(
                """
                INSERT OR IGNORE INTO user_progress (episode_id, series_id, position, duration, completed, hidden, last_played, updated, series_title, episode_title, cover_path)
                VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?)""",
                episodeId, seriesId, pos, max(0.0, duration), completed, t, t, seriesTitle, episodeTitle, coverPath
            )
            db.run(
                """
                UPDATE user_progress SET
                  series_id = ?, position = ?,
                  duration = CASE WHEN ? > 0 THEN ? ELSE duration END,
                  completed = ?, hidden = 0, last_played = ?, updated = ?,
                  series_title = CASE WHEN ? <> '' THEN ? ELSE series_title END,
                  episode_title = CASE WHEN ? <> '' THEN ? ELSE episode_title END,
                  cover_path = CASE WHEN ? <> '' THEN ? ELSE cover_path END
                WHERE episode_id = ?""",
                seriesId, pos, duration, duration, completed, t, t,
                seriesTitle, seriesTitle, episodeTitle, episodeTitle, coverPath, coverPath, episodeId
            )
        }
        return completed
    }

    fun recordDuration(episodeId: String, duration: Double) {
        if (duration > 0) db.run(
            "UPDATE user_progress SET duration = ? WHERE episode_id = ? AND duration = 0",
            duration,
            episodeId
        )
    }

    fun markCompleted(
        episodeId: String,
        seriesId: String,
        completed: Boolean,
        seriesTitle: String = "",
        episodeTitle: String = "",
        coverPath: String = ""
    ) {
        val t = now()
        db.transaction {
            db.run(
                """
                INSERT OR IGNORE INTO user_progress (episode_id, series_id, position, duration, completed, hidden, last_played, updated, series_title, episode_title, cover_path)
                VALUES (?, ?, 0, 0, ?, 1, 0, ?, ?, ?, ?)""",
                episodeId, seriesId, completed, t, seriesTitle, episodeTitle, coverPath
            )
            db.run(
                """
                UPDATE user_progress SET position = 0, completed = ?, updated = ?,
                  series_title = CASE WHEN ? <> '' THEN ? ELSE series_title END,
                  episode_title = CASE WHEN ? <> '' THEN ? ELSE episode_title END,
                  cover_path = CASE WHEN ? <> '' THEN ? ELSE cover_path END
                WHERE episode_id = ?""",
                completed, t, seriesTitle, seriesTitle, episodeTitle, episodeTitle, coverPath, coverPath, episodeId
            )
        }
    }

    fun hideFromRecent(episodeId: String) {
        db.run("UPDATE user_progress SET hidden = 1 WHERE episode_id = ?", episodeId)
    }

    fun clearRecent() {
        db.run("UPDATE user_progress SET hidden = 1 WHERE hidden = 0")
    }

    fun addFavorite(
        seriesId: String,
        title: String = "",
        coverPath: String = "",
        at: Long? = null
    ) {
        db.transaction {
            db.run(
                "INSERT OR IGNORE INTO user_favorite (series_id, added, series_title, cover_path) VALUES (?, ?, ?, ?)",
                seriesId, at ?: now(), title, coverPath
            )
            db.run(
                """
                UPDATE user_favorite SET
                  series_title = CASE WHEN ? <> '' THEN ? ELSE series_title END,
                  cover_path = CASE WHEN ? <> '' THEN ? ELSE cover_path END
                WHERE series_id = ?""",
                title, title, coverPath, coverPath, seriesId
            )
        }
    }

    fun removeFavorite(seriesId: String) {
        db.run("DELETE FROM user_favorite WHERE series_id = ?", seriesId)
    }

    fun isFavorite(seriesId: String) =
        db.first("SELECT 1 AS x FROM user_favorite WHERE series_id = ?", seriesId) != null

    // ---------- 下载记录 ----------

    private fun dlRow(r: Row) = DlRow(
        r.str("episode_id"),
        r.str("series_id"),
        r.str("series_title"),
        r.str("episode_title"),
        r.int("pos").toInt(),
        r.str("audio_path"),
        r.optStr("local_file"),
        DlStatus.of(r.optStr("state")) ?: DlStatus.QUEUED,
        r.int("retries").toInt(),
        r.int("requested_at"),
        r.int("bytes"),
        r.int("total"),
        r.optStr("validator")
    )

    fun queuedMany(items: List<DlItem>) {
        val t = now()
        db.transaction {
            for (i in items) db.run(
                """
                INSERT OR REPLACE INTO user_download (episode_id, series_id, series_title, episode_title, pos, audio_path, local_file, state, retries, requested_at)
                VALUES (?,?,?,?,?,?,NULL,'queued',0,?)""",
                i.episodeId,
                i.seriesId,
                i.seriesTitle,
                i.episodeTitle,
                i.pos,
                i.audioPath,
                t
            )
        }
    }

    /** 一批集开始下载：新的先建记录，然后全部记为“下载中”。整批一个事务。 */
    fun startDownloads(fresh: List<DlItem>, ids: List<String>) {
        db.transaction {
            if (fresh.isNotEmpty()) queuedMany(fresh)
            for (id in ids) setDlState(id, DlStatus.DOWNLOADING)
        }
    }

    fun setDlState(id: String, state: DlStatus) {
        db.run("UPDATE user_download SET state = ? WHERE episode_id = ?", state.raw, id)
    }

    fun setDlInfo(id: String, total: Long, validator: String?) {
        db.run(
            "UPDATE user_download SET total = ?, validator = ? WHERE episode_id = ?",
            total,
            validator,
            id
        )
    }

    fun setDlPaused(id: String, bytes: Long) {
        db.run(
            "UPDATE user_download SET state = 'paused', bytes = ? WHERE episode_id = ?",
            bytes,
            id
        )
    }

    fun setDlDone(id: String, localFile: String) {
        db.run(
            "UPDATE user_download SET state = 'done', local_file = ? WHERE episode_id = ?",
            localFile,
            id
        )
    }

    fun removeDownload(id: String) {
        db.run("DELETE FROM user_download WHERE episode_id = ?", id)
    }

    fun getDownload(id: String) =
        db.first("SELECT * FROM user_download WHERE episode_id = ?", id)?.let(::dlRow)

    fun downloadsOfSeries(seriesId: String) =
        db.all("SELECT * FROM user_download WHERE series_id = ? ORDER BY pos", seriesId)
            .map(::dlRow)

    fun allDownloads() = db.all("SELECT * FROM user_download").map(::dlRow)
    fun doneDownloads() = db.all("SELECT * FROM user_download WHERE state = 'done'").map(::dlRow)
    fun seriesIdsWithDownloads() =
        db.all("SELECT DISTINCT series_id FROM user_download").map { it.str("series_id") }

    fun doneEpisodeIds(seriesId: String) = db.all(
        "SELECT episode_id FROM user_download WHERE series_id = ? AND state = 'done' ORDER BY pos",
        seriesId
    ).map { it.str("episode_id") }

    fun loadLibrary() = db.all(
        """
        SELECT d.series_id AS series_id, COALESCE(s.title, max(d.series_title)) AS series_title, s.cover_path AS cover_path,
               count(*) AS n, sum(d.state = 'done') AS done, sum(d.state = 'paused') AS paused, min(d.requested_at) AS first_requested
        FROM user_download d LEFT JOIN catalog_series s ON s.id = d.series_id
        GROUP BY d.series_id ORDER BY first_requested DESC"""
    ).map {
        LibrarySeries(
            it.str("series_id"),
            it.str("series_title"),
            it.int("n").toInt(),
            it.int("done").toInt(),
            it.int("paused").toInt(),
            it.int("first_requested"),
            it.str("cover_path")
        )
    }

    fun loadLibraryEpisodes(seriesId: String) = db.all(
        """
        SELECT d.episode_id, d.series_id, COALESCE(s.title, d.series_title) AS series_title, COALESCE(e.title, d.episode_title) AS episode_title,
               d.pos, d.audio_path, d.local_file, d.state, d.retries, d.requested_at, d.bytes, d.total, d.validator,
               p.position, p.duration, p.completed
        FROM user_download d
        LEFT JOIN user_progress p ON p.episode_id = d.episode_id
        LEFT JOIN catalog_series s ON s.id = d.series_id
        LEFT JOIN catalog_episode e ON e.id = d.episode_id
        WHERE d.series_id = ? ORDER BY d.pos""", seriesId
    ).map { LibraryEpisode(dlRow(it), prog(it)) }
}
