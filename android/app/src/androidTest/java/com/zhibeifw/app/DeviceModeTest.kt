package com.zhibeifw.app

import android.content.Intent
import android.content.res.Configuration
import android.graphics.drawable.AdaptiveIconDrawable
import android.util.DisplayMetrics
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceModeTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun updateDestinationAndPermissionsMatchDistribution() {
        val site = BuildConfig.FLAVOR == "site"
        val permissions = context.packageManager.getPackageInfo(context.packageName,
            android.content.pm.PackageManager.GET_PERMISSIONS).requestedPermissions.orEmpty()
        assertEquals(site, android.Manifest.permission.REQUEST_INSTALL_PACKAGES in permissions)
        assertEquals(site, context.packageManager.resolveContentProvider("${context.packageName}.updates", 0) != null)
        var launched: Intent? = null
        val capture = object : android.content.ContextWrapper(context) {
            override fun startActivity(intent: Intent) { launched = intent }
        }
        ChannelUpdates.open(capture, "https://example.org", "2026.12.01", "releases/new.apk") {
            throw AssertionError(it)
        }
        val intent = requireNotNull(launched)
        if (site) {
            assertEquals("com.zhibeifw.app.UpdateInstallActivity", intent.component?.className)
            assertEquals("https://example.org/releases/new.apk", intent.dataString)
        } else {
            assertEquals("com.android.vending", intent.`package`)
            assertEquals("market://details?id=com.zhibeifw.app", intent.dataString)
        }
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
    fun televisionLauncherResourcesAtXhdpi() {
        val config = Configuration(context.resources.configuration).apply {
            uiMode = (uiMode and Configuration.UI_MODE_TYPE_MASK.inv()) or Configuration.UI_MODE_TYPE_TELEVISION
            densityDpi = DisplayMetrics.DENSITY_XHIGH
        }
        val tv = context.createConfigurationContext(config)
        val info = tv.applicationInfo
        val banner = tv.getDrawable(info.banner)!!
        assertEquals(320, banner.intrinsicWidth)
        assertEquals(180, banner.intrinsicHeight)
        val icon = tv.getDrawable(info.icon)!!
        assertTrue(icon is AdaptiveIconDrawable)
        assertEquals(icon.intrinsicWidth, icon.intrinsicHeight)
        assertTrue("电视 xhdpi 方形图标实际为 ${icon.intrinsicWidth}px", icon.intrinsicWidth >= 160)
    }

    @Test
    fun oneInstalledPackageSupportsBothLauncherIntents() {
        for (category in listOf(Intent.CATEGORY_LAUNCHER, Intent.CATEGORY_LEANBACK_LAUNCHER)) {
            val launch = Intent(Intent.ACTION_MAIN).addCategory(category).setPackage(context.packageName)
            assertNotNull(context.packageManager.resolveActivity(launch, 0))
        }
    }
}
