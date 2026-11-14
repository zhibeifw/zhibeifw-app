import SwiftUI
import WatchKit

struct WatchPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppCore.self) private var core

    var body: some View {
        ScrollView {
            if let p = core.player, let current = p.current {
                VStack(spacing: Tok.Component.WatchPlayer.spacing) {
                    VStack(alignment: .leading) {
                        Text(current.info.episodeTitle).font(.headline).lineLimit(1)
                        Text(current.info.seriesTitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: Tok.Component.WatchPlayer.spacing) {
                        Button {
                            p.seek(by: -SEEK_BACK_SECONDS)
                        } label: {
                            Image(systemName: "gobackward.15")
                                .frame(width: Tok.Component.WatchPlayer.skipSize, height: Tok.Component.WatchPlayer.skipSize)
                        }.buttonStyle(.bordered).buttonBorderShape(.circle).accessibilityLabel("后退15秒")
                        Button {
                            p.toggle()
                        } label: {
                            Gauge(value: p.duration > 0 ? min(1, max(0, p.position / p.duration)) : 0) {
                                Text("播放进度")
                            } currentValueLabel: {
                                PlaybackLoadingView(loading: p.loadingPlayback) {
                                    Image(systemName: p.looksPlaying ? "pause.fill" : "play.fill").font(.title2)
                                }
                            }
                            .gaugeStyle(.accessoryCircularCapacity)
                            .tint(.primary)
                            .frame(width: Tok.Component.EpisodeRow.gaugeNative, height: Tok.Component.EpisodeRow.gaugeNative)
                            .scaleEffect(Tok.Component.WatchPlayer.playSize / Tok.Component.EpisodeRow.gaugeNative)
                            .frame(width: Tok.Component.WatchPlayer.playSize, height: Tok.Component.WatchPlayer.playSize)
                            .contentShape(Circle())
                        }.buttonStyle(.plain).accessibilityLabel(p.looksPlaying ? "暂停" : "播放")
                        Button {
                            p.seek(by: SEEK_FORWARD_SECONDS)
                        } label: {
                            Image(systemName: "goforward.30")
                                .frame(width: Tok.Component.WatchPlayer.skipSize, height: Tok.Component.WatchPlayer.skipSize)
                        }.buttonStyle(.bordered).buttonBorderShape(.circle).accessibilityLabel("前进30秒")
                    }
                    .font(.title2)
                    HStack {
                        NavigationLink {
                            WatchPlaybackRateView()
                        } label: {
                            Text(String(format: "%g×", p.rate)).monospacedDigit()
                                .fixedSize().frame(maxWidth: .infinity)
                        }.accessibilityLabel("播放速度，\(p.rate)倍")
                        NavigationLink {
                            WatchPlayerActionsView()
                        } label: {
                            Image(systemName: "ellipsis").frame(maxWidth: .infinity)
                        }.accessibilityLabel("更多播放选项")
                        NavigationLink {
                            WatchSleepTimerView()
                        } label: {
                            Image(systemName: p.sleep == .off ? "moon" : "moon.fill")
                                .frame(maxWidth: .infinity)
                        }.accessibilityLabel(p.sleep == .off ? "睡眠定时，关闭" : "睡眠定时，已启用")
                    }
                    .font(.callout)
                    .buttonStyle(.plain)
                    .frame(minHeight: Tok.Component.WatchPlayer.actionHeight)
                    if p.error != nil {
                        Button("重试播放", systemImage: "arrow.clockwise") { p.retry() }
                    }
                }
            } else {
                ContentUnavailableView("尚未播放", systemImage: "play.circle", description: Text("选择一节课开始收听"))
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
            }
        }
        .task {
            while !Task.isCancelled {
                core.player?.refreshSleepDisplay()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct WatchPlaybackRateView: View {
    @Environment(AppCore.self) private var core
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            ForEach(PLAYBACK_RATES, id: \.self) { rate in
                Button {
                    core.player.setRate(rate)
                    dismiss()
                } label: {
                    HStack {
                        Text(rateMenuTitle(rate))
                        Spacer()
                        if core.player.rate == rate { Image(systemName: "checkmark") }
                    }
                }
            }
        }.navigationTitle("播放速度")
    }
}

private struct WatchSleepTimerView: View {
    @Environment(AppCore.self) private var core
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            ForEach(SLEEP_CHOICES) { choice in
                Button {
                    core.player.setSleep(sleepSetting(choice))
                    dismiss()
                } label: {
                    HStack {
                        Text(choice.title)
                        Spacer()
                        if core.player.sleep.choiceId == choice.id { Image(systemName: "checkmark") }
                    }
                }
            }
        }.navigationTitle("睡眠定时")
    }
}

private struct WatchPlayerFactsKey: Equatable {
    let episodeId: String?
    let versions: [Int]
}

struct WatchPlayerActionsView: View {
    @Environment(AppCore.self) private var core
    @Environment(WatchModel.self) private var model
    @State private var completed = false
    @State private var favorite = false
    @State private var download: DlRow?
    var body: some View {
        List {
            if let current = core.player.current {
                if core.player.error != nil { Button("重试播放", systemImage: "arrow.clockwise") { core.player.retry() } }
                WatchDownloadActionRows(id: current.episodeId, download: download) {
                    model.confirm("删除此下载？", message: "将停止当前播放，保留收听进度。") {
                        model.deleteDownloads([current.episodeId])
                    }
                }
                Button(
                    completed ? "标记为未听完" : "标记为已听完",
                    systemImage: completed ? "rectangle.badge.minus" : "rectangle.badge.checkmark"
                ) {
                    core.markCompleted(current.episodeId, seriesId: current.seriesId, completed: !completed)
                }
                Button(
                    favorite ? "取消收藏这门课" : "收藏这门课",
                    systemImage: favorite ? "bookmark.fill" : "bookmark"
                ) {
                    core.toggleFavorite(current.seriesId, title: current.info.seriesTitle, coverPath: current.info.coverPath)
                }
                Button("前往课程", systemImage: "arrow.forward.circle") { model.showSeries(current.seriesId) }
            }
        }
        .navigationTitle("更多操作")
        .task(id: WatchPlayerFactsKey(episodeId: core.player.current?.episodeId, versions: model.versions)) {
            guard let current = core.player.current else { return }
            completed = core.store.loadProgress(current.episodeId)?.completed ?? false
            favorite = core.store.isFavorite(current.seriesId)
            download = core.store.getDownload(current.episodeId)
        }
    }
}

/// 单集下载入口共用系统按钮与侧滑操作，避免播放页和课程页出现不同的操作规则。
struct WatchDownloadActionRows: View {
    let id: String
    let download: DlRow?
    var canDownload = true
    var title: String? = nil
    var playDownloaded: (() -> Void)? = nil
    let delete: () -> Void
    @Environment(WatchModel.self) private var model

    var body: some View {
        switch model.downloads?.items[id]?.status ?? download?.state {
        case .done:
            if let title {
                Button {
                    playDownloaded?()
                } label: {
                    HStack {
                        Text(title)
                        Spacer()
                        Image(systemName: "arrow.down.circle.fill")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("播放\(title)，已下载")
                .swipeActions {
                    Button(role: .destructive, action: delete) {
                        Label("删除下载", systemImage: "trash")
                    }
                }
            } else {
                Button(role: .destructive, action: delete) {
                    Label("删除下载", systemImage: "trash")
                }
            }
        case .queued, .downloading, .paused:
            let paused = (model.downloads?.items[id]?.status ?? download?.state) == .paused
            let ratio = model.downloads?.ratio(id) ?? 0
            Button {
                if paused {
                    if let download { model.download([download.item]) }
                } else {
                    model.downloads?.pause(id)
                }
            } label: {
                HStack {
                    if let title { Text(title); Spacer() }
                    Gauge(value: ratio) {
                        EmptyView()
                    } currentValueLabel: {
                        Image(systemName: paused ? "arrow.down" : "pause.fill")
                            .font(.title2)
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .frame(width: Tok.Component.EpisodeRow.gaugeNative, height: Tok.Component.EpisodeRow.gaugeNative)
                    .scaleEffect(Tok.Component.EpisodeRow.ring / Tok.Component.EpisodeRow.gaugeNative)
                    .frame(width: Tok.Component.EpisodeRow.ring, height: Tok.Component.EpisodeRow.ring)
                    .accessibilityHidden(true)
                    if title == nil {
                        Text(paused ? "继续下载" : "暂停下载")
                        Spacer()
                    }
                    Text(ratio, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
            }
            .accessibilityLabel("\(title ?? "下载")，\(paused ? "继续下载" : "暂停下载")，\(ratio.formatted(.percent.precision(.fractionLength(0))))")
            .swipeActions {
                Button(role: .destructive) {
                    model.downloads?.cancel(id)
                } label: {
                    Label("取消下载", systemImage: "xmark")
                }
            }
        case nil:
            if canDownload {
                Button {
                    model.download(Set([id]))
                } label: {
                    if let title {
                        HStack {
                            Text(title)
                            Spacer()
                            Image(systemName: "arrow.down.circle")
                        }
                    } else {
                        Label("下载这一集", systemImage: "arrow.down.circle")
                    }
                }.accessibilityLabel("下载\(title ?? "这一集")")
            }
        }
    }
}
