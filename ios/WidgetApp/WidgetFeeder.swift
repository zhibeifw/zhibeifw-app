import SwiftUI
import WidgetKit
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// 给小组件备数据（iPhone / iPad 和 Mac 共用）：把继续播放、最新课程写进共享目录，再让系统刷新小组件。
/// 什么时候写：主页目录变了，换了一集、播放 / 暂停变了、读到这一集的时长（等 1 秒合并成一次），退到后台时，小组件的按钮执行完时。
/// 播放进度不跟着每 5 秒的保存写（在后台时系统限制刷新次数），退到后台、暂停时会带上最新进度。
@MainActor
final class WidgetFeeder {
    private let core: AppCore
    private var pending: Task<Void, Never>?
    private var started = false

    /// 每种列表最多几条：大号小组件放得下的数量
    private static let latestLimit = 7
    /// 写给小组件的封面宽度（像素）：大号小组件里最宽的封面约 160pt × 3 倍
    private static let coverPx = 480

    init(core: AppCore) { self.core = core }

    /// 进入主页后开始（数据库和目录都好了）
    func start() {
        WidgetLog.note("开始备数据：共享目录=\(WidgetStore.dir?.path ?? "没有")")
        guard !started, WidgetStore.dir != nil else { return }
        started = true
        // 启动时让系统重画一次：数据没变时不会刷新，App 升级后桌面上会一直是旧版画出来的样子（按钮还连着旧版的动作）。
        // App 在前台时刷新不占系统给的刷新次数
        WidgetCenter.shared.reloadAllTimelines()
        track()
        schedule()
    }

    private func track() {
        withObservationTracking {
            _ = core.catalogVersion
            _ = core.player?.current?.episodeId
            _ = core.player?.looksPlaying
            _ = core.player?.positionKnown
            // 刚开始播时还不知道时长，读到后再写一次（“剩余几分钟”）
            _ = (core.player?.duration ?? 0) > 0
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.schedule()
                self?.track()
            }
        }
    }

    func schedule() {
        guard started else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            // 开始写了就不再取消（取消会让取封面半途放弃，写出没有封面的数据）
            await Task { await self.write() }.value
        }
    }

    /// 小组件按钮执行完：只改“继续播放”这一条，只刷新有播放按钮的两个小组件（继续播放、最新课程），按钮马上变；
    /// 完整的数据随后照常再写一次。
    /// 封面用已经存好的（换成最新课程里的一集时，它的封面在那里已经存过）
    /// playing：按钮要切到的状态。不读播放器当时的状态：刚发出暂停 / 播放时它还没变过来，照它写的话小组件还是旧图标，
    /// 下一次点又会发出同一个动作，看起来像坏了
    func quickUpdateNowPlaying(playing: Bool) {
        guard started, let p = core.player, let c = p.current else { return }
        var snap = WidgetStore.read()
        let i = c.info
        let name = ImageLoader.diskName(i.coverPath) + ".jpg"
        let cover = WidgetStore.coverURL(name).map { FileManager.default.fileExists(atPath: $0.path) } == true ? name : nil
        let progress = playbackProgress(p)
        snap.nowPlaying = WidgetNowPlaying(
            item: WidgetItem(
                seriesId: i.seriesId, seriesTitle: i.seriesTitle, episodeId: i.episodeId, episodeTitle: i.episodeTitle,
                cover: cover, color: placeholderColor(i.seriesId).light),
            position: progress.position, duration: progress.duration, playing: playing, loaded: true)
        let changed = WidgetStore.write(snap)
        WidgetLog.note("按钮后写：\(i.seriesId) / \(i.episodeId) playing=\(playing) 变了=\(changed)")
        if changed {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.nowPlaying)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.latest)
        }
        schedule()
    }

    /// 马上写（退到后台）：等着的那次不用再写
    func writeNow() async {
        pending?.cancel()
        await write()
    }

    private func write() async {
        guard core.phase == .ready, let store = core.store else { return }
        var snap = WidgetSnapshot()
        snap.nowPlaying = nowPlaying(store)
        snap.origin = Network.shared.currentOrigin ?? Prefs.d.string(forKey: Prefs.kLastService)
        snap.catalogCheckedAt = core.lastSyncAt > 0 ? core.lastSyncAt : nil
        let old = WidgetStore.read()
        if let w = old.latestFromWidgetAt, w > core.lastSyncAt {
            // 小组件自己取到的新课程比 App 上次同步还新（App 很久没打开）：先用它，等 App 同步后再换成自己的
            snap.latest = old.latest
            snap.latestFromWidgetAt = w
        } else {
            snap.latest = core.home.ongoing.prefix(Self.latestLimit).compactMap { c in
                guard let e = store.lastEpisode(c.id) else { return nil }
                return item(c.id, c.title, c.coverPath, episodeId: e.id, episodeTitle: e.title)
            }
        }
        snap.latest = snap.latest.map { item in
            var item = item
            if let id = item.episodeId {
                if let current = snap.nowPlaying, current.item.episodeId == id {
                    item.progress = progressRatio(current.position, current.duration)
                } else if let progress = store.loadProgress(id) {
                    item.progress = progress.completed ? 1 : progressRatio(progress.position, progress.duration)
                }
            }
            return item
        }
        await prepareCovers(&snap)
        let changed = WidgetStore.write(snap)
        WidgetLog.note(
            "App 写：在播 \(snap.nowPlaying?.item.seriesId ?? "无") / \(snap.nowPlaying?.item.episodeId ?? "无") playing=\(snap.nowPlaying?.playing ?? false) 变了=\(changed)"
        )
        if changed { WidgetCenter.shared.reloadAllTimelines() }
    }

    private func playbackProgress(_ player: PlayerController) -> (position: Double, duration: Double) {
        let saved = player.current.flatMap { core.store?.loadProgress($0.episodeId) }
        return widgetPlaybackProgress(
            position: player.position, duration: player.duration, positionKnown: player.positionKnown,
            savedPosition: saved?.position, savedDuration: saved?.duration, completed: saved?.completed ?? false)
    }

    /// 正在播放的这一集；没在播就是最近播放里最近一条没听完的
    private func nowPlaying(_ store: Store) -> WidgetNowPlaying? {
        if let p = core.player, let c = p.current {
            let i = c.info
            let progress = playbackProgress(p)
            return WidgetNowPlaying(
                item: item(i.seriesId, i.seriesTitle, i.coverPath, episodeId: i.episodeId, episodeTitle: i.episodeTitle),
                position: progress.position, duration: progress.duration, playing: p.looksPlaying, loaded: true)
        }
        guard let r = ((try? store.loadRecent(limit: 20)) ?? []).first(where: { !$0.gone && !$0.progress.completed }) else { return nil }
        return WidgetNowPlaying(
            item: item(r.seriesId, r.seriesTitle, r.coverPath, episodeId: r.episodeId, episodeTitle: r.epTitle),
            position: r.progress.position, duration: r.progress.duration, playing: false, loaded: false)
    }

    /// cover 先放原路径，prepareCovers 换成共享目录里的文件名
    private func item(
        _ seriesId: String, _ title: String, _ coverPath: String, episodeId: String? = nil, episodeTitle: String? = nil
    )
        -> WidgetItem
    {
        WidgetItem(
            seriesId: seriesId, seriesTitle: title, episodeId: episodeId, episodeTitle: episodeTitle,
            cover: coverPath.isEmpty ? nil : coverPath, color: placeholderColor(seriesId).light)
    }

    private static func jpeg(_ img: PlatformImage) -> Data? {
        #if os(macOS)
            guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        #else
            img.jpegData(compressionQuality: 0.8)
        #endif
    }

    /// 把用到的封面缩小存进共享目录（已有的跳过），删掉不再用的；取不到的封面留空，小组件显示占位色
    private func prepareCovers(_ snap: inout WidgetSnapshot) async {
        guard let dir = WidgetStore.coversDir else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var names: [String: String?] = [:]
        let paths = Set(([snap.nowPlaying?.item].compactMap { $0 } + snap.latest).compactMap(\.cover))
        for path in paths {
            let name = ImageLoader.diskName(path) + ".jpg"
            let f = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: f.path) { names[path] = name; continue }
            if let img = await ImageLoader.shared.load(path, maxPixel: Self.coverPx), let d = Self.jpeg(img),
                (try? d.write(to: f, options: .atomic)) != nil
            {
                names[path] = name
            } else {
                names[path] = .some(nil)
            }
        }
        func fix(_ i: WidgetItem) -> WidgetItem {
            var i = i
            i.cover = i.cover.flatMap { names[$0] ?? nil }
            return i
        }
        if let np = snap.nowPlaying { snap.nowPlaying?.item = fix(np.item) }
        snap.latest = snap.latest.map(fix)
        let keep = Set(names.values.compactMap { $0 })
        for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !keep.contains(f) {
            try? fm.removeItem(at: dir.appendingPathComponent(f))
        }
    }
}
