package com.zhibeifw.app

import android.content.ContextWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.zhibeifw.app.widget.*
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class WidgetStoreDeviceTest {
    @Test fun delayedSnapshotPreservesPauseAndChangedEpisode() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(base.cacheDir, "widget-test-${UUID.randomUUID()}")
        val context = object : ContextWrapper(base) { override fun getFilesDir() = directory }
        val item = WidgetItem("s", "课程", episodeId = "e", color = 0)
        val playing = WidgetNowPlaying(item, 30.0, 600.0, true, true)
        try {
            for (newState in listOf(playing.copy(playing = false), playing.copy(item = item.copy(episodeId = "next")))) {
                val old = WidgetSnapshot(nowPlaying = playing)
                WidgetStore.update(context) { old }
                WidgetStore.update(context) { it.copy(nowPlaying = newState) }
                WidgetStore.writePrepared(context, old.copy(latest = listOf(item)), old)
                val result = WidgetStore.read(context)
                assertEquals(newState, result.nowPlaying)
                assertEquals(listOf(item), result.latest)
            }
        } finally { directory.deleteRecursively() }
    }
    @Test fun concurrentUpdatesKeepEveryChange() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(base.cacheDir, "widget-test-${UUID.randomUUID()}")
        val context = object : ContextWrapper(base) { override fun getFilesDir() = directory }
        val pool = Executors.newFixedThreadPool(4)
        try {
            val futures = (0 until 40).map { i -> pool.submit {
                WidgetStore.update(context) { it.copy(latest = it.latest + WidgetItem("s$i", "课程", color = 0)) }
            } }
            futures.forEach { it.get() }
            assertEquals(40, WidgetStore.read(context).latest.size)
        } finally { pool.shutdownNow(); directory.deleteRecursively() }
    }
}
