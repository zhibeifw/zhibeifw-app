using System.Globalization;
using System.Runtime.InteropServices;

namespace Zhibei;

// Windows SDK 的 winsqlite3.dll 与公开的 SQLite C ABI 相同。
internal sealed class Database : IDisposable
{
    const string Lib = "winsqlite3";
    const int Row = 100, Done = 101;
    IntPtr db;

    [DllImport(Lib, CharSet = CharSet.Unicode, ExactSpelling = true)]
    static extern int sqlite3_open16(string path, out IntPtr db);
    [DllImport(Lib)] static extern int sqlite3_close(IntPtr db);
    [DllImport(Lib)] static extern int sqlite3_busy_timeout(IntPtr db, int milliseconds);
    [DllImport(Lib)] static extern IntPtr sqlite3_errmsg16(IntPtr db);
    [DllImport(Lib, CharSet = CharSet.Unicode, ExactSpelling = true)]
    static extern int sqlite3_prepare16_v2(IntPtr db, string sql, int bytes, out IntPtr stmt, IntPtr tail);
    [DllImport(Lib, CharSet = CharSet.Unicode, ExactSpelling = true)]
    static extern int sqlite3_bind_text16(IntPtr stmt, int index, string value, int bytes, IntPtr destructor);
    [DllImport(Lib)] static extern int sqlite3_bind_double(IntPtr stmt, int index, double value);
    [DllImport(Lib)] static extern int sqlite3_bind_int64(IntPtr stmt, int index, long value);
    [DllImport(Lib)] static extern int sqlite3_step(IntPtr stmt);
    [DllImport(Lib)] static extern IntPtr sqlite3_column_text16(IntPtr stmt, int index);
    [DllImport(Lib)] static extern int sqlite3_column_count(IntPtr stmt);
    [DllImport(Lib)] static extern int sqlite3_finalize(IntPtr stmt);

    internal Database(string path)
    {
        try
        {
            Check(sqlite3_open16(path, out db));
            Check(sqlite3_busy_timeout(db, 3000));
        }
        catch { Dispose(); throw; }
    }

    void Check(int code)
    {
        if (code != 0) throw new DatabaseException(code, Marshal.PtrToStringUni(sqlite3_errmsg16(db)));
    }

    internal List<string[]> Query(string sql, params object[] values)
    {
        Check(sqlite3_prepare16_v2(db, sql, -1, out var statement, IntPtr.Zero));
        try
        {
            for (int i = 0; i < values.Length; i++)
            {
                int slot = i + 1;
                Check(values[i] switch {
                    string s => sqlite3_bind_text16(statement, slot, s, s.Length * 2, new IntPtr(-1)),
                    double n => sqlite3_bind_double(statement, slot, n),
                    _ => sqlite3_bind_int64(statement, slot, Convert.ToInt64(values[i], CultureInfo.InvariantCulture))
                });
            }
            List<string[]> rows = [];
            int code;
            while ((code = sqlite3_step(statement)) == Row)
            {
                string[] fields = new string[sqlite3_column_count(statement)];
                for (int i = 0; i < fields.Length; i++)
                    fields[i] = Marshal.PtrToStringUni(sqlite3_column_text16(statement, i)) ?? "";
                rows.Add(fields);
            }
            if (code != Done) Check(code);
            return rows;
        }
        finally { sqlite3_finalize(statement); }
    }

    public void Dispose()
    {
        if (db == IntPtr.Zero) return;
        sqlite3_close(db);
        db = IntPtr.Zero;
    }
}

internal sealed class DatabaseException(int code, string? detail) : IOException("无法读写本机数据库：" + detail)
{
    internal bool IsCorrupt => (code & 0xff) == 11; // SQLITE_CORRUPT
}
