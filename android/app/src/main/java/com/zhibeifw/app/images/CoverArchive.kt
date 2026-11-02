package com.zhibeifw.app.images

import com.zhibeifw.app.data.AppFiles
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * 下载过的课，封面另存一份到本机（资料库离线显示、锁屏封面用；清除封面缓存不影响它）。
 * 取图复用封面加载器：同样的线路、超时、并发去重和磁盘缓存（与 iOS CoverArchive.swift 对应）。
 */
class CoverArchive(private val files: AppFiles, private val images: ImageLoader, private val scope: CoroutineScope) {
    fun save(seriesId: String, coverPath: String?) {
        val dest = files.coverFile(seriesId)
        if (coverPath.isNullOrEmpty() || dest.exists()) return
        scope.launch(Dispatchers.IO) {
            val src = images.originalFile(coverPath) ?: return@launch
            // 先拷到临时文件再改名：中途被关掉不会留下半张图（对账只清 .jpg，不会管它）
            val tmp = File(dest.path + ".tmp")
            runCatching { src.copyTo(tmp, overwrite = true) }.onFailure { tmp.delete(); return@launch }
            if (dest.exists() || !tmp.renameTo(dest)) tmp.delete()
        }
    }
}
