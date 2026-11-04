package com.zhibeifw.app.data

import android.database.Cursor
import android.database.sqlite.SQLiteCursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteProgram

/**
 * 系统自带 SQLite（android.database.sqlite）的一层薄包装，与 iOS 的 SQLiteDB 同样的用法。
 * 不用 Room 管理用户表：Room 会校验表结构和 room_master_table，直接打开 v1.0 的库会报不一致。
 * 所有带输入的语句一律参数绑定，按类型绑定（不是全转成字符串）。
 */
class Row(val values: Map<String, Any?>) {
    fun str(k: String): String = optStr(k) ?: ""
    fun optStr(k: String): String? = when (val v = values[k]) {
        null -> null; is String -> v; is Double -> v.toString(); else -> v.toString()
    }

    fun int(k: String): Long = optInt(k) ?: 0
    fun optInt(k: String): Long? = when (val v = values[k]) {
        is Number -> v.toLong(); is String -> v.toLongOrNull(); else -> null
    }

    fun double(k: String): Double = optDouble(k) ?: 0.0
    fun optDouble(k: String): Double? = when (val v = values[k]) {
        is Number -> v.toDouble(); is String -> v.toDoubleOrNull(); else -> null
    }

    fun bool(k: String): Boolean = int(k) != 0L
}

class Db(val db: SQLiteDatabase) {
    companion object {
        fun open(path: String): Db {
            val d = SQLiteDatabase.openDatabase(
                path,
                null,
                SQLiteDatabase.OPEN_READWRITE or SQLiteDatabase.CREATE_IF_NECESSARY
            )
            d.enableWriteAheadLogging()
            return Db(d)
        }
    }

    private fun bind(p: SQLiteProgram, args: Array<out Any?>) {
        args.forEachIndexed { i, a ->
            val idx = i + 1
            when (a) {
                null -> p.bindNull(idx)
                is Boolean -> p.bindLong(idx, if (a) 1 else 0)
                is Int -> p.bindLong(idx, a.toLong())
                is Long -> p.bindLong(idx, a)
                is Double -> p.bindDouble(idx, a)
                is Float -> p.bindDouble(idx, a.toDouble())
                else -> p.bindString(idx, a.toString())
            }
        }
    }

    /** 只用于固定语句（建表、迁移），可以是用分号隔开的多条；绝不拼接外部输入。 */
    fun exec(sql: String) {
        for (stmt in sql.split(';')) {
            val s = stmt.lines().filterNot { it.trim().startsWith("--") }.joinToString("\n").trim()
            if (s.isNotEmpty()) db.execSQL(s)
        }
    }

    /** 执行一条带参数的语句，返回受影响的行数。 */
    fun run(sql: String, vararg args: Any?): Int {
        val st = db.compileStatement(sql)
        try {
            bind(st, args)
            return st.executeUpdateDelete()
        } finally {
            st.close()
        }
    }

    fun all(sql: String, vararg args: Any?): List<Row> {
        val factory = SQLiteDatabase.CursorFactory { _, driver, editTable, query ->
            bind(query, args)
            SQLiteCursor(driver, editTable, query)
        }
        val c = db.rawQueryWithFactory(factory, sql, null, "")
        c.use {
            val out = ArrayList<Row>(c.count)
            val names = c.columnNames
            while (c.moveToNext()) {
                val m = HashMap<String, Any?>(names.size)
                for (i in names.indices) {
                    m[names[i]] = when (c.getType(i)) {
                        Cursor.FIELD_TYPE_INTEGER -> c.getLong(i)
                        Cursor.FIELD_TYPE_FLOAT -> c.getDouble(i)
                        Cursor.FIELD_TYPE_NULL -> null
                        else -> c.getString(i)
                    }
                }
                out.add(Row(m))
            }
            return out
        }
    }

    fun first(sql: String, vararg args: Any?): Row? = all(sql, *args).firstOrNull()

    /** 事务：中途抛错整体回滚。可以嵌套。 */
    fun <T> transaction(body: () -> T): T {
        db.beginTransaction()
        try {
            val r = body()
            db.setTransactionSuccessful()
            return r
        } finally {
            db.endTransaction()
        }
    }

    var userVersion: Int
        get() = db.version
        set(v) {
            db.version = v
        }
}
