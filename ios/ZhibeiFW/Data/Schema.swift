import Foundation

// 一个库，两组表：catalog_* 目录表（缓存，可随时重建），user_* 用户表（要认真迁移）。
// 表结构与 v1.0 完全一致，以便覆盖安装后直接接管 v1.0 的数据库。
// 规则：已发布的迁移不许改，只能在末尾追加新的一步。

struct Migration {
    let name: String
    let up: (SQLiteDB) throws -> Void
}

enum Schema {
    static let user: [Migration] = [
        Migration(name: "v1 初始：播放进度、收藏、下载记录") { db in
            try db.exec(
                """
                CREATE TABLE user_progress (
                  episode_id  TEXT PRIMARY KEY,
                  series_id   TEXT NOT NULL,
                  position    REAL NOT NULL DEFAULT 0,
                  duration    REAL NOT NULL DEFAULT 0,
                  completed   INTEGER NOT NULL DEFAULT 0,
                  hidden      INTEGER NOT NULL DEFAULT 0,
                  last_played INTEGER NOT NULL,
                  updated     INTEGER NOT NULL
                );
                CREATE INDEX idx_progress_recent ON user_progress(hidden, last_played);
                CREATE INDEX idx_progress_series ON user_progress(series_id);
                CREATE TABLE user_favorite (
                  series_id TEXT PRIMARY KEY,
                  added     INTEGER NOT NULL
                );
                CREATE INDEX idx_favorite_added ON user_favorite(added);
                CREATE TABLE user_download (
                  episode_id    TEXT PRIMARY KEY,
                  series_id     TEXT NOT NULL,
                  series_title  TEXT NOT NULL,
                  episode_title TEXT NOT NULL,
                  pos           INTEGER NOT NULL,
                  audio_path    TEXT NOT NULL,
                  local_file    TEXT,
                  state         TEXT NOT NULL,
                  retries       INTEGER NOT NULL DEFAULT 0,
                  requested_at  INTEGER NOT NULL
                );
                CREATE INDEX idx_download_series ON user_download(series_id, pos);
                CREATE INDEX idx_download_requested ON user_download(requested_at);
                """)
        },
        Migration(name: "v2 下载记录：断点续传") { db in
            try db.exec(
                """
                ALTER TABLE user_download ADD COLUMN bytes INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE user_download ADD COLUMN total INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE user_download ADD COLUMN validator TEXT;
                """)
        },
        Migration(name: "v3 收藏与播放记录自带显示信息") { db in
            try db.exec(
                """
                ALTER TABLE user_favorite ADD COLUMN series_title TEXT NOT NULL DEFAULT '';
                ALTER TABLE user_favorite ADD COLUMN cover_path TEXT NOT NULL DEFAULT '';
                ALTER TABLE user_progress ADD COLUMN series_title TEXT NOT NULL DEFAULT '';
                ALTER TABLE user_progress ADD COLUMN episode_title TEXT NOT NULL DEFAULT '';
                ALTER TABLE user_progress ADD COLUMN cover_path TEXT NOT NULL DEFAULT '';
                """)
        },
    ]

    static let catalog: [Migration] = [
        Migration(name: "v1 初始") { db in
            try db.exec(
                """
                CREATE TABLE catalog_category (id TEXT PRIMARY KEY, name TEXT NOT NULL, pos INTEGER NOT NULL);
                CREATE TABLE catalog_series (
                  id TEXT PRIMARY KEY, title TEXT NOT NULL, title_norm TEXT NOT NULL, category_id TEXT NOT NULL,
                  cover_path TEXT NOT NULL, status TEXT NOT NULL, pos INTEGER NOT NULL, description TEXT
                );
                CREATE INDEX idx_series_category ON catalog_series(category_id, pos);
                CREATE INDEX idx_series_pos ON catalog_series(pos);
                CREATE TABLE catalog_episode (id TEXT PRIMARY KEY, series_id TEXT NOT NULL, title TEXT NOT NULL, audio_path TEXT NOT NULL, pos INTEGER NOT NULL);
                CREATE INDEX idx_episode_series ON catalog_episode(series_id, pos);
                CREATE TABLE catalog_home_ongoing (pos INTEGER PRIMARY KEY, series_id TEXT NOT NULL);
                CREATE TABLE catalog_home_featured (pos INTEGER PRIMARY KEY, title TEXT NOT NULL, series_id TEXT NOT NULL);
                CREATE TABLE catalog_sync (path TEXT PRIMARY KEY, etag TEXT NOT NULL);
                """)
        },
        Migration(name: "v2 主页分类行") { db in
            try db.exec(
                "CREATE TABLE catalog_home_category (category_id TEXT NOT NULL, pos INTEGER NOT NULL, series_id TEXT NOT NULL, PRIMARY KEY (category_id, pos));"
            )
        },
        Migration(name: "v3 集的总时长") { db in
            try db.exec("ALTER TABLE catalog_episode ADD COLUMN duration INTEGER; DELETE FROM catalog_sync;")
        },
        Migration(name: "v4 分类的 icon、color") { db in
            try db.exec(
                "ALTER TABLE catalog_category ADD COLUMN icon TEXT; ALTER TABLE catalog_category ADD COLUMN color TEXT; DELETE FROM catalog_sync WHERE path = 'index.json';"
            )
        },
        Migration(name: "v5 单文件目录") { db in
            try db.exec(
                "ALTER TABLE catalog_series ADD COLUMN episodes_hash TEXT; DROP TABLE IF EXISTS catalog_home_ongoing; DROP TABLE IF EXISTS catalog_home_category; DELETE FROM catalog_sync;"
            )
        },
        Migration(name: "v6 只写变了的课") { db in
            try db.exec("ALTER TABLE catalog_series ADD COLUMN series_sig TEXT; ALTER TABLE catalog_series ADD COLUMN episodes_sig TEXT;")
        },
        Migration(name: "v7 课程 updated_at") { db in
            try db.exec("ALTER TABLE catalog_series ADD COLUMN updated_at INTEGER; DELETE FROM catalog_sync WHERE path = 'index.json';")
        },
    ]

    static let userTables = ["user_progress", "user_favorite", "user_download"]
}

struct MigrateResult: Equatable {
    var userVersion: Int
    var catalogVersion: Int
    var userTooNew: Bool
    var catalogTooNew: Bool
    var catalogRebuilt: Bool
}

enum Migrator {
    /// 打开数据库后调用。用户表、目录表各自一步步升级，每一步一个事务。
    /// 用户表升级失败抛出（调用方提示用户重启再试，不拿这个库继续用）；目录表升级失败就整体重建（保留“已初始化”标记）。
    static func migrate(
        _ db: SQLiteDB, user: [Migration] = Schema.user, catalog: [Migration] = Schema.catalog,
        beforeUserMigration: ((Int, Int) throws -> Void)? = nil
    ) throws -> MigrateResult {
        try db.exec("CREATE TABLE IF NOT EXISTS catalog_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        let uv = db.userVersion
        var userVersion = uv
        if uv <= user.count {
            if uv > 0 && uv < user.count, let b = beforeUserMigration {
                do { try b(uv, user.count) } catch { NSLog("升级前备份用户数据失败（不影响升级）：\(error)") }
            }
            for i in uv..<user.count {
                try db.transaction {
                    try user[i].up(db)
                    try db.setUserVersion(i + 1)
                }
                userVersion = i + 1
            }
        }
        let cv = Int(try db.first("SELECT value FROM catalog_meta WHERE key = 'schema'")?.str("value") ?? "0") ?? 0
        var catalogVersion = cv
        var rebuilt = false
        if cv <= catalog.count {
            do {
                for i in cv..<catalog.count {
                    try db.transaction {
                        try catalog[i].up(db)
                        try db.run("INSERT OR REPLACE INTO catalog_meta (key, value) VALUES ('schema', ?)", [String(i + 1)])
                    }
                    catalogVersion = i + 1
                }
            } catch {
                NSLog("目录表升级失败，整体重建：\(error)")
                catalogVersion = try rebuildCatalog(db, catalog)
                rebuilt = true
            }
        }
        return MigrateResult(
            userVersion: userVersion, catalogVersion: catalogVersion, userTooNew: uv > user.count,
            catalogTooNew: cv > catalog.count, catalogRebuilt: rebuilt)
    }

    /// 目录表整体删掉重建；保留 catalog_meta（里面有“已初始化”标记）。
    static func rebuildCatalog(_ db: SQLiteDB, _ catalog: [Migration]) throws -> Int {
        try db.transaction {
            let names = try db.all("SELECT name FROM sqlite_master WHERE type = 'table' AND name != 'catalog_meta'").map { $0.str("name") }
            for n in names where n.range(of: "^catalog_[a-z_]+$", options: .regularExpression) != nil {
                try db.exec("DROP TABLE IF EXISTS \"\(n)\"")  // 名字已校验：只是我们自己建的 catalog_ 表
            }
            try db.run("DELETE FROM catalog_meta WHERE key = 'schema'")
        }
        var v = 0
        for i in 0..<catalog.count {
            try db.transaction {
                try catalog[i].up(db)
                try db.run("INSERT OR REPLACE INTO catalog_meta (key, value) VALUES ('schema', ?)", [String(i + 1)])
            }
            v = i + 1
        }
        return v
    }

    /// 升级用户表前，把三张用户表复制到备份文件（覆盖旧备份）。
    static func backupUserTables(_ db: SQLiteDB, to path: String) throws {
        try db.run("ATTACH DATABASE ? AS bak", [path])
        defer { try? db.exec("DETACH DATABASE bak") }
        for t in Schema.userTables {
            try db.exec("DROP TABLE IF EXISTS bak.\(t); CREATE TABLE bak.\(t) AS SELECT * FROM main.\(t);")  // 表名是固定常量
        }
    }
}
