import SwiftUI

/// 播放控制始终留在浏览窗口，附加操作使用系统弹出面板。
struct VisionMiniPlayer: View {
    @Environment(AppCore.self) private var core
    @Environment(VisionModel.self) private var model
    @State private var favorite = false
    @State private var completed = false
    @State private var morePresented = false
    @State private var ratePresented = false
    @State private var sleepPresented = false

    var body: some View {
        if let p = core.player, let current = p.current {
            VStack {
                HStack(spacing: Tok.Component.CompactPlayer.controlSpacing) {
                    Button { ratePresented = true } label: {
                        Text(String(format: "%g×", p.rate)).monospacedDigit()
                            .font(.title3)
                            .fixedSize(horizontal: true, vertical: false)
                            .visionHitTarget()
                    }
                    .popover(isPresented: $ratePresented, arrowEdge: .bottom) {
                        VisionPlayerOptions {
                            ForEach(PLAYBACK_RATES, id: \.self) { rate in
                                Button {
                                    p.setRate(rate)
                                    ratePresented = false
                                } label: {
                                    VisionPlayerOptionLabel(title: rateMenuTitle(rate), selected: p.rate == rate)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("播放速度")
                    .frame(width: Tok.Component.CompactPlayer.rateWidth, height: Tok.Component.Vision.hitSize)
                    .padding(.leading, Tok.Component.CompactPlayer.leadingInset)
                    Button { p.seek(by: -SEEK_BACK_SECONDS) } label: {
                        Label("后退15秒", systemImage: "gobackward.15").visionHitTarget()
                    }
                        .frame(width: Tok.Component.Vision.hitSize, height: Tok.Component.Vision.hitSize)
                    Button {
                        p.toggle()
                    } label: {
                        PlaybackLoadingView(loading: p.loadingPlayback) {
                            Label(p.looksPlaying ? "暂停" : "播放", systemImage: p.looksPlaying ? "pause.fill" : "play.fill")
                        }.visionHitTarget()
                    }

                    .frame(width: Tok.Component.Vision.hitSize, height: Tok.Component.Vision.hitSize)
                    Button { p.seek(by: SEEK_FORWARD_SECONDS) } label: {
                        Label("前进30秒", systemImage: "goforward.30").visionHitTarget()
                    }
                        .frame(width: Tok.Component.Vision.hitSize, height: Tok.Component.Vision.hitSize)
                    Button { sleepPresented = true } label: {
                        Image(systemName: p.sleep == .off ? "moon" : "moon.fill").visionHitTarget()
                    }
                    .popover(isPresented: $sleepPresented, arrowEdge: .bottom) {
                        VisionPlayerOptions {
                            ForEach(SLEEP_CHOICES) { choice in
                                Button {
                                    p.setSleep(sleepSetting(choice))
                                    sleepPresented = false
                                } label: {
                                    VisionPlayerOptionLabel(title: choice.title, selected: p.sleep.choiceId == choice.id)
                                }
                            }
                        }
                    }
                    .accessibilityLabel("睡眠定时")
                    .help(p.sleep == .off ? "睡眠定时" : sleepLabel(p.sleep == .end ? nil : p.sleepLeft ?? 0))
                    .frame(width: Tok.Component.Vision.hitSize, height: Tok.Component.Vision.hitSize)
                    VisionPlaybackInfo(player: p) {
                        HStack(spacing: Tok.Component.CompactPlayer.spacing) {
                            CoverImage(
                                path: current.info.coverPath, colorId: current.seriesId, radius: Tok.Component.CompactPlayer.infoRadius
                            )
                            .frame(width: Tok.Component.CompactPlayer.artworkWidth, height: Tok.Component.CompactPlayer.artworkHeight)
                            VStack(alignment: .leading, spacing: 0) {
                                Button {
                                    model.showSeries(current.seriesId)
                                } label: {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(current.info.episodeTitle).font(.title3).fontWeight(.semibold).lineLimit(1)
                                        Text(current.info.seriesTitle).font(.headline).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .visionHitTarget()
                                    .contentShape(Rectangle())
                                }
                                .help("前往课程")

                            }

                        }
                    }
                    .padding(.horizontal, Tok.Component.CompactPlayer.padding)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: Tok.Component.CompactPlayer.infoMaxWidth)
                    Button { morePresented = true } label: {
                        Label("更多操作", systemImage: "ellipsis")
                            .font(.system(size: Tok.Component.CompactPlayer.controlIconSize))
                            .visionHitTarget()
                    }
                    .popover(isPresented: $morePresented, arrowEdge: .bottom) {
                        VStack(spacing: Tok.Component.Vision.hitGap) {
                            Button {
                                morePresented = false
                                core.markCompleted(current.episodeId, seriesId: current.seriesId, completed: !completed)
                            } label: {
                                Label(completed ? "标记为未听完" : "标记为已听完",
                                      systemImage: completed ? "rectangle.badge.minus" : "rectangle.badge.checkmark")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .visionHitTarget()
                            }
                            Button {
                                morePresented = false
                                core.toggleFavorite(current.seriesId, title: current.info.seriesTitle, coverPath: current.info.coverPath)
                            } label: {
                                Label(favorite ? "取消收藏课程" : "收藏课程", systemImage: favorite ? "bookmark.fill" : "bookmark")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .visionHitTarget()
                            }
                            Button {
                                morePresented = false
                                model.showSeries(current.seriesId)
                            } label: {
                                Label("前往课程", systemImage: "arrow.forward.circle")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .visionHitTarget()
                            }
                        }
                        .font(.body)
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.plain)
                        .padding(Tok.Component.Vision.pageMargin)
                        .frame(width: Tok.Component.Vision.actionsWidth)
                    }

                }
                .font(.system(size: Tok.Component.CompactPlayer.controlIconSize))
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                if let error = p.error {
                    HStack {
                        Text(error == .gone ? "这一集已下架" : error == .damaged ? "这一集的文件已损坏" : "暂时无法播放，请检查网络后重试")
                        if error == .cannotPlay { Button { p.retry() } label: { Label("重试", systemImage: "arrow.clockwise").visionHitTarget() } }
                    }
                    .foregroundStyle(C.danger)
                }
            }
            .padding(.horizontal, Tok.Component.CompactPlayer.padding)
            .padding(.vertical, Tok.Component.CompactPlayer.verticalPadding)
            .frame(width: Tok.Component.CompactPlayer.width)
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

private struct VisionPlayerOptions<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: Tok.Component.Vision.hitGap) { content }
        .padding(Tok.Component.Vision.pageMargin)
        .frame(width: Tok.Component.Vision.actionsWidth)
        .fixedSize(horizontal: false, vertical: true)
        .font(.body)
        .buttonStyle(.plain)
    }
}

private struct VisionPlayerOptionLabel: View {
    let title: String
    let selected: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: "checkmark").opacity(selected ? 1 : 0)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .visionHitTarget()
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct VisionAboutContent: View {
    @Environment(AppCore.self) private var core
    @State private var clearing = false
    @State private var checking = false
    @State private var clearResult: String?
    @State private var routeResult: String?
    var body: some View {
        Section("设置") {
            Button {
                guard !clearing else { return }
                clearing = true
                Task {
                    defer { clearing = false }
                    do { try ImageLoader.shared.clear(); OriginWatcher.shared.bump(); clearResult = "已清除" } catch {
                        clearResult = "清除失败，请重试"
                    }
                }
            } label: {
                VStack(alignment: .leading) {
                    Text("清除缓存")
                    if let clearResult { Text(clearResult).font(.footnote).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).visionHitTarget()
            }
            Button {
                guard !checking else { return }
                checking = true
                Task {
                    routeResult = await core.refreshRoutes(); checking = false
                }
            } label: {
                VStack(alignment: .leading) {
                    Text("刷新网络线路")
                    if checking {
                        Text("正在检测…").font(.footnote).foregroundStyle(.secondary)
                    } else if let routeResult {
                        Text(routeResult).font(.footnote).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).visionHitTarget()
            }
        }
        Section {
            Link(destination: URL(string: "mailto:hello@zhibeifw.com")!) { Text("联系：hello@zhibeifw.com").frame(maxWidth: .infinity, alignment: .leading).visionHitTarget() }
            Link(destination: NetConfig.privacyURL) { Text("隐私政策").frame(maxWidth: .infinity, alignment: .leading).visionHitTarget() }
            Link(destination: NetConfig.sourceURL) { Text("源代码").frame(maxWidth: .infinity, alignment: .leading).visionHitTarget() }
        } header: {
            Text("关于")
        } footer: {
            VStack {
                Text("智悲佛网")
                Text("版本 " + AppInfo.version)
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical)
        }
    }
}

private struct VisionPlaybackSliderStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(visionOS 26.0, *) {
            content.sliderThumbVisibility(.hidden)
        } else {
            content
        }
    }
}

private struct VisionPlaybackInfo<Metadata: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let player: PlayerController
    @ViewBuilder var metadata: Metadata
    @State private var dragging: Double?
    @Namespace private var hoverNamespace
    private var hoverGroup: HoverEffectGroup { HoverEffectGroup(hoverNamespace) }

    var body: some View {
        ZStack(alignment: .bottom) {
            metadata
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .offset(y: Tok.Component.CompactPlayer.metadataOffset)
                .hoverEffect(in: hoverGroup) { effect, active, _ in
                    effect.animation(reduceMotion ? nil : .easeInOut) { transition in
                        transition.opacity(active ? 0 : 1)
                    }
                }
            VStack(spacing: Tok.Component.CompactPlayer.timeProgressGap) {
                HStack {
                    Text(clock(dragging ?? player.position))
                    Spacer()
                    Text(remainingClock(dragging ?? player.position, player.duration))
                }
                .font(.body).monospacedDigit().foregroundStyle(.primary)
                .hoverEffect(in: hoverGroup) { effect, active, _ in
                    effect.animation(reduceMotion ? nil : .easeInOut) { transition in
                        transition.opacity(active ? 1 : 0)
                    }
                }
                ZStack {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(.tint)
                                .frame(width: geometry.size.width * progressFraction)
                        }
                        .frame(height: Tok.Component.CompactPlayer.roundTrackHeight)
                        .frame(maxHeight: .infinity)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .hoverEffect(in: hoverGroup) { effect, active, _ in
                        effect.animation(reduceMotion ? nil : .easeInOut) { transition in
                            transition.scaleEffect(x: 1, y: active ? 1 : Tok.Component.CompactPlayer.roundTrackIdleScale)
                                .offset(y: active ? 0 : Tok.Component.CompactPlayer.idleTrackOffset)
                        }
                    }
                    // 保留原生滑块的命中范围、拖动和辅助功能，圆头轨道只负责显示。
                    slider
                        .controlSize(.regular)
                        .hoverEffectDisabled()
                        .opacity(Tok.Component.CompactPlayer.nativeSliderOpacity)
                }
                .frame(height: Tok.Component.Vision.hitSize)
                .visionDebugBoundary()
            }
        }
        // 两种状态共用完整内容高度，时间字号变化也不会越出播放栏。
        .frame(minHeight: Tok.Component.Vision.playerInfoHeight)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(.hoverEffect, Rectangle())
        // 用始终存在的外层维持悬停分组，子视图淡出不撤销悬停。
        .hoverEffect(in: hoverGroup) { effect, _, _ in
            effect.opacity(1)
        }
        .onChange(of: player.current?.episodeId) { _, _ in dragging = nil }
    }

    private var progressFraction: Double {
        guard player.duration > 0 else { return 0 }
        return min(1, max(0, (dragging ?? player.position) / player.duration))
    }

    private var slider: some View {
        Slider(value: Binding(get: { dragging ?? player.position }, set: { dragging = $0 }), in: 0...max(1, player.duration)) { active in
            if !active, let target = dragging {
                player.seek(to: target)
                dragging = nil
            }
        }
        .modifier(VisionPlaybackSliderStyle())
        .frame(minHeight: Tok.Component.Vision.hitSize)
        .contentShape(Rectangle())
        .disabled(player.duration <= 0)
        .accessibilityLabel("播放进度")
        .accessibilityValue(clock(dragging ?? player.position) + "，剩余" + remainingClock(dragging ?? player.position, player.duration))
    }
}

// 尺寸施加在控件标签内，使留白也属于命中区域，而不只是外部布局。
extension View {
    func visionHitTarget() -> some View {
        frame(minWidth: Tok.Component.Vision.hitSize, minHeight: Tok.Component.Vision.hitSize)
            .contentShape(Rectangle())
            .visionDebugBoundary()
    }
}

// 只测量现有布局，不扩大命中范围；系统内部控件仍需单独检查。
extension View {
    @ViewBuilder
    func visionDebugBoundary() -> some View {
        #if DEBUG
        overlay {
            GeometryReader { geometry in
                let size = geometry.size
                let enough = size.width >= Tok.Component.Vision.hitSize && size.height >= Tok.Component.Vision.hitSize
                Rectangle().strokeBorder(enough ? Color.green : Color.red)
                    .overlay(alignment: .topLeading) {
                        Text(String(format: "%.1f×%.1f pt", size.width, size.height))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white)
                            .background(.black)
                            .fixedSize()
                    }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        #else
        self
        #endif
    }
}
