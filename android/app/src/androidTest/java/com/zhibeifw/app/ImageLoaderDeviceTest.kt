package com.zhibeifw.app

import android.graphics.Bitmap
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.zhibeifw.app.images.ImageLoader
import com.zhibeifw.app.net.Network
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ImageLoaderDeviceTest {
    /** 有本地封面时取过一次，同步查内存要能命中（不再每次进页面重新读文件、解码） */
    @Test
    fun localCoverHitsMemory() = runBlocking {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val dir = File(ctx.cacheDir, "il-test-${System.nanoTime()}").apply { mkdirs() }
        try {
            val loader = ImageLoader(Network(ctx), File(dir, "cache"))
            val local = File(dir, "cover.png")
            local.outputStream().use {
                Bitmap.createBitmap(64, 36, Bitmap.Config.ARGB_8888).compress(Bitmap.CompressFormat.PNG, 100, it)
            }
            assertNull(loader.cached("c/s/cover.jpg", 320, local = true))
            assertNotNull(loader.load("c/s/cover.jpg", 320, local))
            assertNotNull(loader.cached("c/s/cover.jpg", 320, local = true))
        } finally {
            dir.deleteRecursively()
        }
    }
}
