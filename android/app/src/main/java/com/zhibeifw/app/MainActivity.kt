package com.zhibeifw.app

import android.Manifest
import android.app.Application
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.LaunchedEffect
import androidx.core.content.ContextCompat
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.zhibeifw.app.design.ZTheme
import com.zhibeifw.app.ui.RootView

class ZhibeiApp : Application() {
    lateinit var model: AppModel; private set

    override fun onCreate() {
        super.onCreate()
        model = AppModel(this)
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) = model.onForeground()
            override fun onStop(owner: LifecycleOwner) = model.onBackground()
        })
    }
}

class MainActivity : ComponentActivity() {
    private val model get() = (application as ZhibeiApp).model

    override fun onCreate(savedInstanceState: Bundle?) {
        // 启动页：SplashScreen API，本地数据准备好才放行（最多约 3 秒，没网不等）
        val splash = installSplashScreen()
        super.onCreate(savedInstanceState)
        splash.setKeepOnScreenCondition { model.phase is Phase.Launching }
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT),
        )
        lockOrientation(false)
        model.openUrl = openUrlRef
        model.bootOnce()
        // 点桌面小组件打开的（页面重建时不再处理一次）
        if (savedInstanceState == null) model.openWidgetLink(intent?.data)
        setContent {
            val dark = isSystemInDarkTheme()
            ZTheme(dark) {
                LaunchedEffect(model.playerOpen) { lockOrientation(model.playerOpen) }
                RootView(model)
            }
        }
    }

    /** App 已经开着时点桌面小组件（singleTask：不新建页面，交到这里） */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        model.openWidgetLink(intent.data)
    }

    /** 屏幕方向：手机只有全屏播放页能横屏；平板（最短边 ≥ 600dp）全部方向。 */
    private fun lockOrientation(playerOpen: Boolean) {
        val tablet = resources.configuration.smallestScreenWidthDp >= 600
        requestedOrientation = when {
            tablet -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            playerOpen -> ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
            else -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
    }

    // 全局的 model 活得比页面长：页面销毁时解绑，免得 model 一直抓着已销毁的页面（内存泄漏）
    private val openUrlRef: (String) -> Unit = ::openUrl
    override fun onDestroy() {
        if (model.openUrl === openUrlRef) model.openUrl = null
        super.onDestroy()
    }

    /**
     * 打开网页的统一方式：① Custom Tabs；② 系统“打开链接”；③ 只弹“无法打开网页”。
     * 每一步都捕获异常：不能崩溃，也不能点了没反应。没有网络先提示。
     */
    private fun openUrl(url: String) {
        if (!model.connectivity.connected) {
            model.alert = AlertSpec("需要联网才能查看"); return
        }
        val uri = Uri.parse(url)
        try {
            CustomTabsIntent.Builder().build().launchUrl(this, uri); return
        } catch (_: Exception) {
        }
        try {
            startActivity(
                Intent(
                    Intent.ACTION_VIEW,
                    uri
                ).addCategory(Intent.CATEGORY_BROWSABLE)
            ); return
        } catch (_: ActivityNotFoundException) {
        } catch (_: Exception) {
        }
        model.alert = AlertSpec("无法打开网页")
    }
}
