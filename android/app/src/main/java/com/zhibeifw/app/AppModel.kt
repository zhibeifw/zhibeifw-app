package com.zhibeifw.app

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.datastore.preferences.core.edit
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavHostController
import com.zhibeifw.app.core.COVER_THUMB_WIDTHS
import com.zhibeifw.app.core.DlStatus
import com.zhibeifw.app.core.FileKind
import com.zhibeifw.app.core.NavCollapse
import com.zhibeifw.app.core.PlayContext
import com.zhibeifw.app.core.PushGuard
import com.zhibeifw.app.core.RemindLater
import com.zhibeifw.app.core.UpdateChannel
import com.zhibeifw.app.core.UpdateDecision
import com.zhibeifw.app.core.decideUpdate
import com.zhibeifw.app.core.isHttpsOrigin
import com.zhibeifw.app.core.launchFreshWaitMs
import com.zhibeifw.app.core.parseDomains
import com.zhibeifw.app.core.parseUpgrade
import com.zhibeifw.app.core.shouldAutoCheck
import com.zhibeifw.app.core.shouldSyncOnForeground
import com.zhibeifw.app.core.suppressedByRemindLater
import com.zhibeifw.app.data.AppFiles
import com.zhibeifw.app.data.CatalogSync
import com.zhibeifw.app.data.Db
import com.zhibeifw.app.data.DlItem
import com.zhibeifw.app.data.HomeData
import com.zhibeifw.app.data.Migrator
import com.zhibeifw.app.data.RecentRow
import com.zhibeifw.app.data.Store
import com.zhibeifw.app.data.SyncSummary
import com.zhibeifw.app.data.UPGRADE_PATH
import com.zhibeifw.app.download.DownloadManager
import com.zhibeifw.app.download.SystemDownloader
import com.zhibeifw.app.images.ImageLoader
import com.zhibeifw.app.net.Connectivity
import com.zhibeifw.app.net.NetResult
import com.zhibeifw.app.net.Network
import com.zhibeifw.app.net.PrefKeys
import com.zhibeifw.app.net.buildUrl
import com.zhibeifw.app.net.prefs
import com.zhibeifw.app.player.PlayerController
import com.zhibeifw.app.ui.SheetSpec
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

sealed class Phase {
    object Launching : Phase()
    data class Initializing(val attempt: Int, val failed: Boolean) : Phase()
    object Ready : Phase()
    object DbError : Phase()
}

enum class Tab { HOME, CATEGORIES, LIBRARY, SEARCH }

data class AlertButton(
    val title: String,
    val destructive: Boolean = false,
    val cancel: Boolean = false,
    val action: () -> Unit = {}
)

data class AlertSpec(
    val title: String,
    val message: String? = null,
    val buttons: List<AlertButton> = listOf(AlertButton("好"))
)

/** 全 App 的状态与动作（与 iOS AppModel.swift 同样的结构）。页面只读它、调它。 */
class AppModel(private val ctx: Context) {
    val files = AppFiles(ctx)
    lateinit var store: Store; private set
    val net = Network(ctx)
    val connectivity = Connectivity(ctx)
    val images = ImageLoader(net, File(ctx.cacheDir, "covers-cache"))
    var player: PlayerController? by mutableStateOf(null); private set
    var downloads: DownloadManager? by mutableStateOf(null); private set
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    var phase by mutableStateOf<Phase>(Phase.Launching)
    var home by mutableStateOf(HomeData())
    var syncFailed by mutableStateOf(false)

    /** “此版本过旧”提示条。 */
    var outdated by mutableStateOf<UpdateDecision.Outdated?>(null)
    var outdatedDismissed by mutableStateOf(false)

    /** 后台自动检查更新进行中（启动、切回前台时）：主页顶部显示“正在更新…”。下拉刷新有系统转圈，不算 */
    var autoUpdating by mutableStateOf(false); private set
    private var lastSyncAt = 0L
    private var syncing = false
    private var inflightSync: Deferred<SyncSummary>? = null

    /** 用户数据变了：各页面据此重新读取。 */
    var dataVersion by mutableIntStateOf(0)
    var catalogVersion by mutableIntStateOf(0)

    var tab by mutableStateOf(Tab.HOME)
    var homeNav: NavHostController? = null
    var categoriesNav: NavHostController? = null
    var libraryNav: NavHostController? = null
    var searchNav: NavHostController? = null
    var playerOpen by mutableStateOf(false)
    var navCollapsed by mutableStateOf(false)

    /** 底部导航栏是否显示（关于页不显示）；Snackbar 据此决定要不要给导航栏让位 */
    var bottomNavShown by mutableStateOf(true)
    private val nav = NavCollapse()
    var alert by mutableStateOf<AlertSpec?>(null)
    var sheet by mutableStateOf<SheetSpec?>(null)
    val pushGuard = PushGuard()

    val versionName: String = BuildConfig.VERSION_NAME
    val channel = if (BuildConfig.CHANNEL == "store") UpdateChannel.STORE else UpdateChannel.SITE

    // ---------- 启动 ----------

    /** 启动页期间：打开数据库、迁移、读本机数据。返回后启动页才关（setKeepOnScreenCondition）。 */
    suspend fun boot() {
        val t0 = System.currentTimeMillis()
        val ok = withContext(Dispatchers.IO) {
            files.prepare()
            try {
                val db = Db.open(files.dbPath.path)
                try {
                    Migrator.migrate(
                        db,
                        beforeUserMigration = { _, _ ->
                            Migrator.backupUserTables(
                                db,
                                files.backupPath
                            )
                        })
                } catch (e: Exception) {
                    Migrator.migrate(db) // 失败重试一次，仍失败就提示并停下
                }
                store = Store(db)
                importV1Prefs()
                true
            } catch (e: Exception) {
                Log.e("AppModel", "数据库打开或升级失败", e)
                false
            }
        }
        if (!ok) {
            phase = Phase.DbError; return
        }
        val p = PlayerController(ctx, store, files, net)
        player = p
        val dm = DownloadManager(SystemDownloader(ctx), store, files)
        dm.origin = { net.ensureRoutes() }
        dm.onChange = { dataVersion++ }
        dm.onBatchFailed = { alert = AlertSpec("部分下载失败，请稍后重试") }
        dm.onDiskFull = { alert = AlertSpec("手机存储空间不足，下载失败") }
        downloads = dm
        p.onProgressSaved = { dataVersion++ }
        p.onDamaged =
            { id -> dm.removeDownload(id); alert = AlertSpec("这一集的下载文件已损坏，请重新下载") }
        runCatching { dm.reconcile() }
        connectivity.onReconnect.add {
            val ph = phase
            if (ph is Phase.Initializing && ph.failed) scope.launch { runInitialization() }
        }

        if (store.isInitialized) {
            loadHome()
            val wait = launchFreshWaitMs(connectivity.connected, System.currentTimeMillis() - t0)
            if (wait > 0) {
                val job = scope.async { syncCatalog(false) }
                withTimeoutOrNull(wait) { job.await() }
            } else scope.launch { syncCatalog(false) }
            phase = Phase.Ready
            scope.launch { checkUpgrade(manual = false) }
        } else {
            phase = Phase.Initializing(1, false)
            scope.launch { runInitialization() }
        }
    }

    suspend fun runInitialization() {
        phase = Phase.Initializing(1, false)
        val ok = CatalogSync.initializeWithRetry(
            store,
            net,
            onAttempt = { n -> phase = Phase.Initializing(n, false) })
        if (ok) {
            loadHome()
            phase = Phase.Ready
            lastSyncAt = System.currentTimeMillis()
            scope.launch { checkUpgrade(manual = false) }
        } else phase = Phase.Initializing(CatalogSync.INIT_ATTEMPTS, true)
    }

    /** 从 v1.0 的 ExpoSQLiteStorage 读出线路相关的小偏好。只读一次。 */
    private suspend fun importV1Prefs() {
        val p = ctx.prefs.data.first()
        if (p[PrefKeys.migratedV1] != null) return
        ctx.prefs.edit { it[PrefKeys.migratedV1] = "1" }
        if (!files.v1KVPath.exists()) return
        runCatching {
            val kv = Db(
                SQLiteDatabase.openDatabase(
                    files.v1KVPath.path,
                    null,
                    SQLiteDatabase.OPEN_READONLY
                )
            )
            // 旧库坏了、查询出错也要关掉
            val (last, doms) = try {
                kv.first("SELECT value FROM storage WHERE key = ?", "net.lastService")
                    ?.optStr("value") to
                        kv.first("SELECT value FROM storage WHERE key = ?", "net.domains")
                            ?.optStr("value")
            } finally {
                kv.db.close()
            }
            ctx.prefs.edit {
                if (last != null && isHttpsOrigin(last)) it[PrefKeys.lastService] = last
                if (doms != null && parseDomains(doms) != null) it[PrefKeys.domains] = doms
            }
        }
    }

    fun loadHome() {
        home = runCatching { store.loadHome() }.getOrDefault(HomeData())
        catalogVersion++
        prefetchHomeCovers()
    }

    /** 主页上的封面先在后台下好（只存磁盘，已有的跳过）：打开主页时多数直接是图，不先看到占位色。
     *  新课程是大卡片（要原图）；编辑精选和各分类行是小卡片（640 小图），每行只取前 4 张（第一屏能看到的加一点）。 */
    private fun prefetchHomeCovers() {
        val h = home
        val large = h.ongoing.map { it.coverPath to Int.MAX_VALUE }
        val small =
            (h.featured + h.categories.flatMap { it.series.take(4) }).map { it.coverPath to COVER_THUMB_WIDTHS.last() }
        images.prefetch(scope, large + small)
    }

    /** 同步目录。userInitiated：主页下拉刷新。有新内容就立刻换上主页。 */
    /** 取 index.json 只有这几处：启动、切回前台（自动，主页顶栏显示“正在更新…”）、下拉刷新、刷新网络线路。
     *  点开课程、在“最近”里点已下架的课都只看本机目录，不联网。 */
    suspend fun syncCatalog(userInitiated: Boolean): SyncSummary? {
        // 已经在更新（启动、回到前台时的自动更新）：等它做完，不另起一次；直接返回的话，下拉刷新的转圈会一闪就没
        inflightSync?.let { running ->
            val s = running.await()
            if (userInitiated) {
                loadHome()
                if (s.failed) syncFailed = true
            }
            return s
        }
        syncing = true
        if (!userInitiated) autoUpdating = true
        try {
            val task = scope.async { CatalogSync.sync(store, net) }
            inflightSync = task
            val s = try {
                task.await()
            } finally {
                inflightSync = null
            }
            lastSyncAt = System.currentTimeMillis()
            // 有新内容立刻换上；用户下拉刷新则完成后一律重读
            if (userInitiated || s.changed) loadHome()
            syncFailed = if (s.failed) userInitiated || connectivity.connected else false
            return s
        } finally {
            syncing = false; autoUpdating = false
        }
    }

    fun onForeground() {
        if (phase != Phase.Ready) return
        if (shouldSyncOnForeground(
                System.currentTimeMillis(),
                lastSyncAt,
                syncing
            )
        ) scope.launch { syncCatalog(false) }
        downloads?.let { scope.launch { it.reconcile() } }
        dataVersion++
    }

    fun onBackground() {
        player?.saveNow()
    }

    // ---------- 更新检查 ----------

    var updateDialog by mutableStateOf<UpdateDecision.Optional?>(null)

    /** 检查更新。手动检查时返回要显示在“检查更新”那一行右边的结果（有新版本时同时弹更新对话框）；自动检查返回 null。 */
    suspend fun checkUpgrade(manual: Boolean): String? {
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
    private suspend fun apply(u: com.zhibeifw.app.core.UpgradeFile, manual: Boolean): String? {
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
        openExternal(buildUrl(origin, apkPath))
    }

    // ---------- 导航 ----------

    val navController
        get() = when (tab) {
            Tab.HOME -> homeNav; Tab.CATEGORIES -> categoriesNav; Tab.LIBRARY -> libraryNav; Tab.SEARCH -> searchNav
        }

    fun push(route: String) {
        if (!pushGuard.allow("$tab-$route")) return
        navController?.navigate(route)
        resetNav()
    }

    fun selectTab(t: Tab) {
        if (tab == t) navController?.let { nc -> while (nc.previousBackStackEntry != null) nc.popBackStack() } else tab =
            t
        resetNav()
    }

    fun resetNav() {
        nav.expand(); nav.reset(0.0); navCollapsed = false
    }

    fun feedScroll(y: Double) {
        if (nav.feed(y)) navCollapsed = nav.collapsed
    }

    fun openPlayer() {
        if (player?.current == null) return
        playerOpen = true
    }

    fun closePlayer() {
        playerOpen = false
    }

    /** 播放页“前往课程”：下面已经是这门课就只收起播放页。 */
    fun goToSeries(seriesId: String) {
        closePlayer()
        val r = Routes.series(seriesId)
        if (navController?.currentBackStackEntry?.let { Routes.seriesIdOf(it) } == seriesId) return
        push(r)
    }

    // ---------- 播放入口 ----------

    fun playAndOpen(episodeId: String, ctx: PlayContext) {
        val p = player ?: return
        if (p.current?.episodeId == episodeId) {
            if (!p.looksPlaying && p.error == null) p.resume(); openPlayer(); return
        }
        if (p.start(episodeId, ctx)) openPlayer() else alert = AlertSpec("这一集已下架")
    }

    fun togglePlay(episodeId: String, ctx: PlayContext) {
        val p = player ?: return
        if (p.current?.episodeId == episodeId) {
            p.toggle(); return
        }
        if (!p.start(episodeId, ctx)) alert = AlertSpec("这一集已下架")
    }

    /** “最近”里点某一集：本机目录里没有、也没下载过，就是已下架。只看本机目录，不联网（只有启动和下拉刷新取 index.json）。 */
    fun playFromRecent(row: RecentRow, open: Boolean) {
        val go = {
            if (open) playAndOpen(
                row.episodeId,
                PlayContext.Single
            ) else togglePlay(row.episodeId, PlayContext.Single)
        }
        if (!row.gone || store.getDownload(row.episodeId)?.state == com.zhibeifw.app.core.DlStatus.DONE) {
            go(); return
        }
        alert = AlertSpec(if (store.seriesExists(row.seriesId)) "这一集已下架" else "这门课已下架")
    }

    // ---------- 进度、收藏 ----------

    fun markCompleted(episodeId: String, seriesId: String, completed: Boolean) {
        if (completed) player?.stopAsCompleted(episodeId)
        val info = store.getEpisodeInfo(episodeId)
        runCatching {
            store.markCompleted(
                episodeId,
                seriesId,
                completed,
                info?.seriesTitle ?: "",
                info?.episodeTitle ?: "",
                info?.coverPath ?: ""
            )
        }
        dataVersion++
    }

    fun toggleFavorite(seriesId: String, title: String, coverPath: String) {
        if (store.isFavorite(seriesId)) store.removeFavorite(seriesId) else store.addFavorite(
            seriesId,
            title,
            coverPath
        )
        dataVersion++
    }

    fun hideRecent(episodeId: String) {
        store.hideFromRecent(episodeId); dataVersion++
    }

    // ---------- 下载 ----------

    /** 有网就下，不分 Wi-Fi 还是流量，不提示；没网直接提示。 */
    private fun requireNetwork(): Boolean {
        if (connectivity.connected) return true
        alert = AlertSpec("网络异常，请检查网络后重试")
        return false
    }

    fun download(items: List<DlItem>, single: Boolean) {
        if (items.isEmpty() || !requireNetwork()) return
        saveCoverLocally(items[0].seriesId)
        downloads?.enqueue(items)
    }

    fun resumeDownloads(seriesId: String?, single: Boolean = false, episodeId: String? = null) {
        if (!requireNetwork()) return
        val dm = downloads ?: return
        if (episodeId != null) store.getDownload(episodeId)
            ?.let { dm.enqueue(listOf(it.item)) } else dm.resumePaused(seriesId)
    }

    fun dlItem(episodeId: String): DlItem? = store.getEpisodeInfo(episodeId)?.let {
        DlItem(
            it.episodeId,
            it.seriesId,
            it.seriesTitle,
            it.episodeTitle,
            it.pos,
            it.audioPath
        )
    }

    fun deleteDownload(episodeId: String) {
        player?.stopIfCurrent(episodeId)
        downloads?.removeDownload(episodeId)
    }

    private fun saveCoverLocally(seriesId: String) {
        val dest = files.coverFile(seriesId)
        val cover = store.seriesCoverPath(seriesId)
        if (dest.exists() || cover.isNullOrEmpty()) return
        scope.launch(Dispatchers.IO) {
            val origin = net.ensureRoutes() ?: return@launch
            runCatching {
                val c = URL(buildUrl(origin, cover)).openConnection() as HttpURLConnection
                try {
                    if (c.responseCode == 200) {
                        val tmp = File(dest.path + ".tmp")
                        // 下到一半断了：删掉半截的临时文件（对账只清 .jpg，不会管它）
                        try {
                            c.inputStream.use { i -> tmp.outputStream().use { i.copyTo(it) } }
                        } catch (e: Exception) {
                            tmp.delete(); throw e
                        }
                        if (dest.exists() || !tmp.renameTo(dest)) tmp.delete()
                    }
                } finally {
                    c.disconnect()
                }
            }
        }
    }

    // ---------- 关于页 ----------

    suspend fun refreshRoutes(): String {
        val (origin, same) = net.refreshRoutes()
        if (origin == null) return "暂时无法连接"
        syncCatalog(true)
        return if (same) "线路正常" else "已切换到备用线路，连接正常"
    }

    var openUrl: ((String) -> Unit)? = null
    fun openExternal(url: String) {
        openUrl?.invoke(url)
    }

    fun launch(block: suspend CoroutineScope.() -> Unit) = scope.launch(block = block)
}

/** 页面地址（Navigation Compose 的路由）。课程 ID 可以是中文，拼进路径前先编码。 */
object Routes {
    const val HOME = "home"
    const val CATEGORIES = "categories"
    const val LIBRARY_HUB = "libraryHub"
    const val SEARCH = "search"
    const val RECENT = "recent"
    const val FAVORITES = "favorites"
    const val LIBRARY = "library"
    const val ABOUT = "about"
    fun category(id: String) = "category/${Uri.encode(id)}"
    fun series(id: String) = "series/${Uri.encode(id)}"
    fun libraryCourse(id: String) = "libraryCourse/${Uri.encode(id)}"
    fun seriesIdOf(e: NavBackStackEntry): String? =
        if (e.destination.route == "series/{id}") e.arguments?.getString("id")
            ?.let { Uri.decode(it) } else null
}

