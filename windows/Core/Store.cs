using System.Globalization;

namespace Zhibei;

public record SavedCourse(string Id, string Title, string Cover);
public record SavedEpisode(string CourseId, string CourseTitle, string Id, string Title, Progress Progress, string Cover);

public sealed class Store : IDisposable
{
    const string CatalogQuery = "SELECT raw,etag FROM catalog_index WHERE id=1";
    readonly Database db;
    static long Now => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    static double Number(string s) => double.Parse(s, CultureInfo.InvariantCulture);
    public Store(string file) : this(file, out _) { }

    public Store(string file, out (string Raw, string Tag) cachedCatalog)
    {
        db = OpenDatabase(file);
        try { cachedCatalog = ReadCatalog(); }
        catch (DatabaseException e) when (e.IsCorrupt)
        {
            db.Dispose();
            RecoverCatalog(file);
            db = OpenDatabase(file);
            try { cachedCatalog = ReadCatalog(); }
            catch { db.Dispose(); throw; }
        }
        catch { db.Dispose(); throw; }
    }

    static Database OpenDatabase(string file)
    {
        var db = new Database(file);
        try
        {
            var version = db.Query("PRAGMA user_version")[0][0];
            if (version == "1") return db;
            if (version != "0") throw new IOException("本机资料来自更新的版本，请使用新版智悲佛网打开。");
            db.Query("BEGIN IMMEDIATE");
            db.Query("CREATE TABLE IF NOT EXISTS catalog_index(id INTEGER PRIMARY KEY, raw TEXT NOT NULL, etag TEXT NOT NULL)");
            db.Query("CREATE TABLE IF NOT EXISTS catalog_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)");
            db.Query("CREATE TABLE IF NOT EXISTS user_favorite(series_id TEXT PRIMARY KEY, added INTEGER NOT NULL, series_title TEXT NOT NULL, cover_path TEXT NOT NULL)");
            db.Query("""
                CREATE TABLE IF NOT EXISTS user_progress(episode_id TEXT PRIMARY KEY, series_id TEXT NOT NULL,
                  position REAL NOT NULL, duration REAL NOT NULL, completed INTEGER NOT NULL, hidden INTEGER NOT NULL,
                  last_played INTEGER NOT NULL, updated INTEGER NOT NULL, series_title TEXT NOT NULL, episode_title TEXT NOT NULL, cover_path TEXT NOT NULL)
                """);
            db.Query("CREATE INDEX IF NOT EXISTS idx_progress_recent ON user_progress(hidden,last_played)");
            db.Query("PRAGMA user_version=1");
            db.Query("COMMIT");
            return db;
        }
        catch { db.Dispose(); throw; }
    }

    static void RecoverCatalog(string file)
    {
        using var recoveryLock = new FileStream(file + ".recovery", FileMode.OpenOrCreate,
            FileAccess.ReadWrite, FileShare.None, 1, FileOptions.DeleteOnClose);
        using (var current = OpenDatabase(file))
        {
            try
            {
                current.Query(CatalogQuery);
                return;
            }
            catch (DatabaseException e) when (e.IsCorrupt) { }
        }

        string backup = file + $".damaged-{Guid.NewGuid():N}";
        string snapshot = backup + ".copy";
        string replacement = backup + ".new";
        try
        {
            // Allow atomic replacement while preventing writes to the source during recovery.
            using var original = File.Open(file, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
            if (File.Exists(file + "-journal") || File.Exists(file + "-wal"))
                throw new IOException("本机数据库有未完成的写入，请关闭智悲佛网后重新打开。");
            using (var copy = File.Create(snapshot)) original.CopyTo(copy);
            using (var rebuilt = OpenDatabase(replacement))
            {
                rebuilt.Query("ATTACH DATABASE ? AS damaged", snapshot);
                rebuilt.Query("BEGIN IMMEDIATE");
                rebuilt.Query("INSERT INTO main.catalog_meta SELECT * FROM damaged.catalog_meta");
                rebuilt.Query("INSERT INTO main.user_favorite SELECT * FROM damaged.user_favorite");
                rebuilt.Query("INSERT INTO main.user_progress SELECT * FROM damaged.user_progress");
                rebuilt.Query("COMMIT");
                if (rebuilt.Query("PRAGMA main.integrity_check")[0][0] != "ok")
                    throw new IOException("恢复后的本机数据库未通过校验。");
            }
            File.Replace(replacement, file, backup);
        }
        catch (IOException e)
        {
            throw new IOException("无法安全恢复本机资料，原数据库已保留。", e);
        }
        finally
        {
            File.Delete(snapshot);
            File.Delete(replacement);
        }
    }

    public (string Raw, string Tag) ReadCatalog() =>
        db.Query(CatalogQuery).FirstOrDefault() is {} r ? (r[0], r[1]) : ("", "");
    public void CacheCatalog(string raw, string tag) =>
        db.Query("INSERT OR REPLACE INTO catalog_index VALUES(1,?,?)", raw, tag);
    public string Setting(string key) => db.Query("SELECT value FROM catalog_meta WHERE key=?", key).FirstOrDefault()?[0] ?? "";
    public void Set(string key, string value) => db.Query("INSERT OR REPLACE INTO catalog_meta VALUES(?,?)", key, value);
    public List<SavedCourse> Favorites() => db.Query("SELECT series_id,series_title,cover_path FROM user_favorite ORDER BY added DESC")
        .Select(r => new SavedCourse(r[0], string.IsNullOrWhiteSpace(r[1]) ? SavedCourseTitle(r[0]) ?? "已下架的课程" : r[1], r[2])).ToList();
    public string? SavedCourseTitle(string id)
    {
        var title = db.Query("""
            SELECT COALESCE(
                (SELECT series_title FROM user_favorite WHERE series_id=?1 AND trim(series_title)<>''),
                (SELECT series_title FROM user_progress WHERE series_id=?1 AND trim(series_title)<>'' ORDER BY updated DESC LIMIT 1)
            )
            """, id).Single()[0];
        return string.IsNullOrWhiteSpace(title) ? null : title;
    }
    public bool IsFavorite(string id) => db.Query("SELECT 1 FROM user_favorite WHERE series_id=?", id).Count > 0;
    public void RemoveFavorite(string id) => db.Query("DELETE FROM user_favorite WHERE series_id=?", id);
    public void Favorite(Course c, bool enabled)
    {
        if (enabled) db.Query("INSERT OR IGNORE INTO user_favorite VALUES(?,?,?,?)", c.Id, Now, c.Title, c.Cover);
        else RemoveFavorite(c.Id);
    }
    public List<SavedEpisode> Recent() => db.Query("""
        SELECT series_id,series_title,episode_id,episode_title,position,duration,completed,cover_path FROM user_progress
        WHERE hidden=0 ORDER BY last_played DESC LIMIT 500
        """).Select(r => new SavedEpisode(r[0], r[1], r[2], r[3], new(Number(r[4]), Number(r[5]), r[6] == "1"), r[7])).ToList();
    public Progress? ReadProgress(string id) =>
        db.Query("SELECT position,duration,completed FROM user_progress WHERE episode_id=?", id).FirstOrDefault() is {} r
            ? new(Number(r[0]), Number(r[1]), r[2] == "1") : null;
    public Dictionary<string, Progress> CourseProgress(string id) =>
        db.Query("SELECT episode_id,position,duration,completed FROM user_progress WHERE series_id=?", id)
            .ToDictionary(r => r[0], r => new Progress(Number(r[1]), Number(r[2]), r[3] == "1"));
    public void ClearRecent() => db.Query("UPDATE user_progress SET hidden=1 WHERE hidden=0");

    public void Save(Course c, Episode e, double position, double duration, bool done, bool showInRecent)
    {
        long now = Now;
        db.Query("""
            INSERT INTO user_progress VALUES(?,?,?,?,?,0,?,?,?,?,?)
            ON CONFLICT(episode_id) DO UPDATE SET position=excluded.position,
              duration=CASE WHEN excluded.duration>0 THEN excluded.duration ELSE user_progress.duration END,
              completed=excluded.completed,hidden=CASE WHEN ? THEN 0 ELSE user_progress.hidden END,
              last_played=excluded.last_played,updated=excluded.updated,series_id=excluded.series_id,
              series_title=excluded.series_title,episode_title=excluded.episode_title,cover_path=excluded.cover_path
            """, e.Id, c.Id, done ? 0 : position, duration, done, now, now, c.Title, e.Title, c.Cover, showInRecent);
    }
    public void Mark(Course c, Episode e, bool done) => db.Query("""
        INSERT INTO user_progress VALUES(?,?,0,?,?,1,0,?,?,?,?)
        ON CONFLICT(episode_id) DO UPDATE SET position=0,completed=excluded.completed,updated=excluded.updated
        """, e.Id, c.Id, e.Duration, done, Now, c.Title, e.Title, c.Cover);
    public void Dispose() => db.Dispose();
}
