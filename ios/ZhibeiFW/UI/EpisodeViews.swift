import SwiftUI

/// 一集在列表里需要的全部信息（系列页、资料库第二层、最近共用）。
struct EpisodeItem: Identifiable, Equatable {
    var id: String { episodeId }
    var episodeId: String
    var seriesId: String
    var title: String
    var progress: Prog?
    var epDuration: Double?
    var dlState: DlStatus?
    var canDownload = true
}

extension AppModel {
    /// 正在播放的这一集用播放器的实时位置（liveProgress）。
    func liveProg(_ e: EpisodeItem) -> Prog? {
        // 先看是不是正在播的这一集：不是的话不读位置，列表里其它行不会跟着播放进度每半秒重画
        guard let p = player, p.current?.episodeId == e.episodeId else { return e.progress }
        return liveProgress(
            currentId: p.current?.episodeId, position: p.position, duration: p.duration,
            active: p.looksPlaying, episodeId: e.episodeId, fromDb: e.progress)
    }

    func dlStatus(_ e: EpisodeItem) -> (DlStatus?, Double) {
        if let d = downloads?.items[e.episodeId] { return (d.status, downloads.ratio(e.episodeId)) }
        return (e.dlState, e.dlState == .done ? 1 : 0)
    }

    /// 下载状态图标的点按：下载中＝暂停这一集；已暂停＝继续。
    func tapDownloadIndicator(_ e: EpisodeItem) {
        switch dlStatus(e).0 {
        case .queued, .downloading: downloads.pause(e.episodeId)
        case .paused: resumeDownloads(seriesId: e.seriesId, episodeId: e.episodeId)
        default: break
        }
    }

    func downloadItems(for e: EpisodeItem) -> [MenuItem] {
        downloadMenuItems(dlStatus(e).0, canDownload: e.canDownload).map { d in
            MenuItem(title: d.title, icon: d.icon, destructive: d.destructive) { [weak self] in self?.runDownloadAction(d.action, e) }
        }
    }

    func runDownloadAction(_ a: DlMenuAction, _ e: EpisodeItem) {
        switch a {
        // 资料库里的集可能已不在目录里：用下载记录里存的信息重新下（v1.0 这里误落到“标记已听完”的分支过）
        case .download: if let it = dlItem(episodeId: e.episodeId) ?? store.getDownload(e.episodeId)?.item { download([it]) }
        case .pause: downloads.pause(e.episodeId)
        case .resume: resumeDownloads(seriesId: e.seriesId, episodeId: e.episodeId)
        case .cancel: downloads.cancel(e.episodeId)
        case .delete: deleteDownload(e.episodeId)
        }
    }

    func completedNow(_ e: EpisodeItem) -> Bool { liveProg(e)?.completed ?? false }

    func markItem(_ e: EpisodeItem) -> MenuItem {
        let done = completedNow(e)
        return MenuItem(title: done ? "标记为未听完" : "标记为已听完", icon: done ? "rectangle.badge.minus" : "rectangle.badge.checkmark") { [weak self] in
            self?.markCompleted(e.episodeId, seriesId: e.seriesId, completed: !done)
        }
    }

    func goCourseItem(_ seriesId: String) -> MenuItem {
        MenuItem(title: "前往课程", icon: "arrow-forward-circle-outline") { [weak self] in self?.nav.push(.series(seriesId)) }
    }

}

/// 集数行：标题 + 操作行（播放胶囊、下载状态、“•••”）。
struct EpisodeRowView: View {
    var item: EpisodeItem
    var ctx: PlayContext
    var showDownloadedIcon = true
    var menuGroups: (EpisodeItem) -> [[MenuItem]]
    @Environment(AppModel.self) private var model
    @Environment(\.windowWidth) private var W

    var body: some View {
        let prog = model.liveProg(item)
        let state = pillState(prog, knownDuration: item.epDuration ?? 0)
        let isCurrent = model.player?.current?.episodeId == item.episodeId
        let playing = isCurrent && (model.player?.looksPlaying ?? false)
        let (dl, ratio) = model.dlStatus(item)
        Button {
            model.playAndOpen(item.episodeId, ctx: ctx)
        } label: {
            VStack(alignment: .leading, spacing: CP.EpisodeRow.titleToActions) {
                Text(item.title).zFont(S.listRowTitle).foregroundStyle(C.labelPrimary).lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: CP.EpisodeRow.statusGap) {
                    PlayPill(
                        state: state, ratio: prog.map { progressRatio($0.position, $0.duration) } ?? 0, playing: playing, loading: playing && (model.player?.loadingPlayback ?? false),
                        onIcon: { model.togglePlay(item.episodeId, ctx: ctx) },
                        onBody: { model.playAndOpen(item.episodeId, ctx: ctx) })
                    if dl != .done || showDownloadedIcon {
                        DownloadIndicator(status: dl, ratio: ratio) { model.tapDownloadIndicator(item) }
                    }
                    Spacer(minLength: 0)
                    MoreButton { menuGroups(item) }
                }
            }
            .padding(.vertical, CP.EpisodeRow.paddingV)
            .padding(.horizontal, Layout.pageMargin(W))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .overlay(alignment: .bottom) { Separator().padding(.horizontal, Layout.pageMargin(W)) }
        .accessibilityElement(children: .contain)
    }
}

/// 单集行 H3（最近）：封面缩略图 + “课程名 单集标题” + 操作行。
struct RecentRowView: View {
    var row: RecentRow
    @Environment(AppModel.self) private var model
    @Environment(\.windowWidth) private var W

    var item: EpisodeItem {
        EpisodeItem(
            episodeId: row.episodeId, seriesId: row.seriesId, title: row.epTitle, progress: row.progress,
            epDuration: row.epDuration, dlState: row.dlState, canDownload: !row.gone && row.audioPath != nil)
    }

    var body: some View {
        let it = item
        let prog = model.liveProg(it)
        let state = pillState(prog, knownDuration: it.epDuration ?? 0)
        let playing = model.player?.current?.episodeId == row.episodeId && (model.player?.looksPlaying ?? false)
        let (dl, ratio) = model.dlStatus(it)
        let m = Layout.pageMargin(W)
        Button {
            model.playFromRecent(row, open: true)
        } label: {
            HStack(alignment: .top, spacing: CP.RecentRow.gap) {
                CoverImage(
                    path: row.coverPath, colorId: row.seriesId, radius: Tok.Radius.thumbnail,
                    localFile: model.files.coverFile(seriesId: row.seriesId)
                )
                .frame(width: CP.RecentRow.thumbWidth, height: CP.RecentRow.thumbHeight)
                VStack(alignment: .leading, spacing: CP.RecentRow.actionsTop) {
                    Text("\(row.seriesTitle) \(row.epTitle)").zFont(S.listRowTitle).foregroundStyle(C.labelPrimary).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: CP.EpisodeRow.statusGap) {
                        PlayPill(
                            state: state, ratio: prog.map { progressRatio($0.position, $0.duration) } ?? 0, playing: playing, loading: playing && (model.player?.loadingPlayback ?? false),
                            onIcon: { model.playFromRecent(row, open: false) }, onBody: { model.playFromRecent(row, open: true) })
                        DownloadIndicator(status: dl, ratio: ratio) { model.tapDownloadIndicator(it) }
                        Spacer(minLength: 0)
                        MoreButton {
                            [
                                model.downloadItems(for: it) + [model.markItem(it), model.goCourseItem(row.seriesId)],
                            ]
                        }
                    }
                }
            }
            .padding(.vertical, CP.RecentRow.paddingV)
            .padding(.horizontal, m)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .overlay(alignment: .bottom) { Separator() }
    }
}
