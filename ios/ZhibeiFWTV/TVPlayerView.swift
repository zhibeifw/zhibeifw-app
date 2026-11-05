import SwiftUI

/// 全屏播放页：照 iPhone 横屏的播放页做（左边封面，右边控制区），按电视放大。
/// 右边从上到下：集名、“课程名 ›”（前往课程）和“•••”更多；进度条；时间（左已播，右剩余 / 睡眠定时）；
/// 控制行：倍速、后退 15 秒、播放暂停、前进 30 秒、睡眠定时。图标用和 iPhone 一样的共用图标。
/// 电视上没有手指拖动：进度条可以选中，选中后按左右键后退 15 秒、前进 30 秒。
/// 遥控器的播放/暂停键随时可用（PlayerController 注册的系统远程命令）；返回键收起播放页，声音照常播。
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
            .onExitCommand { dismiss() }
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

    private var p: PlayerController { player }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 集名、“课程名 ›”；右边“•••”
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(now.info.episodeTitle).font(.title2).fontWeight(.bold).foregroundStyle(C.labelPrimary).lineLimit(2)
                    Button { model.goToSeries(now.seriesId) } label: {
                        HStack(spacing: 6) {
                            Text(now.info.seriesTitle).lineLimit(1)
                            ZIcon(name: "chevron-forward", size: 22, color: C.labelSecondary)
                        }
                        .font(.callout).foregroundStyle(C.labelSecondary)
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
                TVProgressBar(player: p).padding(.top, 48)
                HStack {
                    Text(clock(p.position))
                    Spacer()
                    Text(rightLabel)
                }
                .font(.callout).monospacedDigit().foregroundStyle(C.labelSecondary)
                .padding(.top, 14)
                controlRow.padding(.top, 56)
            }
        }
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
            Menu {
                ForEach(PLAYBACK_RATES, id: \.self) { r in
                    Button { p.setRate(r) } label: { checkLabel(rateMenuTitle(r), p.rate == r) }
                }
            } label: {
                Text(String(format: "%g×", p.rate)).font(.headline).foregroundStyle(C.labelSecondary).frame(minWidth: 72)
            }
            Spacer()
            Button { p.seek(by: -SEEK_BACK_SECONDS) } label: { SeekIcon(forward: false, size: 64) }
                .accessibilityLabel("后退 \(Int(SEEK_BACK_SECONDS)) 秒")
            Spacer()
            Button { p.toggle() } label: { ZIcon(name: p.looksPlaying ? "pause" : "play", size: 84) }
                .accessibilityLabel(p.looksPlaying ? "暂停" : "播放")
            Spacer()
            Button { p.seek(by: SEEK_FORWARD_SECONDS) } label: { SeekIcon(forward: true, size: 64) }
                .accessibilityLabel("前进 \(Int(SEEK_FORWARD_SECONDS)) 秒")
            Spacer()
            Menu {
                ForEach(SLEEP_CHOICES) { ch in
                    Button { p.setSleep(sleepSetting(ch)) } label: { checkLabel(ch.title, p.sleep.choiceId == ch.id) }
                }
            } label: {
                ZIcon(name: "moon", size: 40, color: p.sleep == .off ? C.labelTertiary : C.labelPrimary).frame(minWidth: 72)
            }
            .accessibilityLabel("睡眠定时")
        }
        .buttonStyle(.borderless)
    }

    /// “•••”：标记已听完、收藏课程、前往课程（和 iPhone 一样；没有下载）
    private var moreMenu: some View {
        Menu {
            Button {
                core.markCompleted(now.episodeId, seriesId: now.seriesId, completed: !completed)
            } label: {
                Label(completed ? "标记为未听完" : "标记为已听完", systemImage: "checkmark.circle")
            }
            Button {
                core.toggleFavorite(now.seriesId, title: now.info.seriesTitle, coverPath: now.info.coverPath)
            } label: {
                Label(favorite ? "取消收藏课程" : "收藏课程", systemImage: favorite ? "bookmark.fill" : "bookmark")
            }
            Button { model.goToSeries(now.seriesId) } label: {
                Label("前往课程", systemImage: "arrow.forward.circle")
            }
        } label: {
            ZStack {
                Circle().fill(C.backgroundSecondary).frame(width: 72, height: 72)
                ZIcon(name: "ellipsis-horizontal", size: 36, color: C.labelPrimary)
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("更多操作")
    }

    /// 单选菜单里的一项：选中的打勾。
    @ViewBuilder private func checkLabel(_ title: String, _ checked: Bool) -> some View {
        if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func errorText(_ e: PlayerError) -> String {
        switch e {
        case .cannotPlay: "暂时无法播放，请检查网络后重试"
        case .damaged: "这一集的文件已损坏"
        case .gone: "这一集已下架"
        }
    }
}

/// 进度条：颜色和 iPhone 一样（progressFill / progressTrack）。可以选中：选中时变粗，左右键后退 15 秒、前进 30 秒。
private struct TVProgressBar: View {
    let player: PlayerController
    @FocusState private var focused: Bool

    var body: some View {
        let ratio = progressRatio(player.position, player.duration)
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Tok.Color.progressTrack.color)
                Capsule().fill(Tok.Color.progressFill.color).frame(width: max(0, g.size.width * ratio))
            }
        }
        .frame(height: focused ? 14 : 8)
        .animation(.easeOut(duration: 0.15), value: focused)
        .padding(.vertical, 12)
        .focusable()
        .focused($focused)
        .onMoveCommand { dir in
            switch dir {
            case .left: player.seek(by: -SEEK_BACK_SECONDS)
            case .right: player.seek(by: SEEK_FORWARD_SECONDS)
            default: break
            }
        }
        .accessibilityLabel("播放进度")
    }
}
