import Foundation

// 目录写库、各页面的读取查询、用户表写入、下载记录（与 v1.0 db/catalog.ts、queries.ts、user.ts、downloads.ts 一致）。
// 全部参数绑定；需要同时用到目录和用户数据的页面用一条 SQL 联表。

// MARK: - 行类型

struct SeriesCard: Identifiable, Equatable, Hashable {
    var id: String; var title: String; var coverPath: String; var status: String
    var lastTitle: String? = nil  // 新课程：“更新至 ”+ 最后一集
    var featureTitle: String? = nil
}
struct CategoryRow: Identifiable, Equatable { var id: String; var name: String; var series: [SeriesCard] }
struct HomeData: Equatable { var ongoing: [SeriesCard] = []; var featured: [SeriesCard] = []; var categories: [CategoryRow] = [] }
struct CategoryTile: Identifiable, Equatable { var id: String; var name: String; var icon: String?; var color: String? }

struct SeriesHeader: Equatable {
    var id: String; var title: String; var coverPath: String; var status: String; var description: String?
    var categoryId: String; var categoryName: String?; var favorited: Bool
}

struct EpisodeRow: Identifiable, Equatable {
    var id: String; var seriesId: String; var title: String; var audioPath: String; var pos: Int; var epDuration: Double?
    var progress: Prog?
    var dlState: DlStatus?
}

struct FavoriteRow: Identifiable, Equatable {
    var id: String; var title: String; var coverPath: String; var status: String?; var gone: Bool
}

struct RecentRow: Identifiable, Equatable {
    var id: String { episodeId }
    var episodeId: String; var seriesId: String; var epTitle: String; var seriesTitle: String; var coverPath: String
    var audioPath: String?; var progress: Prog; var dlState: DlStatus?; var pos: Int?; var gone: Bool; var epDuration: Double?
}

struct EpisodeInfo: Equatable {
    var episodeId: String; var seriesId: String; var seriesTitle: String; var episodeTitle: String; var coverPath: String;
    var audioPath: String; var pos: Int
}

struct DlItem: Equatable, Hashable {
    var episodeId: String; var seriesId: String; var seriesTitle: String; var episodeTitle: String; var pos: Int; var audioPath: String
}

struct DlRow: Equatable {
    var episodeId: String; var seriesId: String; var seriesTitle: String; var episodeTitle: String; var pos: Int; var audioPath: String
    var localFile: String?; var state: DlStatus; var retries: Int; var requestedAt: Int64; var bytes: Int64; var total: Int64;
    var validator: String?
    var item: DlItem {
        DlItem(
            episodeId: episodeId, seriesId: seriesId, seriesTitle: seriesTitle, episodeTitle: episodeTitle, pos: pos, audioPath: audioPath)
    }
}

struct LibrarySeries: Identifiable, Equatable {
    var id: String { seriesId }
    var seriesId: String; var seriesTitle: String; var n: Int; var done: Int; var paused: Int; var firstRequested: Int64
    var coverPath = ""
}

struct LibraryEpisode: Identifiable, Equatable {
    var id: String { row.episodeId }
    var row: DlRow; var progress: Prog?
}

// MARK: - Store

let HOME_LIMIT = 10
let INDEX_PATH = "index.json"
let UPGRADE_PATH = "upgrade.json"
let DOMAINS_PATH = "domains.json"

final class Store: @unchecked Sendable {
    let db: SQLiteDB
    init(db: SQLiteDB) { self.db = db }

    /// 拼音搜索用：每门课的拼音（按目录顺序）。第一次拼音搜索时算，目录换了作废。搜索在后台线程，加锁。
    private struct PinyinEntry { let card: SeriesCard; let initials: String; let full: String }
    private var pinyinCache: [PinyinEntry]?
    private let pinyinLock = NSLock()

    private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: 目录写入

    static func episodesSig(_ eps: [EpisodeEntry]) -> String {
        let arr: [[Any]] = eps.map { [$0.id, $0.title, $0.audioPath, $0.duration.map { $0 as Any } ?? NSNull()] }
        return jsonString(arr)
    }
    static func seriesSig(
        title: String, categoryId: String, coverPath: String, status: String, description: String?, updatedAt: Int64?
    ) -> String {
        jsonString([
            title, categoryId, coverPath, status, description.map { $0 as Any } ?? NSNull(), updatedAt.map { $0 as Any } ?? NSNull(),
        ])
    }
    private static func jsonString(_ v: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes])).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
    }

    /// 用 index.json 替换整个目录（一个事务），只写变了的课。
    func replaceIndex(_ index: IndexFile) throws {
        // 写完（事务提交或失败）以后再作废拼音缓存：写的过程中来的拼音搜索不会把旧目录又缓存回去
        defer { pinyinLock.withLock { pinyinCache = nil } }
        try db.transaction {
            let old = try db.all("SELECT id, series_sig, episodes_sig FROM catalog_series")
            var oldRow: [String: (String?, String?)] = [:]
            for r in old { oldRow[r.str("id")] = (r.optStr("series_sig"), r.optStr("episodes_sig")) }
            try db.exec("DELETE FROM catalog_category; DELETE FROM catalog_home_featured;")
            for (i, c) in index.categories.enumerated() {
                try db.run(
                    "INSERT INTO catalog_category (id, name, pos, icon, color) VALUES (?,?,?,?,?)", [c.id, c.name, i, c.icon, c.color])
            }
            let keep = Set(index.series.map(\.id))
            for id in oldRow.keys where !keep.contains(id) { try db.run("DELETE FROM catalog_series WHERE id = ?", [id]) }
            for (i, s) in index.series.enumerated() {
                let epSig = Self.episodesSig(s.episodes)
                let rowSig = Self.seriesSig(
                    title: s.title, categoryId: s.categoryId, coverPath: s.coverPath, status: s.status, description: s.description,
                    updatedAt: s.updatedAt)
                let prev = oldRow[s.id]
                // 先后（pos）不进签名：前面插进一门新课时，后面的课只改先后，不整行重写
                if let p = prev, p.0 == rowSig, p.1 == epSig {
                    try db.run("UPDATE catalog_series SET pos = ? WHERE id = ? AND pos <> ?", [i, s.id, i])
                    continue
                }
                if prev != nil {
                    try db.run(
                        "UPDATE catalog_series SET title = ?, title_norm = ?, category_id = ?, cover_path = ?, status = ?, pos = ?, description = ?, updated_at = ?, series_sig = ?, episodes_sig = ? WHERE id = ?",
                        [
                            s.title, normalizeText(s.title), s.categoryId, s.coverPath, s.status, i, s.description, s.updatedAt, rowSig,
                            epSig, s.id,
                        ])
                } else {
                    try db.run(
                        "INSERT INTO catalog_series (id, title, title_norm, category_id, cover_path, status, pos, description, updated_at, series_sig, episodes_sig) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                        [
                            s.id, s.title, normalizeText(s.title), s.categoryId, s.coverPath, s.status, i, s.description, s.updatedAt,
                            rowSig, epSig,
                        ])
                }
                if let p = prev, p.1 == epSig { continue }
                try db.run("DELETE FROM catalog_episode WHERE series_id = ?", [s.id])
                for (k, e) in s.episodes.enumerated() {
                    try db.run(
                        "INSERT OR REPLACE INTO catalog_episode (id, series_id, title, audio_path, pos, duration) VALUES (?,?,?,?,?,?)",
                        [e.id, s.id, e.title, e.audioPath, k, e.duration])
                }
            }
            try db.exec("DELETE FROM catalog_episode WHERE series_id NOT IN (SELECT id FROM catalog_series)")
            for (i, f) in index.featured.enumerated() {
                try db.run("INSERT OR REPLACE INTO catalog_home_featured (pos, title, series_id) VALUES (?,?,?)", [i, f.title, f.seriesId])
            }
            // 分类页的先后（只给分类页用）：存成 JSON 数组；index.json 里没有就删掉，分类页回到 categories 的先后
            if index.categoryOrder.isEmpty {
                try db.run("DELETE FROM catalog_meta WHERE key = ?", [Self.categoryOrderKey])
            } else {
                try db.run(
                    "INSERT OR REPLACE INTO catalog_meta (key, value) VALUES (?,?)",
                    [Self.categoryOrderKey, Self.jsonString(index.categoryOrder)])
            }
        }
    }
    private static let categoryOrderKey = "category_order"

    func etag(_ path: String) -> String? { (try? db.first("SELECT etag FROM catalog_sync WHERE path = ?", [path]))??.optStr("etag") }
    func setEtag(_ path: String, _ etag: String?) throws {
        if let e = etag {
            try db.run("INSERT OR REPLACE INTO catalog_sync (path, etag) VALUES (?,?)", [path, e])
        } else {
            try db.run("DELETE FROM catalog_sync WHERE path = ?", [path])
        }
    }

    var isInitialized: Bool { ((try? db.first("SELECT 1 AS x FROM catalog_meta WHERE key = ?", ["initialized"])) ?? nil) != nil }
    func markInitialized() throws { try db.run("INSERT OR REPLACE INTO catalog_meta (key, value) VALUES (?, '1')", ["initialized"]) }

    // MARK: 读取

    private func card(_ r: Row) -> SeriesCard {
        SeriesCard(
            id: r.str("id"), title: r.str("title"), coverPath: r.str("cover_path"), status: r.str("status"),
            lastTitle: r.optStr("last_title"), featureTitle: r.optStr("feature_title"))
    }

    func loadHome() throws -> HomeData {
        let ongoing = try db.all(
            """
            SELECT s.id, s.title, s.cover_path, s.status,
                   (SELECT e.title FROM catalog_episode e WHERE e.series_id = s.id ORDER BY e.pos DESC LIMIT 1) AS last_title
            FROM catalog_series s WHERE s.status = 'ongoing'
            ORDER BY (s.updated_at IS NULL), s.updated_at DESC, s.pos LIMIT \(HOME_LIMIT)
            """
        ).map(card)
        var seen = Set<String>()
        var featured: [SeriesCard] = []
        for r in try db.all(
            "SELECT s.id, s.title, s.cover_path, s.status, f.title AS feature_title FROM catalog_home_featured f JOIN catalog_series s ON s.id = f.series_id ORDER BY f.pos"
        ) {
            let c = card(r)
            if seen.insert(c.id).inserted { featured.append(c) }
        }
        var cats: [CategoryRow] = []
        for c in try db.all("SELECT id, name FROM catalog_category ORDER BY pos") {
            let series = try db.all(
                "SELECT id, title, cover_path, status FROM catalog_series WHERE category_id = ? ORDER BY pos LIMIT \(HOME_LIMIT)",
                [c.str("id")]
            ).map(card)
            if !series.isEmpty { cats.append(CategoryRow(id: c.str("id"), name: c.str("name"), series: series)) }
        }
        return HomeData(ongoing: ongoing, featured: featured, categories: cats)
    }

    /// 分类页的方块：按 index.json 的 categoryOrder 排（只给分类页用）；清单里没有的分类排在后面，保持 categories 的先后。
    func loadCategories() throws -> [CategoryTile] {
        let tiles = try db.all("SELECT id, name, icon, color FROM catalog_category ORDER BY pos").map {
            CategoryTile(id: $0.str("id"), name: $0.str("name"), icon: $0.optStr("icon"), color: $0.optStr("color"))
        }
        let raw = (try db.first("SELECT value FROM catalog_meta WHERE key = ?", [Self.categoryOrderKey]))?.optStr("value")
        guard let order = raw.flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] }), !order.isEmpty else {
            return tiles
        }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return tiles.enumerated().sorted { a, b in
            (rank[a.element.id] ?? order.count + a.offset, a.offset) < (rank[b.element.id] ?? order.count + b.offset, b.offset)
        }.map(\.element)
    }

    func categoryName(_ id: String) -> String? { (try? db.first("SELECT name FROM catalog_category WHERE id = ?", [id]))??.optStr("name") }

    func loadCategorySeries(_ categoryId: String, limit: Int, offset: Int) throws -> [SeriesCard] {
        try db.all(
            "SELECT id, title, cover_path, status FROM catalog_series WHERE category_id = ? ORDER BY pos LIMIT ? OFFSET ?",
            [categoryId, limit, offset]
        ).map(card)
    }

    func loadSeriesHeader(_ id: String) throws -> SeriesHeader? {
        guard
            let r = try db.first(
                """
                SELECT s.id, s.title, s.cover_path, s.status, s.description, s.category_id, c.name AS category_name,
                       EXISTS (SELECT 1 FROM user_favorite f WHERE f.series_id = s.id) AS favorited
                FROM catalog_series s LEFT JOIN catalog_category c ON c.id = s.category_id WHERE s.id = ?
                """, [id])
        else { return nil }
        return SeriesHeader(
            id: r.str("id"), title: r.str("title"), coverPath: r.str("cover_path"), status: r.str("status"),
            description: r.optStr("description"), categoryId: r.str("category_id"), categoryName: r.optStr("category_name"),
            favorited: r.bool("favorited"))
    }

    private func prog(_ r: Row) -> Prog? {
        guard r.optDouble("position") != nil else { return nil }
        return Prog(position: r.double("position"), duration: r.double("duration"), completed: r.bool("completed"))
    }

    func loadEpisodes(_ seriesId: String) throws -> [EpisodeRow] {
        try db.all(
            """
            SELECT e.id, e.series_id, e.title, e.audio_path, e.pos, e.duration AS ep_duration, p.position, p.duration, p.completed, d.state AS dl_state
            FROM catalog_episode e LEFT JOIN user_progress p ON p.episode_id = e.id LEFT JOIN user_download d ON d.episode_id = e.id
            WHERE e.series_id = ? ORDER BY e.pos
            """, [seriesId]
        ).map { r in
            EpisodeRow(
                id: r.str("id"), seriesId: r.str("series_id"), title: r.str("title"), audioPath: r.str("audio_path"),
                pos: Int(r.int("pos")),
                epDuration: r.optDouble("ep_duration"), progress: prog(r), dlState: r.optStr("dl_state").flatMap(DlStatus.init(rawValue:)))
        }
    }

    func loadFavorites() throws -> [FavoriteRow] {
        try db.all(
            """
            SELECT f.series_id AS id, COALESCE(s.title, NULLIF(f.series_title, ''), '已下架的课程') AS title,
                   COALESCE(s.cover_path, NULLIF(f.cover_path, ''), '') AS cover_path, s.status AS status, (s.id IS NULL) AS gone
            FROM user_favorite f LEFT JOIN catalog_series s ON s.id = f.series_id ORDER BY f.added DESC
            """
        ).map {
            FavoriteRow(
                id: $0.str("id"), title: $0.str("title"), coverPath: $0.str("cover_path"), status: $0.optStr("status"),
                gone: $0.bool("gone"))
        }
    }

    func loadRecent(limit: Int = 500) throws -> [RecentRow] {
        try db.all(
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
            WHERE p.hidden = 0 ORDER BY p.last_played DESC LIMIT ?
            """, [limit]
        ).map { r in
            RecentRow(
                episodeId: r.str("episode_id"), seriesId: r.str("series_id"), epTitle: r.str("ep_title"),
                seriesTitle: r.str("series_title"),
                coverPath: r.str("cover_path"), audioPath: r.optStr("audio_path"),
                progress: Prog(position: r.double("position"), duration: r.double("duration"), completed: r.bool("completed")),
                dlState: r.optStr("dl_state").flatMap(DlStatus.init(rawValue:)), pos: r.optInt("pos").map(Int.init), gone: r.bool("gone"),
                epDuration: r.optDouble("ep_duration"))
        }
    }

    func loadProgress(_ episodeId: String) -> Prog? {
        guard let r = (try? db.first("SELECT position, duration, completed FROM user_progress WHERE episode_id = ?", [episodeId])) ?? nil
        else { return nil }
        return Prog(position: r.double("position"), duration: r.double("duration"), completed: r.bool("completed"))
    }

    func getEpisodeInfo(_ episodeId: String) throws -> EpisodeInfo? {
        func info(_ r: Row) -> EpisodeInfo {
            EpisodeInfo(
                episodeId: r.str("episodeId"), seriesId: r.str("seriesId"), seriesTitle: r.str("seriesTitle"),
                episodeTitle: r.str("episodeTitle"),
                coverPath: r.str("coverPath"), audioPath: r.str("audioPath"), pos: Int(r.int("pos")))
        }
        if let r = try db.first(
            """
            SELECT e.id AS episodeId, e.series_id AS seriesId, s.title AS seriesTitle, e.title AS episodeTitle, s.cover_path AS coverPath, e.audio_path AS audioPath, e.pos AS pos
            FROM catalog_episode e JOIN catalog_series s ON s.id = e.series_id WHERE e.id = ?
            """, [episodeId])
        {
            return info(r)
        }
        return try db.first(
            """
            SELECT d.episode_id AS episodeId, d.series_id AS seriesId, COALESCE(s.title, NULLIF(d.series_title, ''), '已下架的课程') AS seriesTitle,
                   d.episode_title AS episodeTitle, COALESCE(s.cover_path, NULLIF(p.cover_path, ''), '') AS coverPath, d.audio_path AS audioPath, d.pos AS pos
            FROM user_download d LEFT JOIN catalog_series s ON s.id = d.series_id LEFT JOIN user_progress p ON p.episode_id = d.episode_id
            WHERE d.episode_id = ? AND d.state = 'done' AND d.local_file IS NOT NULL
            """, [episodeId]
        ).map(info)
    }

    func seriesExists(_ id: String) -> Bool { ((try? db.first("SELECT 1 AS x FROM catalog_series WHERE id = ?", [id])) ?? nil) != nil }
    func seriesEpisodeIds(_ seriesId: String) throws -> [String] {
        try db.all("SELECT id FROM catalog_episode WHERE series_id = ? ORDER BY pos", [seriesId]).map { $0.str("id") }
    }

    struct SearchResult: Equatable { var rows: [SeriesCard]; var matched: String; var fallback: Bool }

    /// 搜索：按课程名找；输入全是英文字母时再按拼音找（首字母或全拼，比如 jgj、jingang 都能找到“金刚经”），
    /// 课程名本身匹配的排在前面。
    func searchSeries(_ input: String) throws -> SearchResult {
        let byTitle = try searchByTitle(input)
        guard let pq = pinyinQuery(input) else { return byTitle }
        // 课程名“逐字缩短”的部分匹配对拼音没有意义：拼音能找到时不用它
        let titleRows = byTitle.fallback ? [] : byTitle.rows
        var seen = Set(titleRows.map(\.id))
        let rows = titleRows + (try pinyinMatches(pq)).filter { seen.insert($0.id).inserted }
        if rows.isEmpty { return byTitle }
        return SearchResult(rows: Array(rows.prefix(500)), matched: normalizeText(input), fallback: false)
    }

    /// 拼音匹配：首字母开头 > 首字母包含 > 全拼开头 > 全拼包含；同一档按目录顺序。
    private func pinyinMatches(_ q: String) throws -> [SeriesCard] {
        let entries: [PinyinEntry] = try pinyinLock.withLock {
            if let c = pinyinCache { return c }
            let c = try db.all("SELECT id, title, cover_path, status FROM catalog_series ORDER BY pos").map { r -> PinyinEntry in
                let c = card(r)
                let k = pinyinKeys(c.title)
                return PinyinEntry(card: c, initials: k.initials, full: k.full)
            }
            pinyinCache = c
            return c
        }
        func rank(_ e: PinyinEntry) -> Int? {
            if e.initials.hasPrefix(q) { return 0 }
            if e.initials.contains(q) { return 1 }
            if e.full.hasPrefix(q) { return 2 }
            if e.full.contains(q) { return 3 }
            return nil
        }
        let hits = entries.enumerated().compactMap { i, e in rank(e).map { (rank: $0, pos: i, card: e.card) } }
        return hits.sorted { ($0.rank, $0.pos) < ($1.rank, $1.pos) }.prefix(500).map { $0.card }
    }

    /// 按课程名搜：先整句，搜不到就从开头 2 个字起逐个加长。instr()，不用 LIKE。
    private func searchByTitle(_ input: String) throws -> SearchResult {
        let empty = SearchResult(rows: [], matched: "", fallback: false)
        let q = Array(Array(normalizeText(input).unicodeScalars).prefix(MAX_QUERY_LENGTH))
        func str(_ a: ArraySlice<Unicode.Scalar>) -> String {
            var v = String.UnicodeScalarView(); v.append(contentsOf: a); return String(v)
        }
        if q.isEmpty { return empty }
        let maxLen = Int(try db.first("SELECT max(length(title_norm)) AS m FROM catalog_series")?.int("m") ?? 0)
        if maxLen == 0 { return empty }
        func query(_ k: String) throws -> [SeriesCard] {
            try db.all(
                "SELECT id, title, cover_path, status FROM catalog_series WHERE instr(title_norm, ?) > 0 ORDER BY (instr(title_norm, ?) = 1) DESC, pos LIMIT 500",
                [k, k]
            ).map(card)
        }
        if q.count <= maxLen {
            let whole = str(q[...])
            let rows = try query(whole)
            if !rows.isEmpty { return SearchResult(rows: rows, matched: whole, fallback: false) }
        }
        var best = empty
        let top = min(q.count, maxLen)
        if top >= 2 {
            for n in 2...top {
                let prefix = str(q.prefix(n))
                let rows = try query(prefix)
                if rows.isEmpty { break }
                best = SearchResult(rows: rows, matched: prefix, fallback: true)
            }
        }
        return best
    }

    // MARK: 用户表（“状态规则一览”）

    @discardableResult
    func recordPlayback(
        episodeId: String, seriesId: String, position: Double, duration: Double, seriesTitle: String = "", episodeTitle: String = "",
        coverPath: String = "", at: Int64? = nil
    ) throws -> Bool {
        let t = at ?? now()
        let completed = isNearEnd(position, duration)
        let pos = completed ? 0 : max(0, position)
        try db.run(
            """
            INSERT INTO user_progress (episode_id, series_id, position, duration, completed, hidden, last_played, updated, series_title, episode_title, cover_path)
            VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?)
            ON CONFLICT(episode_id) DO UPDATE SET
              series_id = excluded.series_id, position = excluded.position,
              duration = CASE WHEN excluded.duration > 0 THEN excluded.duration ELSE user_progress.duration END,
              completed = excluded.completed, hidden = 0, last_played = excluded.last_played, updated = excluded.updated,
              series_title = CASE WHEN excluded.series_title <> '' THEN excluded.series_title ELSE user_progress.series_title END,
              episode_title = CASE WHEN excluded.episode_title <> '' THEN excluded.episode_title ELSE user_progress.episode_title END,
              cover_path = CASE WHEN excluded.cover_path <> '' THEN excluded.cover_path ELSE user_progress.cover_path END
            """, [episodeId, seriesId, pos, max(0, duration), completed, t, t, seriesTitle, episodeTitle, coverPath])
        return completed
    }

    func recordDuration(_ episodeId: String, _ duration: Double) throws {
        guard duration > 0 else { return }
        try db.run("UPDATE user_progress SET duration = ? WHERE episode_id = ? AND duration = 0", [duration, episodeId])
    }

    func markCompleted(
        _ episodeId: String, seriesId: String, completed: Bool, seriesTitle: String = "", episodeTitle: String = "", coverPath: String = ""
    ) throws {
        try db.run(
            """
            INSERT INTO user_progress (episode_id, series_id, position, duration, completed, hidden, last_played, updated, series_title, episode_title, cover_path)
            VALUES (?, ?, 0, 0, ?, 1, 0, ?, ?, ?, ?)
            ON CONFLICT(episode_id) DO UPDATE SET position = 0, completed = excluded.completed, updated = excluded.updated,
              series_title = CASE WHEN excluded.series_title <> '' THEN excluded.series_title ELSE user_progress.series_title END,
              episode_title = CASE WHEN excluded.episode_title <> '' THEN excluded.episode_title ELSE user_progress.episode_title END,
              cover_path = CASE WHEN excluded.cover_path <> '' THEN excluded.cover_path ELSE user_progress.cover_path END
            """, [episodeId, seriesId, completed, now(), seriesTitle, episodeTitle, coverPath])
    }

    func hideFromRecent(_ episodeId: String) throws { try db.run("UPDATE user_progress SET hidden = 1 WHERE episode_id = ?", [episodeId]) }
    func clearRecent() throws { try db.run("UPDATE user_progress SET hidden = 1 WHERE hidden = 0") }

    func addFavorite(_ seriesId: String, title: String = "", coverPath: String = "", at: Int64? = nil) throws {
        try db.run(
            """
            INSERT INTO user_favorite (series_id, added, series_title, cover_path) VALUES (?, ?, ?, ?)
            ON CONFLICT(series_id) DO UPDATE SET
              series_title = CASE WHEN excluded.series_title <> '' THEN excluded.series_title ELSE user_favorite.series_title END,
              cover_path = CASE WHEN excluded.cover_path <> '' THEN excluded.cover_path ELSE user_favorite.cover_path END
            """, [seriesId, at ?? now(), title, coverPath])
    }
    func removeFavorite(_ seriesId: String) throws { try db.run("DELETE FROM user_favorite WHERE series_id = ?", [seriesId]) }
    func isFavorite(_ seriesId: String) -> Bool {
        ((try? db.first("SELECT 1 AS x FROM user_favorite WHERE series_id = ?", [seriesId])) ?? nil) != nil
    }

    // MARK: 下载记录

    private func dlRow(_ r: Row) -> DlRow {
        DlRow(
            episodeId: r.str("episode_id"), seriesId: r.str("series_id"), seriesTitle: r.str("series_title"),
            episodeTitle: r.str("episode_title"),
            pos: Int(r.int("pos")), audioPath: r.str("audio_path"), localFile: r.optStr("local_file"),
            state: DlStatus(rawValue: r.str("state")) ?? .queued, retries: Int(r.int("retries")), requestedAt: r.int("requested_at"),
            bytes: r.int("bytes"), total: r.int("total"), validator: r.optStr("validator"))
    }

    func queuedMany(_ items: [DlItem]) throws {
        let t = now()
        try db.transaction {
            for i in items {
                try db.run(
                    """
                    INSERT OR REPLACE INTO user_download (episode_id, series_id, series_title, episode_title, pos, audio_path, local_file, state, retries, requested_at)
                    VALUES (?,?,?,?,?,?,NULL,'queued',0,?)
                    """, [i.episodeId, i.seriesId, i.seriesTitle, i.episodeTitle, i.pos, i.audioPath, t])
            }
        }
    }
    /// 一批集开始下载：新的先建记录，然后全部记为“下载中”。整批一个事务。
    func startDownloads(_ fresh: [DlItem], ids: [String]) throws {
        try db.transaction {
            if !fresh.isEmpty { try queuedMany(fresh) }
            for id in ids { try setDlState(id, .downloading) }
        }
    }
    func setDlState(_ id: String, _ state: DlStatus) throws {
        try db.run("UPDATE user_download SET state = ? WHERE episode_id = ?", [state.rawValue, id])
    }
    func setDlInfo(_ id: String, total: Int64, validator: String?) throws {
        try db.run("UPDATE user_download SET total = ?, validator = ? WHERE episode_id = ?", [total, validator, id])
    }
    func setDlPaused(_ id: String, bytes: Int64) throws {
        try db.run("UPDATE user_download SET state = 'paused', bytes = ? WHERE episode_id = ?", [bytes, id])
    }
    func setDlDone(_ id: String, localFile: String) throws {
        try db.run("UPDATE user_download SET state = 'done', local_file = ? WHERE episode_id = ?", [localFile, id])
    }
    func removeDownload(_ id: String) throws { try db.run("DELETE FROM user_download WHERE episode_id = ?", [id]) }
    func getDownload(_ id: String) -> DlRow? {
        ((try? db.first("SELECT * FROM user_download WHERE episode_id = ?", [id])) ?? nil).map(dlRow)
    }
    func downloadsOfSeries(_ seriesId: String) throws -> [DlRow] {
        try db.all("SELECT * FROM user_download WHERE series_id = ? ORDER BY pos", [seriesId]).map(dlRow)
    }
    func allDownloads() throws -> [DlRow] { try db.all("SELECT * FROM user_download").map(dlRow) }
    func doneDownloads() throws -> [DlRow] { try db.all("SELECT * FROM user_download WHERE state = 'done'").map(dlRow) }
    func seriesIdsWithDownloads() throws -> [String] {
        try db.all("SELECT DISTINCT series_id FROM user_download").map { $0.str("series_id") }
    }
    func doneEpisodeIds(_ seriesId: String) throws -> [String] {
        try db.all("SELECT episode_id FROM user_download WHERE series_id = ? AND state = 'done' ORDER BY pos", [seriesId]).map {
            $0.str("episode_id")
        }
    }

    func loadLibrary() throws -> [LibrarySeries] {
        try db.all(
            """
            SELECT d.series_id AS series_id, COALESCE(s.title, max(d.series_title)) AS series_title, s.cover_path AS cover_path,
                   count(*) AS n, sum(d.state = 'done') AS done, sum(d.state = 'paused') AS paused, min(d.requested_at) AS first_requested
            FROM user_download d LEFT JOIN catalog_series s ON s.id = d.series_id
            GROUP BY d.series_id ORDER BY first_requested DESC
            """
        ).map {
            LibrarySeries(
                seriesId: $0.str("series_id"), seriesTitle: $0.str("series_title"), n: Int($0.int("n")), done: Int($0.int("done")),
                paused: Int($0.int("paused")), firstRequested: $0.int("first_requested"), coverPath: $0.str("cover_path"))
        }
    }

    func loadLibraryEpisodes(_ seriesId: String) throws -> [LibraryEpisode] {
        try db.all(
            """
            SELECT d.episode_id, d.series_id, COALESCE(s.title, d.series_title) AS series_title, COALESCE(e.title, d.episode_title) AS episode_title,
                   d.pos, d.audio_path, d.local_file, d.state, d.retries, d.requested_at, d.bytes, d.total, d.validator,
                   p.position, p.duration, p.completed
            FROM user_download d
            LEFT JOIN user_progress p ON p.episode_id = d.episode_id
            LEFT JOIN catalog_series s ON s.id = d.series_id
            LEFT JOIN catalog_episode e ON e.id = d.episode_id
            WHERE d.series_id = ? ORDER BY d.pos
            """, [seriesId]
        ).map { LibraryEpisode(row: dlRow($0), progress: prog($0)) }
    }

    func seriesCoverPath(_ seriesId: String) -> String? {
        (try? db.first("SELECT cover_path FROM catalog_series WHERE id = ?", [seriesId]))??.optStr("cover_path")
    }
}
