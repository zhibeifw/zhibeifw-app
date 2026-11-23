package com.zhibeifw.app

import android.app.DownloadManager
import android.content.Context
import com.zhibeifw.app.core.compareVersions
import java.io.File

internal object UpdateDownloads {
    fun cleanupInstalledUpdate(context: Context) {
        val target = context.getSharedPreferences("apk_download", Context.MODE_PRIVATE).getString("version", null) ?: return
        if (compareVersions(target, BuildConfig.VERSION_NAME) != 1) discardDownload(context)
    }

    fun discardDownload(context: Context) {
        val prefs = context.getSharedPreferences("apk_download", Context.MODE_PRIVATE)
        if (prefs.contains("id")) runCatching {
            context.getSystemService(DownloadManager::class.java).remove(prefs.getLong("id", -1))
        }
        prefs.edit().clear().apply()
        File(context.cacheDir, "installer/update.apk").delete()
    }

}
