package com.zhibeifw.app

import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.lifecycle.lifecycleScope
import com.zhibeifw.app.core.compareVersions
import com.zhibeifw.app.design.generated.Tok
import kotlin.math.roundToInt
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** 官网更新由系统下载服务执行，安装确认只在用户打开的更新窗口中发起。 */
class UpdateInstallActivity : ComponentActivity() {
    private val manager by lazy { getSystemService(DownloadManager::class.java) }
    private val ticket by lazy { getSharedPreferences("apk_download", MODE_PRIVATE) }
    private val version get() = intent.getStringExtra("version").orEmpty()
    private val url get() = requireNotNull(intent.data)
    private val archive get() = File(cacheDir, "installer/update.apk")
    private val changes = Channel<Unit>(Channel.CONFLATED)
    private var checking: Job? = null
    private var waitingFor = ""
    private var registered = false
    private var failure = false
    private lateinit var message: TextView
    private lateinit var progressBar: ProgressBar
    private lateinit var close: Button

    private val settings = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        waitingFor = ""
        if (packageManager.canRequestPackageInstalls()) changes.trySend(Unit)
        else fail("未获准安装更新。你可以稍后再试。")
    }
    private val installer = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        waitingFor = ""
        if (it.resultCode == RESULT_FIRST_USER) fail("系统未能安装更新，请检查可用空间和设备的安装限制。")
        else finish()
    }
    private val completed = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1) == ticket.getLong("id", -1)) {
                changes.trySend(Unit)
            }
        }
    }
    private val downloadObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) {
            changes.trySend(Unit)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent.data?.scheme != "https" ||
            compareVersions(version, BuildConfig.VERSION_NAME) != 1) {
            finish()
            return
        }
        title = "更新至 $version"
        waitingFor = savedInstanceState?.getString("waiting").orEmpty()
        val panel = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val padding = (Tok.Space.pageMargin * resources.displayMetrics.density).roundToInt()
        panel.setPadding(padding, padding, padding, padding)
        message = TextView(this).also { panel.addView(it); it.text = "正在下载安装包…" }
        progressBar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            isIndeterminate = true
            max = 100
            panel.addView(this)
        }
        close = Button(this).also { panel.addView(it); it.text = "取消"; it.setOnClickListener { finish() } }
        setContentView(panel)
        try {
            if (ticket.getString("version", null) != version || !ticket.contains("id")) {
                discard()
                val request = DownloadManager.Request(url).setTitle("智悲佛网 $version")
                    .setMimeType(APK_TYPE)
                    .setDestinationInExternalFilesDir(this, "updates", "zhibeifw-$version.apk")
                val id = manager.enqueue(request)
                ticket.edit().putString("version", version).putLong("id", id).apply()
            }
        } catch (_: RuntimeException) {
            fail("系统无法下载安装包，请检查下载服务和可用空间。")
        }
    }

    override fun onResume() {
        super.onResume()
        if (isFinishing) return
        ContextCompat.registerReceiver(this, completed, IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE),
            ContextCompat.RECEIVER_EXPORTED)
        registered = true
        contentResolver.registerContentObserver(DOWNLOADS_URI, true, downloadObserver)
        changes.trySend(Unit)
        checking = lifecycleScope.launch {
            for (change in changes) checkDownload()
        }
    }

    override fun onPause() {
        if (registered) {
            contentResolver.unregisterContentObserver(downloadObserver)
            unregisterReceiver(completed)
            registered = false
        }
        checking?.cancel()
        super.onPause()
    }

    private suspend fun checkDownload() {
        if (failure || waitingFor.isNotEmpty() || isFinishing) return
        try {
            val id = ticket.getLong("id", -1)
            val download = withContext(Dispatchers.IO) {
                manager.query(DownloadManager.Query().setFilterById(id))?.use { cursor ->
                    if (!cursor.moveToFirst()) return@use null
                    val status = cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
                    val downloaded = cursor.getLong(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
                    val total = cursor.getLong(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
                    Download(status, downloaded, total)
                }
            }
            when (download?.status) {
                null, DownloadManager.STATUS_FAILED -> fail("下载未完成，请关闭后重试。")
                DownloadManager.STATUS_SUCCESSFUL -> confirmInstall(id)
                else -> showProgress(download)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            fail("无法打开更新，请检查设备的安装权限和可用空间。")
        }
    }

    private fun showProgress(download: Download) {
        val percent = if (download.total > 0) {
            (download.downloaded.coerceIn(0, download.total).toDouble() / download.total * 100).toInt()
        } else null
        progressBar.isIndeterminate = percent == null
        if (percent != null) progressBar.progress = percent
        val text = if (percent == null) "正在下载安装包…" else "正在下载安装包… $percent%"
        if (message.text != text) message.text = text
    }

    private suspend fun confirmInstall(id: Long) {
        progressBar.visibility = View.GONE
        if (!packageManager.canRequestPackageInstalls()) {
            message.text = "请在系统设置中允许智悲佛网安装应用，返回后继续。"
            waitingFor = "settings"
            settings.launch(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
            return
        }
        message.text = "正在校验安装包…"
        val valid = withContext(Dispatchers.IO) { prepareArchive(id) }
        if (!valid) {
            fail("安装包与当前应用或版本不匹配，请重新检查更新。")
            return
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", archive)
        val action = Intent(Intent.ACTION_VIEW).setDataAndType(uri, APK_TYPE)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            .putExtra(Intent.EXTRA_RETURN_RESULT, true)
        val target = packageManager.resolveActivity(action, PackageManager.MATCH_DEFAULT_ONLY or PackageManager.MATCH_SYSTEM_ONLY)
        if (target == null) {
            fail("这台设备没有可用的系统安装程序。")
            return
        }
        action.setClassName(target.activityInfo.packageName, target.activityInfo.name)
        waitingFor = "installer"
        installer.launch(action)
    }

    private fun prepareArchive(id: Long): Boolean {
        archive.parentFile?.mkdirs()
        val temp = File.createTempFile("download-", ".apk", archive.parentFile)
        try {
            contentResolver.openInputStream(manager.getUriForDownloadedFile(id) ?: return false)?.use { input ->
                temp.outputStream().use { input.copyTo(it) }
            } ?: return false
            return packageManager.isUpdateFor(temp, packageName, version, BuildConfig.VERSION_CODE.toLong()) &&
                temp.renameTo(archive)
        } finally {
            temp.delete()
        }
    }

    private fun fail(text: String) {
        failure = true
        waitingFor = ""
        progressBar.visibility = View.GONE
        message.text = text
        close.text = "关闭"
    }

    private fun discard() {
        UpdateDownloads.discardDownload(this)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString("waiting", waitingFor)
    }

    override fun onDestroy() {
        if (isFinishing && ::message.isInitialized) discard()
        super.onDestroy()
    }

    private data class Download(val status: Int, val downloaded: Long, val total: Long)

    companion object {
        private const val APK_TYPE = "application/vnd.android.package-archive"
        private val DOWNLOADS_URI = Uri.parse("content://downloads/my_downloads")
        fun intent(context: Context, url: String, version: String) =
            Intent(context, UpdateInstallActivity::class.java).setData(Uri.parse(url)).putExtra("version", version)
    }
}


@Suppress("DEPRECATION")
internal fun PackageManager.isUpdateFor(archive: File, appId: String, version: String, installedCode: Long): Boolean {
    // Android 10 的归档解析器只在收到 GET_SIGNATURES 时收集证书，再从 signingInfo 取当前签名。
    val flags = if (Build.VERSION.SDK_INT == Build.VERSION_CODES.Q)
        PackageManager.GET_SIGNING_CERTIFICATES or PackageManager.GET_SIGNATURES
    else PackageManager.GET_SIGNING_CERTIFICATES
    val info = getPackageArchiveInfo(archive.path, flags) ?: return false
    if (info.packageName != appId || info.versionName != version || info.longVersionCode <= installedCode) return false
    val signed = info.signingInfo?.apkContentsSigners ?: return false
    val installed = getPackageInfo(appId, PackageManager.GET_SIGNING_CERTIFICATES)
        .signingInfo?.apkContentsSigners ?: return false
    return signed.isNotEmpty() && signed.toSet() == installed.toSet()
}
