package com.zhibeifw.app

import android.content.Intent
import android.content.res.Configuration
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNotNull
import org.junit.Test

class DeviceModeTest {
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

    @Test
    fun televisionCapabilitiesFollowDeviceTypeRegardlessOfWidth() {
        for (tv in listOf(false, true)) {
            for (width in listOf(360, 960)) {
                val config = Configuration(context.resources.configuration)
                val type = if (tv) Configuration.UI_MODE_TYPE_TELEVISION else Configuration.UI_MODE_TYPE_NORMAL
                config.uiMode = (config.uiMode and Configuration.UI_MODE_TYPE_MASK.inv()) or type
                config.smallestScreenWidthDp = width
                val res = context.createConfigurationContext(config).resources
                assertEquals(tv, res.getBoolean(R.bool.is_television))
            }
        }
    }

    @Test
    fun oneInstalledPackageSupportsBothLauncherIntents() {
        for (category in listOf(Intent.CATEGORY_LAUNCHER, Intent.CATEGORY_LEANBACK_LAUNCHER)) {
            val launch = Intent(Intent.ACTION_MAIN).addCategory(category).setPackage(context.packageName)
            assertNotNull(context.packageManager.resolveActivity(launch, 0))
        }
    }
}
