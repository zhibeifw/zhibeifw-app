package com.zhibeifw.app

import android.app.DownloadManager as AndroidDownloads
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.zhibeifw.app.core.fileKey
import com.zhibeifw.app.download.SystemDownloader
import kotlinx.coroutines.runBlocking
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SystemDownloaderDeviceTest {
    /** App 重启后，系统里还在排队、没开始下的那一集也要认得出（这时系统给的本地地址是空的） */
    @Test
    fun legacyQueuedDownloadRecognizedAfterRestart() = runBlocking {
        assertQueuedDownloadRecognized("")
    }

    @Test
    fun queuedDownloadWithUniqueFilenameRecognizedAfterRestart() = runBlocking {
        assertQueuedDownloadRecognized(".${UUID.randomUUID()}")
    }

    private suspend fun assertQueuedDownloadRecognized(suffix: String) {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val dm = ctx.getSystemService(AndroidDownloads::class.java)
        val id = "测试/排队中"
        // 要求设备空闲：测试期间系统不会开始下，一直停在排队
        val sysId = dm.enqueue(
            AndroidDownloads.Request(Uri.parse("https://example.invalid/a.mp3"))
                .setRequiresDeviceIdle(true)
                .setDestinationInExternalFilesDir(ctx, SystemDownloader.DIR, fileKey(id) + suffix + ".part")
        )
        try {
            dm.query(AndroidDownloads.Query().setFilterById(sysId)).use { c ->
                c.moveToFirst()
                assertEquals(AndroidDownloads.STATUS_PENDING, c.getInt(c.getColumnIndexOrThrow(AndroidDownloads.COLUMN_STATUS)))
            }
            // 新建一个，相当于 App 重启后：内存里没有任何系统编号
            assertEquals(setOf(id), SystemDownloader(ctx).activeIds(listOf(id)))
        } finally {
            dm.remove(sysId)
        }
    }
}
