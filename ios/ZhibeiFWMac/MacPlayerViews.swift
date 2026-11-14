import SwiftUI

/// 播放控制始终留在浏览窗口，附加操作使用系统菜单。
struct MacMiniPlayer: View {
    @Environment(AppCore.self) private var core
    @Environment(MacModel.self) private var model
    @State private var favorite = false
    @State private var completed = false

    var body: some View {
        if let p = core.player, let current = p.current {
            VStack {
                HStack(spacing: Tok.Component.MacMiniPlayer.controlSpacing) {
                    Menu {
                        ForEach(PLAYBACK_RATES, id: \.self) { rate in
                            Toggle(rateMenuTitle(rate), isOn: Binding(get: { p.rate == rate }, set: { _ in p.setRate(rate) }))
                        }
                    } label: {
                        Text(String(format: "%g×", p.rate)).monospacedDigit()
                            .font(.title3)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .accessibilityLabel("播放速度")
                    .font(.title3)
                    .frame(width: Tok.Component.MacMiniPlayer.rateWidth, height: Tok.Component.MacMiniPlayer.controlSize)
                    Button("后退15秒", systemImage: "gobackward.15") { p.seek(by: -SEEK_BACK_SECONDS) }
                        .frame(width: Tok.Component.MacMiniPlayer.controlSize, height: Tok.Component.MacMiniPlayer.controlSize)
                    Button {
                        p.toggle()
                    } label: {
                        PlaybackLoadingView(loading: p.loadingPlayback) {
                            Label(p.looksPlaying ? "暂停" : "播放", systemImage: p.looksPlaying ? "pause.fill" : "play.fill")
                        }
                    }

                    .frame(width: Tok.Component.MacMiniPlayer.controlSize, height: Tok.Component.MacMiniPlayer.controlSize)
                    Button("前进30秒", systemImage: "goforward.30") { p.seek(by: SEEK_FORWARD_SECONDS) }
                        .frame(width: Tok.Component.MacMiniPlayer.controlSize, height: Tok.Component.MacMiniPlayer.controlSize)
                    Menu {
                        ForEach(SLEEP_CHOICES) { choice in
                            Toggle(
                                choice.title,
                                isOn: Binding(
                                    get: { p.sleep.choiceId == choice.id },
                                    set: { _ in p.setSleep(sleepSetting(choice)) }
                                ))
                        }
                    } label: {
                        Image(systemName: p.sleep == .off ? "moon" : "moon.fill")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .accessibilityLabel("睡眠定时")
                    .help(p.sleep == .off ? "睡眠定时" : sleepLabel(p.sleep == .end ? nil : p.sleepLeft ?? 0))
                    .frame(width: Tok.Component.MacMiniPlayer.controlSize, height: Tok.Component.MacMiniPlayer.controlSize)
                    MacPlaybackInfo(player: p) {
                        HStack(spacing: Tok.Component.MacMiniPlayer.spacing) {
                            CoverImage(
                                path: current.info.coverPath, colorId: current.seriesId, radius: Tok.Component.MacMiniPlayer.infoRadius
                            )
                            .frame(width: Tok.Component.MacMiniPlayer.artworkWidth, height: Tok.Component.MacMiniPlayer.artworkHeight)
                            VStack(alignment: .leading, spacing: 0) {
                                Button {
                                    model.goToSeries(current.seriesId)
                                } label: {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(current.info.episodeTitle).font(.headline).lineLimit(1)
                                        Text(current.info.seriesTitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .help("前往课程")

                            }

                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .padding(.horizontal, Tok.Component.MacMiniPlayer.padding)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: Tok.Component.MacMiniPlayer.infoMaxWidth)
                    Menu {
                        Button {
                            core.markCompleted(current.episodeId, seriesId: current.seriesId, completed: !completed)
                        } label: {
                            Label(
                                completed ? "标记为未听完" : "标记为已听完",
                                systemImage: completed ? "rectangle.badge.minus" : "rectangle.badge.checkmark"
                            ).labelStyle(.titleAndIcon)
                        }
                        Button {
                            core.toggleFavorite(
                                current.seriesId, title: current.info.seriesTitle, coverPath: current.info.coverPath)
                        } label: {
                            Label(favorite ? "取消收藏课程" : "收藏课程", systemImage: favorite ? "bookmark.fill" : "bookmark").labelStyle(
                                .titleAndIcon)
                        }
                        Button {
                            model.goToSeries(current.seriesId)
                        } label: {
                            Label("前往课程", systemImage: "arrow.forward.circle").labelStyle(.titleAndIcon)
                        }
                    } label: {
                        Label("更多操作", systemImage: "ellipsis")
                            .font(.system(size: Tok.Component.MacMiniPlayer.controlIconSize, weight: .bold))
                            .frame(width: Tok.Component.MacMiniPlayer.controlSize, height: Tok.Component.MacMiniPlayer.controlSize)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)

                }
                .font(.system(size: Tok.Component.MacMiniPlayer.controlIconSize))
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                if let error = p.error {
                    HStack {
                        Text(error == .gone ? "这一集已下架" : error == .damaged ? "这一集的文件已损坏" : "暂时无法播放，请检查网络后重试")
                        if error == .cannotPlay { Button("重试", systemImage: "arrow.clockwise") { p.retry() } }
                    }
                    .foregroundStyle(C.danger)
                }
            }
            .padding(.horizontal, Tok.Component.MacMiniPlayer.padding)
            .padding(.vertical, Tok.Component.MacMiniPlayer.verticalPadding)
            .frame(maxWidth: Tok.Component.MacMiniPlayer.width)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(MacMiniPlayerGlass())
            .padding(Tok.Component.MacMiniPlayer.padding)
            .frame(maxWidth: .infinity)
            .task(id: "\(current.episodeId)|\(core.progressVersion)|\(core.favoritesVersion)") {
                favorite = core.store.isFavorite(current.seriesId)
                completed = core.store.loadProgress(current.episodeId)?.completed ?? false
            }
            .task {
                while !Task.isCancelled {
                    p.refreshSleepDisplay()
                    try? await Task.sleep(for: .seconds(1))
                }
            }

        }
    }
}

private struct MacPlaybackSliderStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.sliderThumbVisibility(.hidden)
        } else {
            content
        }
    }
}

private struct MacMiniPlayerGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

let CONTACT_EMAIL = "hello@zhibeifw.com"

/// 关于窗口：设置与关于两个分组，下方居中显示应用名称和版本。
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
            Form {
                Section("设置") {
                    LabeledContent("清除缓存") {
                        Button(clearing ? "正在清除…" : (clearResult ?? "清除"), systemImage: "internaldrive") { clearCache() }.disabled(clearing)
                    }
                    LabeledContent("刷新网络线路") {
                        Button(checking ? "正在检测…" : (routeResult ?? "刷新"), systemImage: "arrow.clockwise") { refreshRoutes() }.disabled(
                            checking)
                    }
                    if model.updates.channel == .site {
                        LabeledContent("检查更新") {
                            Button(checkingUpdate ? "正在检查…" : (updateResult ?? "检查"), systemImage: "arrow.triangle.2.circlepath") {
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
                Section("关于") {
                    LabeledContent("联系") {
                        Button(CONTACT_EMAIL, systemImage: "envelope") { if let u = URL(string: "mailto:\(CONTACT_EMAIL)") { openURL(u) } }
                    }
                    LabeledContent("隐私政策") { Button("打开", systemImage: "hand.raised") { openURL(NetConfig.privacyURL) } }
                    LabeledContent("源代码") {
                        Button("打开", systemImage: "chevron.left.forwardslash.chevron.right") { openURL(NetConfig.sourceURL) }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 420)
            VStack(spacing: 4) {
                Text("智悲佛网")
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

private struct MacPlaybackInfo<Metadata: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let player: PlayerController
    @ViewBuilder var metadata: Metadata
    @State private var dragging: Double?
    @State private var hovering = false
    @State private var editing = false
    private var expanded: Bool { hovering || editing }

    var body: some View {
        ZStack(alignment: .bottom) {
            metadata
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .offset(y: Tok.Component.MacMiniPlayer.metadataOffset)
                .opacity(expanded ? 0 : 1)
                .allowsHitTesting(!expanded)
            VStack(spacing: 0) {
                HStack {
                    Text(clock(dragging ?? player.position))
                    Spacer()
                    Text(remainingClock(dragging ?? player.position, player.duration))
                }
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .opacity(expanded ? 1 : 0)
                .accessibilityHidden(!expanded)
                slider
                    .controlSize(.regular)
                    .scaleEffect(x: 1, y: expanded ? 1 : Tok.Component.MacMiniPlayer.idleProgressScale)
                    .onHover { active in
                        if active { hovering = true }
                    }
            }
            .offset(y: expanded ? -Tok.Component.MacMiniPlayer.progressLift : Tok.Component.MacMiniPlayer.idleTrackOffset)
        }
        .frame(height: Tok.Component.MacMiniPlayer.infoHeight)
        .contentShape(Rectangle())
        // 滑块动画不改变退出边界，避免展开与收起相互触发。
        .onHover { if !$0 { hovering = false } }
        .animation(reduceMotion ? nil : .easeInOut, value: expanded)
        .onChange(of: player.current?.episodeId) { _, _ in dragging = nil }
    }

    private var slider: some View {
        Slider(value: Binding(get: { dragging ?? player.position }, set: { dragging = $0 }), in: 0...max(1, player.duration)) { active in
            editing = active
            if !active, let target = dragging {
                player.seek(to: target)
                dragging = nil
            }
        }
        .modifier(MacPlaybackSliderStyle())
        .disabled(player.duration <= 0)
        .accessibilityLabel("播放进度")
        .accessibilityValue(clock(dragging ?? player.position) + "，剩余" + remainingClock(dragging ?? player.position, player.duration))
    }
}
