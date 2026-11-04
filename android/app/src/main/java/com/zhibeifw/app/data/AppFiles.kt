package com.zhibeifw.app.data

import android.content.Context
import com.zhibeifw.app.core.fileKey
import java.io.File

/** App 的文件位置，和 v1.0 完全一样，覆盖安装后直接接着用。 */
class AppFiles(val filesDir: File, val cacheDir: File) {
    constructor(ctx: Context) : this(ctx.filesDir, ctx.cacheDir)

    val dbDir get() = File(filesDir, "SQLite")
    val dbPath get() = File(dbDir, "zhibeifw.db")
    val v1KVPath get() = File(dbDir, "ExpoSQLiteStorage")
    val audioDir get() = File(filesDir, "audio")
    val coversDir get() = File(filesDir, "covers")
    val partDir get() = File(cacheDir, "dl-part")
    val backupPath get() = File(File(filesDir, "backup"), "user-before-migrate.db")

    fun prepare() {
        listOf(dbDir, audioDir, coversDir, partDir, backupPath.parentFile!!).forEach { it.mkdirs() }
    }

    fun coverFile(seriesId: String) = File(coversDir, fileKey(seriesId) + ".jpg")

    /** 下载完成后的本地文件（相对 App 文件目录，如 audio/h_xxx.mp3），数据库里存相对路径。 */
    fun finalRelative(episodeId: String, audioPath: String): String {
        val ext = audioPath.substringAfterLast('.', "").lowercase()
        val safe = if (Regex("^[a-z0-9]{1,5}$").matches(ext)) ext else "mp3"
        return "audio/" + fileKey(episodeId) + "." + safe
    }

    fun absolute(relative: String) = File(filesDir, relative)

    sealed class LocalAudio {
        object None : LocalAudio();
        data class Found(val file: File) : LocalAudio();
        object Missing : LocalAudio()
    }

    /** 这一集已下载的本地文件：文件真的在才返回；记录在但文件丢了返回 Missing。 */
    fun localAudio(episodeId: String, store: Store): LocalAudio {
        val r = store.getDownload(episodeId) ?: return LocalAudio.None
        if (r.state != com.zhibeifw.app.core.DlStatus.DONE || r.localFile == null) return LocalAudio.None
        val f = absolute(r.localFile)
        return if (f.exists()) LocalAudio.Found(f) else LocalAudio.Missing
    }
}
