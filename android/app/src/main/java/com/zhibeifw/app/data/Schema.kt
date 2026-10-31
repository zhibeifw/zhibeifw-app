package com.zhibeifw.app.data

import android.database.sqlite.SQLiteDatabase
import android.util.Log
import java.io.File

// 一个库，两组表。表结构与 v1.0、iOS Schema.swift 完全一致。已发布的迁移不许改，只能在末尾追加。

class Migration(val name: String, val up: (Db) -> Unit)

object Schema {
    val user = listOf(
        Migration("v1 初始：播放进度、收藏、下载记录") { db ->
            db.exec(
                """
            CREATE TABLE user_progress (
              episode_id  TEXT PRIMARY KEY, series_id TEXT NOT NULL, position REAL NOT NULL DEFAULT 0, duration REAL NOT NULL DEFAULT 0,
              completed INTEGER NOT NULL DEFAULT 0, hidden INTEGER NOT NULL DEFAULT 0, last_played INTEGER NOT NULL, updated INTEGER NOT NULL
            );
            CREATE INDEX idx_progress_recent ON user_progress(hidden, last_played);
            CREATE INDEX idx_progress_series ON user_progress(series_id);
            CREATE TABLE user_favorite (series_id TEXT PRIMARY KEY, added INTEGER NOT NULL);
            CREATE INDEX idx_favorite_added ON user_favorite(added);
            CREATE TABLE user_download (
              episode_id TEXT PRIMARY KEY, series_id TEXT NOT NULL, series_title TEXT NOT NULL, episode_title TEXT NOT NULL,
              pos INTEGER NOT NULL, audio_path TEXT NOT NULL, local_file TEXT, state TEXT NOT NULL,
              retries INTEGER NOT NULL DEFAULT 0, requested_at INTEGER NOT NULL
            );
            CREATE INDEX idx_download_series ON user_download(series_id, pos);
            CREATE INDEX idx_download_requested ON user_download(requested_at)
            """
            )
        },
        Migration("v2 下载记录：断点续传") { db ->
            db.exec(
                """
            ALTER TABLE user_download ADD COLUMN bytes INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE user_download ADD COLUMN total INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE user_download ADD COLUMN validator TEXT
            """
            )
        },
        Migration("v3 收藏与播放记录自带显示信息") { db ->
            db.exec(
                """
            ALTER TABLE user_favorite ADD COLUMN series_title TEXT NOT NULL DEFAULT '';
            ALTER TABLE user_favorite ADD COLUMN cover_path TEXT NOT NULL DEFAULT '';
            ALTER TABLE user_progress ADD COLUMN series_title TEXT NOT NULL DEFAULT '';
            ALTER TABLE user_progress ADD COLUMN episode_title TEXT NOT NULL DEFAULT '';
            ALTER TABLE user_progress ADD COLUMN cover_path TEXT NOT NULL DEFAULT ''
            """
            )
        },
    )

    val catalog = listOf(
        Migration("v1 初始") { db ->
            db.exec(
                """
            CREATE TABLE catalog_category (id TEXT PRIMARY KEY, name TEXT NOT NULL, pos INTEGER NOT NULL);
            CREATE TABLE catalog_series (id TEXT PRIMARY KEY, title TEXT NOT NULL, title_norm TEXT NOT NULL, category_id TEXT NOT NULL,
              cover_path TEXT NOT NULL, status TEXT NOT NULL, pos INTEGER NOT NULL, description TEXT);
            CREATE INDEX idx_series_category ON catalog_series(category_id, pos);
            CREATE INDEX idx_series_pos ON catalog_series(pos);
            CREATE TABLE catalog_episode (id TEXT PRIMARY KEY, series_id TEXT NOT NULL, title TEXT NOT NULL, audio_path TEXT NOT NULL, pos INTEGER NOT NULL);
            CREATE INDEX idx_episode_series ON catalog_episode(series_id, pos);
            CREATE TABLE catalog_home_ongoing (pos INTEGER PRIMARY KEY, series_id TEXT NOT NULL);
            CREATE TABLE catalog_home_featured (pos INTEGER PRIMARY KEY, title TEXT NOT NULL, series_id TEXT NOT NULL);
            CREATE TABLE catalog_sync (path TEXT PRIMARY KEY, etag TEXT NOT NULL)
            """
            )
        },
        Migration("v2 主页分类行") { db -> db.exec("CREATE TABLE catalog_home_category (category_id TEXT NOT NULL, pos INTEGER NOT NULL, series_id TEXT NOT NULL, PRIMARY KEY (category_id, pos))") },
        Migration("v3 集的总时长") { db -> db.exec("ALTER TABLE catalog_episode ADD COLUMN duration INTEGER; DELETE FROM catalog_sync") },
        Migration("v4 分类的 icon、color") { db -> db.exec("ALTER TABLE catalog_category ADD COLUMN icon TEXT; ALTER TABLE catalog_category ADD COLUMN color TEXT; DELETE FROM catalog_sync WHERE path = 'index.json'") },
        Migration("v5 单文件目录") { db -> db.exec("ALTER TABLE catalog_series ADD COLUMN episodes_hash TEXT; DROP TABLE IF EXISTS catalog_home_ongoing; DROP TABLE IF EXISTS catalog_home_category; DELETE FROM catalog_sync") },
        Migration("v6 只写变了的课") { db -> db.exec("ALTER TABLE catalog_series ADD COLUMN series_sig TEXT; ALTER TABLE catalog_series ADD COLUMN episodes_sig TEXT") },
        Migration("v7 课程 updated_at") { db -> db.exec("ALTER TABLE catalog_series ADD COLUMN updated_at INTEGER; DELETE FROM catalog_sync WHERE path = 'index.json'") },
    )

    val userTables = listOf("user_progress", "user_favorite", "user_download")
}

data class MigrateResult(
    val userVersion: Int,
    val catalogVersion: Int,
    val userTooNew: Boolean,
    val catalogTooNew: Boolean,
    val catalogRebuilt: Boolean
)

object Migrator {
    private val CATALOG_TABLE_RE = Regex("^catalog_[a-z_]+$")

    /** 用户表升级失败抛出；目录表升级失败整体重建（保留“已初始化”标记）。 */
    fun migrate(
        db: Db, user: List<Migration> = Schema.user, catalog: List<Migration> = Schema.catalog,
        beforeUserMigration: ((Int, Int) -> Unit)? = null
    ): MigrateResult {
        db.exec("CREATE TABLE IF NOT EXISTS catalog_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        val uv = db.userVersion
        var userVersion = uv
        if (uv <= user.size) {
            if (uv in 1 until user.size && beforeUserMigration != null) {
                try {
                    beforeUserMigration(uv, user.size)
                } catch (e: Exception) {
                    Log.w("Migrator", "升级前备份失败（不影响升级）", e)
                }
            }
            for (i in uv until user.size) {
                db.transaction {
                    user[i].up(db)
                    db.userVersion = i + 1
                }
                userVersion = i + 1
            }
        }
        val cv = db.first("SELECT value FROM catalog_meta WHERE key = 'schema'")?.str("value")
            ?.toIntOrNull() ?: 0
        var catalogVersion = cv
        var rebuilt = false
        if (cv <= catalog.size) {
            try {
                for (i in cv until catalog.size) {
                    db.transaction {
                        catalog[i].up(db)
                        db.run(
                            "INSERT OR REPLACE INTO catalog_meta (key, value) VALUES ('schema', ?)",
                            (i + 1).toString()
                        )
                    }
                    catalogVersion = i + 1
                }
            } catch (e: Exception) {
                Log.w("Migrator", "目录表升级失败，整体重建", e)
                catalogVersion = rebuildCatalog(db, catalog)
                rebuilt = true
            }
        }
        return MigrateResult(
            userVersion,
            catalogVersion,
            uv > user.size,
            cv > catalog.size,
            rebuilt
        )
    }

    fun rebuildCatalog(db: Db, catalog: List<Migration>): Int {
        db.transaction {
            val names =
                db.all("SELECT name FROM sqlite_master WHERE type = 'table' AND name != 'catalog_meta'")
                    .map { it.str("name") }
            for (n in names) if (CATALOG_TABLE_RE.matches(n)) db.exec("DROP TABLE IF EXISTS \"$n\"") // 名字已校验
            db.run("DELETE FROM catalog_meta WHERE key = 'schema'")
        }
        var v = 0
        for (i in catalog.indices) {
            db.transaction {
                catalog[i].up(db)
                db.run(
                    "INSERT OR REPLACE INTO catalog_meta (key, value) VALUES ('schema', ?)",
                    (i + 1).toString()
                )
            }
            v = i + 1
        }
        return v
    }

    /**
     * 升级用户表前，把三张用户表复制到备份文件（覆盖旧备份）。
     * Android 的库开着 WAL，不能 ATTACH，所以单独打开备份文件，按主库的建表语句建表、逐行复制（参数绑定）。
     */
    fun backupUserTables(db: Db, path: File) {
        path.parentFile?.mkdirs()
        path.delete()
        val bak = SQLiteDatabase.openOrCreateDatabase(path, null)
        try {
            bak.beginTransaction()
            try {
                for (t in Schema.userTables) {
                    val ddl = db.first(
                        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
                        t
                    )?.optStr("sql") ?: continue
                    bak.execSQL(ddl) // 来自主库自己的建表语句（固定常量建的表）
                    for (r in db.all("SELECT * FROM $t")) { // 表名是固定常量
                        val cols = r.values.keys.toList()
                        val st = bak.compileStatement(
                            "INSERT INTO $t (${cols.joinToString(",")}) VALUES (${
                                cols.joinToString(",") { "?" }
                            })"
                        )
                        cols.forEachIndexed { i, c ->
                            when (val v = r.values[c]) {
                                null -> st.bindNull(i + 1)
                                is Long -> st.bindLong(i + 1, v)
                                is Double -> st.bindDouble(i + 1, v)
                                else -> st.bindString(i + 1, v.toString())
                            }
                        }
                        st.executeInsert()
                        st.close()
                    }
                }
                bak.setTransactionSuccessful()
            } finally {
                bak.endTransaction()
            }
        } finally {
            bak.close()
        }
    }
}
