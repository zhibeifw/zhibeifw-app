package com.zhibeifw.app

import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SiteUpdateTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun updateAcceptsOnlyNewerSignedArchiveOfThisAppAndAdvertisedVersion() {
        val installed = context.packageManager.getPackageInfo(context.packageName, 0)
        val version = requireNotNull(installed.versionName)
        val archive = File(context.applicationInfo.sourceDir)
        val manager = context.packageManager
        assertTrue(manager.isUpdateFor(archive, context.packageName, version, installed.longVersionCode - 1))
        assertFalse(manager.isUpdateFor(archive, context.packageName, version, installed.longVersionCode))
        assertFalse(manager.isUpdateFor(archive, context.packageName, "1.0.0", installed.longVersionCode - 1))
        assertFalse(manager.isUpdateFor(archive, "another.package", version, installed.longVersionCode - 1))
    }
}
