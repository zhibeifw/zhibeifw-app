import SwiftUI
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Phase: Equatable {
    case launching
    case initializing(attempt: Int, failed: Bool)
    case ready
    case dbError
}

struct AlertButton: Identifiable {
    let id = UUID()
    var title: String
    var role: ButtonRole? = nil
    var action: () -> Void = {}
}
struct AlertSpec: Identifiable {
    let id = UUID()
    var title: String
    var message: String? = nil
    var buttons: [AlertButton] = [AlertButton(title: "好")]
}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
}

/// iPhone 和 Apple TV 共用的状态与动作：数据库、课程目录同步、主页数据、播放入口、进度和收藏。
/// 各端自己的部分（iPhone 的下载、检查更新、导航、播放页）在各自的 App 模型里，通过下面几个回调接进来。
@MainActor
@Observable
final class AppCore {
    @ObservationIgnored let files = AppFiles()
    @ObservationIgnored private(set) var store: Store!
    private(set) var player: PlayerController!
    /// iCloud 同步：只有带了 iCloud 权限的构建才有（Info.plist 里有 ZBFWCloudContainer）
    @ObservationIgnored private var cloud: CloudSync?

    var phase: Phase = .launching
    var home = HomeData()
    /// 主页顶部“无法更新，显示的是上一次更新的内容”。
    var syncFailed = false
    /// 后台自动检查更新进行中（启动、切回前台时）：主页顶部显示“正在更新…”。下拉刷新有系统转圈，不算
    private(set) var autoUpdating = false
    @ObservationIgnored var lastSyncAt: Double = 0
    @ObservationIgnored var syncing = false
    @ObservationIgnored private var inflightSync: Task<SyncSummary, Never>?
    /// 用户数据变了，按种类分开：各页面只跟自己用到的那几种，别的变了不用重读。
    /// 收听进度、已听完、最近列表
    var progressVersion = 0
    var favoritesVersion = 0
    var catalogVersion = 0
    var alert: AlertSpec?

    // MARK: 各端接进来的部分（boot 之前设好）

    /// 数据库和播放器准备好之后、读主页之前（iPhone：建下载管理、对账）。
    @ObservationIgnored var onStoreReady: (() async -> Void)?
    /// 进入主页之后（iPhone：检查更新）。
    @ObservationIgnored var onReady: (() -> Void)?
    /// 主页数据读好之后，预取第一屏的封面（各端卡片尺寸不同）。
    @ObservationIgnored var prefetchHomeCovers: ((HomeData) -> Void)?
    /// 打开全屏播放页。
    @ObservationIgnored var presentPlayer: (() -> Void)?

    init() {}

    // MARK: 启动

    @ObservationIgnored private var booted = false

    /// 启动只做一次（根视图的 .task 可能不止跑一次，比如多个窗口）。
    func boot() async {
        guard !booted else { return }
        booted = true
        let t0 = Date()
        files.prepare()
        do {
            let db = try SQLiteDB(path: files.dbPath.path)
            let backup = files.backupPath.path
            do {
                _ = try Migrator.migrate(
                    db,
                    beforeUserMigration: { _, _ in
                        try? FileManager.default.removeItem(atPath: backup); try Migrator.backupUserTables(db, to: backup)
                    })
            } catch {
                // 失败重试一次，仍失败就提示并停下
                _ = try Migrator.migrate(db)
            }
            store = Store(db: db)
        } catch {
            NSLog("数据库打开或升级失败：\(error)")
            phase = .dbError
            return
        }
        importV1Prefs()
        player = PlayerController(store: store, files: files)
        player.onProgressSaved = { [weak self] in self?.progressVersion += 1 }
        Network.shared.onOriginChange = { OriginWatcher.shared.bump() }
        startCloudSync()
        await onStoreReady?()

        if store.isInitialized {
            loadHome()
            // 有网络时等联网检查最多到启动后约 3 秒；没网不等
            let online = Connectivity.shared.connected
            let wait = launchFreshWaitMs(online: online, elapsedMs: Date().timeIntervalSince(t0) * 1000)
            if wait > 0 {
                // 同步做完或时间到，谁先到算谁；时间到了同步照样在后台做完，只是启动页不再等它
                let (done, cont) = AsyncStream<Void>.makeStream()
                Task {
                    await self.syncCatalog(userInitiated: false)
                    cont.finish()
                }
                let timer = Task {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000))
                    cont.finish()
                }
                for await _ in done {}
                timer.cancel()
            } else {
                Task { await self.syncCatalog(userInitiated: false) }
            }
            phase = .ready
            onReady?()
        } else {
            await runInitialization()
        }
        Connectivity.shared.onReconnect.append { [weak self] in
            guard let self, case .initializing(_, true) = self.phase else { return }
            Task { await self.runInitialization() }
        }
    }

    /// iCloud 同步：Info.plist 里写了容器（和权限文件里的一致）才启动；没有就只存本机。
    /// 不带权限就去连 iCloud，系统会直接让 App 崩溃，所以以这个键为准，不硬连。
    private func startCloudSync() {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "ZBFWCloudContainer") as? String, !id.isEmpty else { return }
        let c = CloudSync(store: store, containerIdentifier: id)
        c.onRemoteChange = { [weak self] progress, favorites in
            guard let self else { return }
            if progress { self.progressVersion += 1 }
            if favorites { self.favoritesVersion += 1 }
        }
        cloud = c
        // 启动时主动取一次：同步引擎没收到推送时，启动不会自己去取（日志里写“没有要做的事”）
        c.fetchNow()
        // 别的设备改了，iCloud 用静默推送通知这台设备来取（同步引擎自己处理推送）
        #if os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #else
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    /// 正在首次初始化：网络恢复和“重试”同时来时只跑一轮
    @ObservationIgnored private var initRunning = false

    func runInitialization() async {
        guard !initRunning else { return }
        initRunning = true
        defer { initRunning = false }
        phase = .initializing(attempt: 1, failed: false)
        let ok = await CatalogSync.initializeWithRetry(
            store: store, net: Network.shared,
            onAttempt: { [weak self] n in self?.phase = .initializing(attempt: n, failed: false) })
        if ok {
            loadHome()
            phase = .ready
            lastSyncAt = Date().timeIntervalSince1970 * 1000
            onReady?()
        } else {
            phase = .initializing(attempt: CatalogSync.initAttempts, failed: true)
        }
    }

    /// 从 v1.0 的 ExpoSQLiteStorage 读出线路相关的小偏好。只读一次（Apple TV 没有 v1.0，文件不在，直接跳过）。
    private func importV1Prefs() {
        guard !Prefs.d.bool(forKey: Prefs.kMigratedV1) else { return }
        defer { Prefs.d.set(true, forKey: Prefs.kMigratedV1) }
        guard FileManager.default.fileExists(atPath: files.v1KVPath.path), let kv = try? SQLiteDB(path: files.v1KVPath.path, readOnly: true) else { return }
        for key in [Prefs.kLastService, Prefs.kDomains] {
            if let v = (try? kv.first("SELECT value FROM storage WHERE key = ?", [key]))??.optStr("value") {
                if key == Prefs.kLastService ? isHttpsOrigin(v) : parseDomains(v) != nil { Prefs.d.set(v, forKey: key) }
            }
        }
    }

    func loadHome() {
        home = (try? store.loadHome()) ?? HomeData()
        catalogVersion += 1
        prefetchHomeCovers?(home)
    }

    /// 同步目录。userInitiated：主页下拉刷新。有新内容就立刻换上主页。
    /// 取 index.json 只有这几处：启动、切回前台（自动，主页顶栏显示“正在更新…”）、下拉刷新、刷新网络线路。
    /// 点开课程、在“最近”里点已下架的课都只看本机目录，不联网。
    @discardableResult
    func syncCatalog(userInitiated: Bool) async -> SyncSummary? {
        // 已经在更新（启动、回到前台时的自动更新）：等它做完，不另起一次；直接返回的话，下拉刷新的转圈会一闪就没
        if let running = inflightSync {
            let s = await running.value
            if userInitiated {
                loadHome()
                if s.failed { syncFailed = true }
            }
            return s
        }
        syncing = true
        if !userInitiated { autoUpdating = true }
        defer { syncing = false; autoUpdating = false }
        let task = Task { await CatalogSync.sync(store: store, net: Network.shared) }
        inflightSync = task
        let s = await task.value
        inflightSync = nil
        lastSyncAt = Date().timeIntervalSince1970 * 1000
        // 有新内容立刻换上；用户下拉刷新则完成后一律重读
        if userInitiated || s.changed { loadHome() }
        // 提示条：试遍线路仍失败、且连着网（用户主动刷新时不论有没有网都显示）
        if s.failed { syncFailed = userInitiated || Connectivity.shared.connected } else { syncFailed = false }
        return s
    }

    /// 回到前台：到时间了就自动更新目录，用户数据全部重读一次（在别处，比如锁屏上，可能变了）。
    func onForeground() {
        guard phase == .ready else { return }
        if shouldSyncOnForeground(now: Date().timeIntervalSince1970 * 1000, lastSyncAt: lastSyncAt, syncing: syncing) {
            Task { await syncCatalog(userInitiated: false) }
        }
        player.refreshSleepDisplay()
        progressVersion += 1; favoritesVersion += 1
        cloud?.fetchNow()
    }

    func onBackground() {
        player?.saveNow()
        cloud?.sendNow()
    }

    // MARK: 播放入口

    /// 点一集的行：开始播放并打开全屏播放页。
    func playAndOpen(_ episodeId: String, ctx: PlayContext) {
        if player.current?.episodeId == episodeId && !player.looksPlaying && player.error == nil { player.resume(); presentPlayer?(); return }
        if player.current?.episodeId == episodeId { presentPlayer?(); return }
        if player.start(episodeId, ctx: ctx) { presentPlayer?() } else { episodeGone(episodeId) }
    }

    /// 胶囊里的播放/暂停：原地，不跳页。
    func togglePlay(_ episodeId: String, ctx: PlayContext) {
        if player.current?.episodeId == episodeId { player.toggle(); return }
        if !player.start(episodeId, ctx: ctx) { episodeGone(episodeId) }
    }

    private func episodeGone(_ episodeId: String) {
        alert = AlertSpec(title: "这一集已下架")
    }

    /// “最近”里点某一集：目录里没有、也没下载过，就是已下架。
    func playFromRecent(_ row: RecentRow, open: Bool) {
        if !row.gone || store.getDownload(row.episodeId)?.state == .done {
            if open { playAndOpen(row.episodeId, ctx: .single) } else { togglePlay(row.episodeId, ctx: .single) }
            return
        }
        // 只看本机目录，不联网（只有启动和下拉刷新取 index.json）
        alert = AlertSpec(title: store.seriesExists(row.seriesId) ? "这一集已下架" : "这门课已下架")
    }

    // MARK: 进度、收藏

    func markCompleted(_ episodeId: String, seriesId: String, completed: Bool) {
        if completed { player.stopAsCompleted(episodeId) }
        let info = try? store.getEpisodeInfo(episodeId)
        try? store.markCompleted(
            episodeId, seriesId: seriesId, completed: completed, seriesTitle: info?.seriesTitle ?? "",
            episodeTitle: info?.episodeTitle ?? "", coverPath: info?.coverPath ?? "")
        progressVersion += 1
    }

    func hideRecent(_ episodeId: String) {
        try? store.hideFromRecent(episodeId)
        progressVersion += 1
    }

    func clearRecent() {
        try? store.clearRecent()
        progressVersion += 1
    }

    func toggleFavorite(_ seriesId: String, title: String, coverPath: String) {
        if store.isFavorite(seriesId) {
            try? store.removeFavorite(seriesId)
        } else {
            try? store.addFavorite(seriesId, title: title, coverPath: coverPath)
        }
        favoritesVersion += 1
    }

    func removeFavorite(_ seriesId: String) {
        try? store.removeFavorite(seriesId)
        favoritesVersion += 1
    }

    // MARK: 网络线路

    func refreshRoutes() async -> String {
        let (origin, same) = await Network.shared.refreshRoutes()
        guard origin != nil else { return "暂时无法连接" }
        _ = await syncCatalog(userInitiated: true)
        return same ? "线路正常" : "已切换到备用线路，连接正常"
    }
}
