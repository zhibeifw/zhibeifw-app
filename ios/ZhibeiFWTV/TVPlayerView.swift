import SwiftUI

/// 全屏播放页：照 iPhone 横屏的播放页做（左边封面，右边控制区），按电视放大。
/// 右边从上到下：集名、“课程名 ›”（前往课程）和“•••”更多；进度条；时间（左已播，右剩余 / 睡眠定时）；
/// 控制行：倍速、后退 15 秒、播放暂停、前进 30 秒、睡眠定时。全部是系统组件和系统图标（SF Symbols）。
/// 进度条是系统的 ProgressView，只显示进度（tvOS 没有系统滑块）；快退快进用下面的按钮。
/// 遥控器的播放/暂停键随时可用（PlayerController 注册的系统远程命令）；返回键由系统收起播放页，声音照常播。
struct TVPlayerView: View {
    @Environment(AppCore.self) private var core
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let p = core.player, let c = p.current {
            HStack(alignment: .center, spacing: 100) {
                CoverImage(path: c.info.coverPath, colorId: c.seriesId, radius: 24)
                    .frame(width: 880, height: TVLayout.coverHeight(880))
                    .shadow(color: scheme == .dark ? .clear : .black.opacity(0.18), radius: 20, y: 10)
                TVPlayerControls(player: p, now: c)
                    .frame(width: 720)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(C.background.ignoresSafeArea())
            // 睡眠定时的倒计时每秒刷新一次（和 iPhone 一样）
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    p.refreshSleepDisplay()
                }
            }
        } else {
            // 播放器停了（比如这一集被标为已听完）：没什么可显示的，收起
            Color.clear.onAppear { dismiss() }
        }
    }
}

private struct TVPlayerControls: View {
    @Environment(AppCore.self) private var core
    @Environment(TVModel.self) private var model
    let player: PlayerController
    let now: NowPlaying
    @State private var favorite = false
    @State private var completed = false
    /// 倍速、睡眠定时、“•••”：按下后弹系统的选项单。用 Menu 的话 tvOS 上焦点落不上去
    @State private var dialog: Dialog?
    private enum Dialog { case rate, sleep, more }

    private var p: PlayerController { player }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 集名、“课程名 ›”；右边“•••”
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(now.info.episodeTitle).font(.title2).fontWeight(.bold).lineLimit(2)
                    Button { model.goToSeries(now.seriesId) } label: {
                        HStack(spacing: 6) {
                            Text(now.info.seriesTitle).lineLimit(1)
                            Image(systemName: "chevron.right")
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                Spacer(minLength: 8)
                moreMenu
            }
            if let err = p.error {
                Text(errorText(err)).foregroundStyle(C.danger).padding(.top, 40)
                if err == .cannotPlay { Button("重试") { p.retry() }.padding(.top, 20) }
            } else {
                ProgressView(value: progressRatio(p.position, p.duration)).padding(.top, 48)
                HStack {
                    Text(clock(p.position))
                    Spacer()
                    Text(rightLabel)
                }
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .padding(.top, 14)
                controlRow.padding(.top, 56)
            }
        }
        .confirmationDialog(
            dialogTitle, isPresented: Binding(get: { dialog != nil }, set: { if !$0 { dialog = nil } }), titleVisibility: .visible
        ) { dialogButtons }
        // 收藏、已听完变了（或换了一集）才重读，不在每次进度刷新时读库
        .task(id: "\(now.episodeId)|\(core.progressVersion)|\(core.favoritesVersion)") {
            favorite = core.store.isFavorite(now.seriesId)
            completed = core.store.loadProgress(now.episodeId)?.completed ?? false
        }
    }

    private var rightLabel: String {
        switch p.sleep {
        case .end: return sleepLabel(nil)
        case .timer: return sleepLabel(p.sleepLeft ?? 0)
        case .off: return p.duration > 0 ? remainingClock(p.position, p.duration) : ""
        }
    }

    // 倍速 | 后退 15 | 播放暂停 | 前进 30 | 睡眠定时（和 iPhone 同样的顺序）
    private var controlRow: some View {
        HStack {
            // 纯文字的无边框按钮在 tvOS 上选中时几乎看不出来（只有图片会放大、高亮）：倍速单独用胶囊按钮
            Button { dialog = .rate } label: {
                Text(String(format: "%g×", p.rate)).font(.headline).monospacedDigit().frame(minWidth: 64)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .accessibilityLabel("播放速度 \(String(format: "%g", p.rate)) 倍")
            Spacer()
            Button { p.seek(by: -SEEK_BACK_SECONDS) } label: {
                Image(systemName: "gobackward.\(Int(SEEK_BACK_SECONDS))").font(.system(size: 56))
            }
                .accessibilityLabel("后退 \(Int(SEEK_BACK_SECONDS)) 秒")
            Spacer()
            Button { p.toggle() } label: {
                Image(systemName: p.looksPlaying ? "pause.fill" : "play.fill").font(.system(size: 72))
            }
                .accessibilityLabel(p.looksPlaying ? "暂停" : "播放")
            Spacer()
            Button { p.seek(by: SEEK_FORWARD_SECONDS) } label: {
                Image(systemName: "goforward.\(Int(SEEK_FORWARD_SECONDS))").font(.system(size: 56))
            }
                .accessibilityLabel("前进 \(Int(SEEK_FORWARD_SECONDS)) 秒")
            Spacer()
            Button { dialog = .sleep } label: {
                Image(systemName: p.sleep == .off ? "moon" : "moon.fill").font(.system(size: 40))
            }
            .accessibilityLabel("睡眠定时")
        }
        .buttonStyle(.borderless)
    }

    /// “•••”：标记已听完、收藏课程、前往课程（和 iPhone 一样；没有下载），按下后弹选项单
    private var moreMenu: some View {
        Button { dialog = .more } label: {
            Image(systemName: "ellipsis")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel("更多操作")
    }

    /// 选项单里的一项：选中的前面打勾。
    private func checked(_ title: String, _ on: Bool) -> String { on ? "✓ " + title : title }

    private var dialogTitle: String {
        switch dialog {
        case .rate: "播放速度"
        case .sleep: "睡眠定时"
        case .more, nil: now.info.episodeTitle
        }
    }

    @ViewBuilder private var dialogButtons: some View {
        switch dialog {
        case .rate:
            ForEach(PLAYBACK_RATES, id: \.self) { r in
                Button(checked(rateMenuTitle(r), p.rate == r)) { p.setRate(r) }
            }
        case .sleep:
            ForEach(SLEEP_CHOICES) { ch in
                Button(checked(ch.title, p.sleep.choiceId == ch.id)) { p.setSleep(sleepSetting(ch)) }
            }
        case .more:
            Button(completed ? "标记为未听完" : "标记为已听完") {
                core.markCompleted(now.episodeId, seriesId: now.seriesId, completed: !completed)
            }
            Button(favorite ? "取消收藏课程" : "收藏课程") {
                core.toggleFavorite(now.seriesId, title: now.info.seriesTitle, coverPath: now.info.coverPath)
            }
            Button("前往课程") { model.goToSeries(now.seriesId) }
        case nil:
            EmptyView()
        }
        Button("取消", role: .cancel) {}
    }

    private func errorText(_ e: PlayerError) -> String {
        switch e {
        case .cannotPlay: "暂时无法播放，请检查网络后重试"
        case .damaged: "这一集的文件已损坏"
        case .gone: "这一集已下架"
        }
    }
}
