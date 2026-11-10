import SwiftUI

/// 工具栏中间的播放控制：后退 15、播放暂停、前进 30，旁边是封面小图和集名（点了打开播放页）。
/// 没有在播的一集时按钮不可用，显示“未在播放”。
struct MacNowPlayingBar: View {
    @Environment(AppCore.self) private var core
    @Environment(MacModel.self) private var model

    var body: some View {
        let p = core.player
        let c = p?.current
        HStack(spacing: 12) {
            Button { p?.seek(by: -SEEK_BACK_SECONDS) } label: {
                Image(systemName: "gobackward.\(Int(SEEK_BACK_SECONDS))")
            }
            .help("后退 \(Int(SEEK_BACK_SECONDS)) 秒")
            Button { p?.toggle() } label: {
                PlaybackLoadingView(loading: p?.loadingPlayback ?? false) {
                    Image(systemName: p?.looksPlaying == true ? "pause.fill" : "play.fill")
                }
            }
            .help(p?.looksPlaying == true ? "暂停" : "播放")
            Button { p?.seek(by: SEEK_FORWARD_SECONDS) } label: {
                Image(systemName: "goforward.\(Int(SEEK_FORWARD_SECONDS))")
            }
            .help("前进 \(Int(SEEK_FORWARD_SECONDS)) 秒")
            Button { model.playerOpen = true } label: {
                HStack(spacing: 8) {
                    if let c {
                        CoverImage(path: c.info.coverPath, colorId: c.seriesId, radius: 4)
                            .frame(width: 48, height: 27)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(c?.info.episodeTitle ?? "未在播放").lineLimit(1)
                        if let c { Text(c.info.seriesTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    .frame(width: 220, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .help("显示播放页")
            .disabled(c == nil)
        }
        .disabled(c == nil)
        .foregroundStyle(c == nil ? .secondary : .primary)
    }
}

/// 播放页（点工具栏的集名或按 ⇧⌘P 打开，铺满整个窗口）：左边封面，右边集名、“课程名 ›”、“•••”，进度条（系统滑块），时间，
/// 控制行：倍速、后退 15、播放暂停、前进 30、睡眠定时。全部是系统组件。窗口变大时整体等比放大，窗口很窄时改成上下排。
/// 打开时窗口工具栏藏起来，播放页占满整个窗口；左上角圈 X（红黄绿按钮下面）或 Esc 关闭，声音照常播。
struct MacPlayerView: View {
    @Environment(AppCore.self) private var core
    @Environment(MacModel.self) private var model

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                C.background.ignoresSafeArea()
                Group {
                    if let p = core.player, let c = p.current {
                        let wide = g.size.width >= 900
                        let coverW = wide ? min(g.size.width * 0.42, 720) : min(g.size.width - 80, 560)
                        let controlsW = wide ? min(g.size.width * 0.34, 520) : coverW
                        let layout = wide ? AnyLayout(HStackLayout(alignment: .center, spacing: 48)) : AnyLayout(VStackLayout(spacing: 28))
                        layout {
                            CoverImage(path: c.info.coverPath, colorId: c.seriesId, radius: 14)
                                .frame(width: coverW, height: MacLayout.coverHeight(coverW))
                                .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
                            MacPlayerControls(player: p, now: c)
                                .frame(width: controlsW)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // 睡眠定时的倒计时每秒刷新一次（和 iPhone 一样）
                        .task {
                            while !Task.isCancelled {
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                                p.refreshSleepDisplay()
                            }
                        }
                    } else {
                        Text("还没有在播放的内容").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                Button { model.playerOpen = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)  // Esc
                .help("关闭播放页 (Esc)")
                .accessibilityLabel("关闭播放页")
                .padding(.leading, 20)
                .padding(.top, 12)
            }
        }
    }
}

private struct MacPlayerControls: View {
    @Environment(AppCore.self) private var core
    @Environment(MacModel.self) private var model
    let player: PlayerController
    let now: NowPlaying
    @State private var favorite = false
    @State private var completed = false
    /// 拖进度条时的位置：拖动中只更新显示，松开才跳过去
    @State private var dragging: Double?

    private var p: PlayerController { player }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(now.info.episodeTitle).font(.largeTitle).fontWeight(.bold).lineLimit(2)
                    Button { model.goToSeries(now.seriesId) } label: {
                        HStack(spacing: 4) {
                            Text(now.info.seriesTitle).lineLimit(1)
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("前往课程")
                }
                Spacer(minLength: 8)
                Menu {
                    Button(completed ? "标记为未听完" : "标记为已听完") {
                        core.markCompleted(now.episodeId, seriesId: now.seriesId, completed: !completed)
                    }
                    Button(favorite ? "取消收藏课程" : "收藏课程") {
                        core.toggleFavorite(now.seriesId, title: now.info.seriesTitle, coverPath: now.info.coverPath)
                    }
                    Button("前往课程") { model.goToSeries(now.seriesId) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("更多操作")
            }
            if let err = p.error {
                Text(errorText(err)).foregroundStyle(C.danger)
                if err == .cannotPlay { Button("重试") { p.retry() } }
            } else {
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(get: { dragging ?? p.position }, set: { dragging = $0 }),
                        in: 0...max(p.duration, 1)
                    ) { editing in
                        if !editing, let t = dragging { p.seek(to: t); dragging = nil }
                    }
                    .disabled(p.duration <= 0)
                    .accessibilityLabel("播放进度")
                    HStack {
                        Text(clock(dragging ?? p.position))
                        Spacer()
                        Text(rightLabel)
                    }
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                controlRow
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
                    Toggle(rateMenuTitle(r), isOn: Binding(get: { p.rate == r }, set: { _ in p.setRate(r) }))
                }
            } label: {
                Text(String(format: "%g×", p.rate)).monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("播放速度 \(String(format: "%g", p.rate)) 倍")
            Spacer()
            Button { p.seek(by: -SEEK_BACK_SECONDS) } label: {
                Image(systemName: "gobackward.\(Int(SEEK_BACK_SECONDS))").font(.title2)
            }
            .accessibilityLabel("后退 \(Int(SEEK_BACK_SECONDS)) 秒")
            Spacer()
            Button { p.toggle() } label: {
                PlaybackLoadingView(loading: p.loadingPlayback) {
                    Image(systemName: p.looksPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 44))
                }
            }
            .accessibilityLabel(p.looksPlaying ? "暂停" : "播放")
            Spacer()
            Button { p.seek(by: SEEK_FORWARD_SECONDS) } label: {
                Image(systemName: "goforward.\(Int(SEEK_FORWARD_SECONDS))").font(.title2)
            }
            .accessibilityLabel("前进 \(Int(SEEK_FORWARD_SECONDS)) 秒")
            Spacer()
            Menu {
                ForEach(SLEEP_CHOICES) { ch in
                    Toggle(ch.title, isOn: Binding(get: { p.sleep.choiceId == ch.id }, set: { _ in p.setSleep(sleepSetting(ch)) }))
                }
            } label: {
                Image(systemName: p.sleep == .off ? "moon" : "moon.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("睡眠定时")
        }
        .buttonStyle(.plain)
    }

    private func errorText(_ e: PlayerError) -> String {
        switch e {
        case .cannotPlay: "暂时无法播放，请检查网络后重试"
        case .damaged: "这一集的文件已损坏"
        case .gone: "这一集已下架"
        }
    }
}

let CONTACT_EMAIL = "hello@zhibeifw.com"

/// 关于智悲佛网（App 菜单第一项打开的窗口）：Logo、名字，下面：清除缓存、刷新网络线路、隐私政策、源代码、联系，最下面版权和版本。
/// Mac 上能打开网页、发邮件：隐私政策、源代码用浏览器打开，联系用邮件 App。官网版最后多一行“检查更新”（和 Android 官网版一样）。
struct MacAboutView: View {
    @Environment(AppCore.self) private var core
    @Environment(MacModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var checkingUpdate = false
    @State private var updateResult: String?
    @State private var clearing = false
    @State private var checking = false
    @State private var clearResult: String?
    @State private var routeResult: String?

    var body: some View {
        VStack(spacing: 16) {
            Image("Logo").resizable().scaledToFit().frame(width: 96).accessibilityLabel("智悲佛网 Logo")
            Text("智悲佛网").font(.title2).fontWeight(.semibold)
            Form {
                LabeledContent("清除缓存") {
                    Button(clearing ? "正在清除…" : (clearResult ?? "清除")) { clearCache() }.disabled(clearing)
                }
                LabeledContent("刷新网络线路") {
                    Button(checking ? "正在检测…" : (routeResult ?? "刷新")) { refreshRoutes() }.disabled(checking)
                }
                LabeledContent("隐私政策") { Button("打开") { openURL(NetConfig.privacyURL) } }
                LabeledContent("源代码") { Button("打开") { openURL(NetConfig.sourceURL) } }
                LabeledContent("联系") {
                    Button(CONTACT_EMAIL) { if let u = URL(string: "mailto:\(CONTACT_EMAIL)") { openURL(u) } }
                }
                // 只有官网版有（App Store 版的更新交给 App Store）
                if model.updates.channel == .site {
                    LabeledContent("检查更新") {
                        Button(checkingUpdate ? "正在检查…" : (updateResult ?? "检查")) {
                            guard !checkingUpdate else { return }
                            checkingUpdate = true
                            Task {
                                updateResult = await model.updates.check(manual: true)
                                checkingUpdate = false
                            }
                        }
                        .disabled(checkingUpdate)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 420)
            VStack(spacing: 4) {
                Text("智悲佛网 版权所有")
                Text("版本 " + AppInfo.version)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private func clearCache() {
        guard !clearing else { return }
        clearing = true
        Task {
            defer { clearing = false }
            do { try ImageLoader.shared.clear(); OriginWatcher.shared.bump(); clearResult = "已清除" } catch {
                clearResult = "清除失败"
            }
        }
    }

    private func refreshRoutes() {
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            routeResult = await core.refreshRoutes()
        }
    }
}
