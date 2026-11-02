package com.zhibeifw.app

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.datastore.preferences.core.edit
import com.zhibeifw.app.core.FileKind
import com.zhibeifw.app.core.RemindLater
import com.zhibeifw.app.core.UpdateChannel
import com.zhibeifw.app.core.UpdateDecision
import com.zhibeifw.app.core.UpgradeFile
import com.zhibeifw.app.core.decideUpdate
import com.zhibeifw.app.core.parseUpgrade
import com.zhibeifw.app.core.shouldAutoCheck
import com.zhibeifw.app.core.suppressedByRemindLater
import com.zhibeifw.app.data.UPGRADE_PATH
import com.zhibeifw.app.net.NetResult
import com.zhibeifw.app.net.Network
import com.zhibeifw.app.net.PrefKeys
import com.zhibeifw.app.net.buildUrl
import com.zhibeifw.app.net.prefs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/** 检查更新：“此版本过旧”提示条和官网版的“发现新版本”对话框（与 iOS UpgradeChecker.swift 对应，iOS 只看 minVersion）。 */
class UpgradeChecker(
    private val ctx: Context,
    private val net: Network,
    private val scope: CoroutineScope,
    private val versionName: String,
    private val channel: UpdateChannel,
    private val openUrl: (String) -> Unit,
) {
    /** “此版本过旧”提示条。 */
    var outdated by mutableStateOf<UpdateDecision.Outdated?>(null); private set
    var outdatedDismissed by mutableStateOf(false)
    var updateDialog by mutableStateOf<UpdateDecision.Optional?>(null); private set

    /** 检查更新。手动检查时返回要显示在“检查更新”那一行右边的结果（有新版本时同时弹更新对话框）；自动检查返回 null。 */
    suspend fun check(manual: Boolean): String? {
        val now = System.currentTimeMillis()
        val p = ctx.prefs.data.first()
        val last = p[PrefKeys.updateCheckedAt]
        if (!manual && !shouldAutoCheck(last, now)) {
            p[PrefKeys.updateBody]?.let { parseUpgrade(it) }?.let { apply(it, manual = false) }
            return null
        }
        val result = when (val r =
            net.request(UPGRADE_PATH, p[PrefKeys.updateEtag], FileKind.UPGRADE.limit)) {
            is NetResult.Ok -> {
                val text = String(r.body, Charsets.UTF_8)
                val u = parseUpgrade(text) ?: return if (manual) "检查失败" else null
                ctx.prefs.edit {
                    it[PrefKeys.updateBody] = text; r.etag?.let { e ->
                    it[PrefKeys.updateEtag] = e
                }; it[PrefKeys.updateCheckedAt] = now
                }
                apply(u, manual)
            }

            NetResult.NotModified -> {
                ctx.prefs.edit { it[PrefKeys.updateCheckedAt] = now }
                p[PrefKeys.updateBody]?.let { parseUpgrade(it) }?.let { apply(it, manual) }
                    ?: "已是最新版本"
            }

            else -> "检查失败" // 自动检查失败不提示
        }
        return if (manual) result else null
    }

    /** 返回手动检查时显示在行上的结果文字；有可选更新时同时弹对话框（要用户决定）。 */
    private suspend fun apply(u: UpgradeFile, manual: Boolean): String? {
        return when (val d = decideUpdate(versionName, u, channel)) {
            is UpdateDecision.Outdated -> {
                outdated = d
                "版本过旧，请到官网更新"
            }

            is UpdateDecision.Optional -> {
                outdated = null
                val p = ctx.prefs.data.first()
                val remind =
                    p[PrefKeys.remindVersion]?.let { RemindLater(it, p[PrefKeys.remindAt] ?: 0) }
                if (manual || !suppressedByRemindLater(
                        remind,
                        d.version,
                        System.currentTimeMillis()
                    )
                ) updateDialog = d
                "有新版本 ${d.version}"
            }

            UpdateDecision.None -> {
                outdated = null; "已是最新版本"
            }
        }
    }

    fun remindLater(version: String) {
        updateDialog = null
        scope.launch {
            ctx.prefs.edit {
                it[PrefKeys.remindVersion] = version; it[PrefKeys.remindAt] =
                System.currentTimeMillis()
            }
        }
    }

    /** 立刻更新：打开官网 APK 直链，交给浏览器 / 下载管理器。 */
    fun openApk(apkPath: String) {
        updateDialog = null
        val origin = net.currentOrigin ?: return
        openUrl(buildUrl(origin, apkPath))
    }
}
