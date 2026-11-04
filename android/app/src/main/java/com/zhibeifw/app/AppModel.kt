package com.zhibeifw.app

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.datastore.preferences.core.edit
import com.zhibeifw.app.core.COVER_THUMB_WIDTHS
import com.zhibeifw.app.core.DlStatus
import com.zhibeifw.app.core.PlayContext
import com.zhibeifw.app.core.UpdateChannel
import com.zhibeifw.app.core.isHttpsOrigin
import com.zhibeifw.app.core.launchFreshWaitMs
import com.zhibeifw.app.core.parseDomains
import com.zhibeifw.app.core.shouldSyncOnForeground
import com.zhibeifw.app.data.AppFiles
import com.zhibeifw.app.data.CatalogSync
import com.zhibeifw.app.data.Db
import com.zhibeifw.app.data.DlItem
import com.zhibeifw.app.data.HomeData
import com.zhibeifw.app.data.Migrator
import com.zhibeifw.app.data.RecentRow
import com.zhibeifw.app.data.Store
import com.zhibeifw.app.data.SyncSummary
import com.zhibeifw.app.download.DownloadManager
import com.zhibeifw.app.download.SystemDownloader
import com.zhibeifw.app.images.CoverArchive
import com.zhibeifw.app.images.ImageLoader
import com.zhibeifw.app.net.Connectivity
import com.zhibeifw.app.net.Network
import com.zhibeifw.app.net.PrefKeys
import com.zhibeifw.app.net.editPrefs
import com.zhibeifw.app.net.readPrefs
import com.zhibeifw.app.player.PlayerController
import com.zhibeifw.app.ui.SheetSpec
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
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
    // 后台任务里没接住的错误只记日志，不让 App 崩溃
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main +
        CoroutineExceptionHandler { _, e -> Log.w("AppModel", "后台任务出错", e) })

    var phase by mutableStateOf<Phase>(Phase.Launching)
    var home by mutableStateOf(HomeData())
    var syncFailed by mutableStateOf(false)


    /** 后台自动检查更新进行中（启动、切回前台时）：主页顶部显示“正在更新…”。下拉刷新有系统转圈，不算 */
    var autoUpdating by mutableStateOf(false); private set
    private var lastSyncAt = 0L
    private var syncing = false
    private var inflightSync: Deferred<SyncSummary>? = null

    /** 用户数据变了，按种类分开：各页面只跟自己用到的那几种，别的变了不用重读。 */
    /** 收听进度、已听完、最近列表 */
    var progressVersion by mutableIntStateOf(0)
    var favoritesVersion by mutableIntStateOf(0)

    /** 下载状态（排队、下载中、暂停、已下载、删除） */
    var downloadsVersion by mutableIntStateOf(0)
    var catalogVersion by mutableIntStateOf(0)

    val nav = Navigator()
    var playerOpen by mutableStateOf(false)
    var alert by mutableStateOf<AlertSpec?>(null)
    var sheet by mutableStateOf<SheetSpec?>(null)

    val versionName: String = BuildConfig.VERSION_NAME
    val channel = if (BuildConfig.CHANNEL == "store") UpdateChannel.STORE else UpdateChannel.SITE
    val upgrade = UpgradeChecker(ctx, net, scope, versionName, channel) { openExternal(it) }
    private val covers = CoverArchive(files, images, scope)

    // ---------- 启动 ----------

    private var bootJob: Job? = null

    /** 启动只做一次，放在 App 自己的 scope 里：页面销毁、重建（包括进程被回收后从最近任务恢复）都不会打断或重复。 */
    fun bootOnce() {
        if (bootJob == null) bootJob = scope.launch { boot() }
    }

    /** 启动页期间：打开数据库、迁移、读本机数据。返回后启动页才关（setKeepOnScreenCondition）。 */
    private suspend fun boot() {
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
                true
            } catch (e: Exception) {
                Log.e("AppModel", "数据库打开或升级失败", e)
                false
            }
        }
        if (!ok) {
            phase = Phase.DbError; return
        }
        // 偏好迁移和数据库无关：出错不能进“数据库出错”页
        withContext(Dispatchers.IO) { runCatching { importV1Prefs() } }
        val p = PlayerController(ctx, store, files, net)
        player = p
        val dm = DownloadManager(SystemDownloader(ctx), store, files)
        dm.origin = { net.ensureRoutes() }
        dm.onChange = { downloadsVersion++ }
        dm.onBatchFailed = { alert = AlertSpec("部分下载失败，请稍后重试") }
        dm.onDiskFull = { alert = AlertSpec("手机存储空间不足，下载失败") }
        downloads = dm
        p.onProgressSaved = { progressVersion++ }
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
            scope.launch { upgrade.check(manual = false) }
        } else {
            phase = Phase.Initializing(1, false)
            scope.launch { runInitialization() }
        }
    }

    /** 正在首次初始化：网络恢复和“重试”同时来时只跑一轮 */
    private var initRunning = false

    suspend fun runInitialization() {
        if (initRunning) return
        initRunning = true
        try {
            initializeOnce()
        } finally {
            initRunning = false
        }
    }

    private suspend fun initializeOnce() {
        phase = Phase.Initializing(1, false)
        val ok = CatalogSync.initializeWithRetry(
            store,
            net,
            onAttempt = { n -> phase = Phase.Initializing(n, false) })
        if (ok) {
            loadHome()
            phase = Phase.Ready
            lastSyncAt = System.currentTimeMillis()
            scope.launch { upgrade.check(manual = false) }
        } else phase = Phase.Initializing(CatalogSync.INIT_ATTEMPTS, true)
    }

    /** 从 v1.0 的 ExpoSQLiteStorage 读出线路相关的小偏好。只读一次。 */
    private suspend fun importV1Prefs() {
        val p = ctx.readPrefs()
        if (p[PrefKeys.migratedV1] != null) return
        ctx.editPrefs { it[PrefKeys.migratedV1] = "1" }
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
            ctx.editPrefs {
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
            // 由同步任务自己做完时清掉：下拉刷新的页面被关掉、等的人被取消时，同步还在跑，不能让下一次另起一个
            lateinit var task: Deferred<SyncSummary>
            task = scope.async(start = CoroutineStart.LAZY) {
                try {
                    CatalogSync.sync(store, net)
                } finally {
                    if (inflightSync === task) inflightSync = null
                }
            }
            inflightSync = task
            task.start()
            val s = task.await()
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
        // 在别处（锁屏、系统下载）可能变了：全部重读一次
        progressVersion++; favoritesVersion++; downloadsVersion++
    }

    fun onBackground() {
        player?.saveNow()
    }

    // ---------- 播放页 ----------

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
        if (nav.isShowingSeries(seriesId)) return
        nav.push(Routes.series(seriesId))
    }

    // ---------- 播放入口 ----------

    fun playAndOpen(episodeId: String, ctx: PlayContext) {
        val p = player ?: return
        if (p.current?.episodeId == episodeId) {
            // 已经是这一集：暂停着就接着播；出错的不自动重试（播放页上有重试）；都打开播放页
            if (!p.looksPlaying && p.error == null) p.resume()
            openPlayer()
            return
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
        if (!row.gone || safe("读下载记录") { store.getDownload(row.episodeId) }?.state == DlStatus.DONE) {
            go(); return
        }
        alert = AlertSpec(if (safe("读课程") { store.seriesExists(row.seriesId) } == true) "这一集已下架" else "这门课已下架")
    }

    // ---------- 进度、收藏 ----------

    /** 页面触发的写库：出错只记日志，不让 App 崩（和 iOS 的 try? 一样）。 */
    private fun <T> safe(what: String, block: () -> T): T? = try {
        block()
    } catch (e: Exception) {
        Log.w("AppModel", "$what 出错", e); null
    }

    fun markCompleted(episodeId: String, seriesId: String, completed: Boolean) {
        if (completed) player?.stopAsCompleted(episodeId)
        safe("标记已听完") {
            val info = store.getEpisodeInfo(episodeId)
            store.markCompleted(
                episodeId,
                seriesId,
                completed,
                info?.seriesTitle ?: "",
                info?.episodeTitle ?: "",
                info?.coverPath ?: ""
            )
        }
        progressVersion++
    }

    fun toggleFavorite(seriesId: String, title: String, coverPath: String) {
        safe("收藏") {
            if (store.isFavorite(seriesId)) store.removeFavorite(seriesId) else store.addFavorite(seriesId, title, coverPath)
        }
        favoritesVersion++
    }

    fun removeFavorite(seriesId: String) {
        safe("取消收藏") { store.removeFavorite(seriesId) }
        favoritesVersion++
    }

    fun hideRecent(episodeId: String) {
        safe("移除最近") { store.hideFromRecent(episodeId) }
        progressVersion++
    }

    fun clearRecent() {
        safe("清空最近") { store.clearRecent() }
        progressVersion++
    }

    // ---------- 下载 ----------

    /** 有网就下，不分 Wi-Fi 还是流量，不提示；没网直接提示。 */
    private fun requireNetwork(): Boolean {
        if (connectivity.connected) return true
        alert = AlertSpec("网络异常，请检查网络后重试")
        return false
    }

    fun download(items: List<DlItem>) {
        if (items.isEmpty() || !requireNetwork()) return
        covers.save(items[0].seriesId, safe("读封面路径") { store.seriesCoverPath(items[0].seriesId) })
        downloads?.enqueue(items)
    }

    fun resumeDownloads(seriesId: String?, episodeId: String? = null) {
        if (!requireNetwork()) return
        val dm = downloads ?: return
        if (episodeId != null) safe("读下载记录") { store.getDownload(episodeId) }
            ?.let { dm.enqueue(listOf(it.item)) } else safe("继续下载") { dm.resumePaused(seriesId) }
    }

    fun dlItem(episodeId: String): DlItem? = safe("读单集") { store.getEpisodeInfo(episodeId) }?.let {
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
