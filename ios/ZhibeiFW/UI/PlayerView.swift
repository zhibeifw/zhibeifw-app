import SwiftUI

/// 全屏播放页：系统的全高底部弹窗，下拉收起由系统处理。
/// iPad 等大屏上系统默认是屏幕正中的卡片，这里让它铺满整个屏幕（和 iPhone 一样），仍是系统弹窗、仍可下拉收起。
struct PlayerSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            if model.player.current != nil {
                PlayerView(size: geo.size, safe: geo.safeAreaInsets)
            }
        }
        .background(C.background.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationSizing(FillScreenSizing())
        .presentationDragIndicator(.visible)
        .appAlert(model, whenPlayerOpen: true)
    }
}

/// 弹窗的尺寸提议成无限大，系统会把它限制在屏幕范围内，也就是铺满。
private struct FillScreenSizing: PresentationSizing {
    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize { .infinity }
}

struct PlayerView: View {
    var size: CGSize
    var safe: EdgeInsets
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var scrub: Double?
    /// “•••”菜单要用的库里的数据：换集或进度、收藏、下载变了才重读（菜单内容在每次重画时都会算，不能在那里查库）
    @State private var menuFacts: MenuFacts?
    /// 最后一次在播的课：正在播的这一集被删掉下载、播放器清空时，播放页收起的那一下还用它画，不会因为“没有当前课”而闪退
    @State private var last: NowPlaying?

    /// 现在要画的课：有当前课用当前课，没有就用最后一次的
    private var shown: NowPlaying? { p.current ?? last }

    private var p: PlayerController { model.player }

    var body: some View {
        let landscape =
            size.width > size.height && size.width >= Tok.Space.tabletBreakpoint
            || (size.width > size.height && UIDevice.current.userInterfaceIdiom == .phone)
        let tablet = Layout.isTablet(min(size.width, size.height)) || Layout.isTablet(size.width) && !landscape
        ZStack(alignment: .top) {
            if let c = shown {
                if landscape {
                    landscapeLayout(
                        c, tablet: Layout.isTablet(min(size.width, size.height) * 2) && UIDevice.current.userInterfaceIdiom == .pad)
                } else {
                    portraitLayout(c, tablet: tablet)
                }
            }
        }
        .onAppear { last = p.current }
        .onChange(of: p.current) { _, now in if let now { last = now } }
        // 睡眠定时的倒计时每秒刷新一次（播放时页面每半秒重画，定时器不能写在 body 里，否则每次重画都被重建、永远走不到点）
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                p.refreshSleepDisplay()
            }
        }
        .task(
            id: MenuKey(
                episodeId: p.current?.episodeId,
                versions: [model.progressVersion, model.favoritesVersion, model.downloadsVersion])
        ) { loadMenuFacts() }
    }

    private struct MenuKey: Equatable { var episodeId: String?; var versions: [Int] }
    private struct MenuFacts { var episodeId: String; var progress: Prog?; var dlState: DlStatus?; var favorite: Bool }

    private func loadMenuFacts() {
        guard let c = p.current else { menuFacts = nil; return }
        menuFacts = MenuFacts(
            episodeId: c.episodeId, progress: model.store.loadProgress(c.episodeId), dlState: model.store.getDownload(c.episodeId)?.state,
            favorite: model.store.isFavorite(c.seriesId))
    }

    // MARK: 竖屏：顶部拖动条；中部封面区（占满剩余，封面居中）；底部信息与控制区整体贴底
    private func portraitLayout(_ c: NowPlaying, tablet: Bool) -> some View {
        let maxW = tablet ? Tok.Player.portraitMaxWidth : size.width
        let contentW = min(size.width, maxW)
        let coverW = contentW - 2 * CP.Player.coverSideMargin
        return VStack(spacing: 0) {
            Color.clear.frame(height: CP.Player.grabberTop + CP.Player.grabberHeight)
            cover(c, width: coverW)
                .frame(maxHeight: .infinity)
                .padding(.vertical, CP.Player.coverMinPad)
            controls(c, width: contentW - 2 * CP.Player.coverSideMargin)
                .padding(.bottom, CP.Player.bottomPad)
        }
        .frame(width: contentW)
        .frame(maxWidth: .infinity)
    }

    // MARK: 横屏：左封面、右控制，各自上下居中
    private func landscapeLayout(_ c: NowPlaying, tablet: Bool) -> some View {
        let L =
            tablet
            ? (
                cover: CP.Player.LandscapeTablet.cover, right: CP.Player.LandscapeTablet.right, gap: CP.Player.LandscapeTablet.gap,
                side: CP.Player.LandscapeTablet.side
            )
            : (
                cover: CP.Player.LandscapePhone.cover, right: CP.Player.LandscapePhone.right, gap: CP.Player.LandscapePhone.gap,
                side: CP.Player.LandscapePhone.side
            )
        let maxCoverByHeight = (size.height - CP.Player.LandscapePhone.coverHeightInset) * 16 / 9
        // 弹窗比设计宽度窄时（iPad、iPhone Duo 展开横屏的居中弹窗）三段一起等比缩小，不超出弹窗
        let k = min(1, (size.width - 2 * L.side) / (L.cover + L.gap + L.right))
        return HStack(spacing: L.gap * k) {
            cover(c, width: min(L.cover * k, maxCoverByHeight))
            controls(c, width: L.right * k, tight: !tablet)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cover(_ c: NowPlaying, width: CGFloat) -> some View {
        return CoverImage(
            path: c.info.coverPath, colorId: c.seriesId, radius: CP.Player.coverRadius,
            localFile: model.files.coverFile(seriesId: c.seriesId)
        )
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: width)
        .frame(minWidth: width * CP.Player.coverMinRatio)
        .shadow(
            color: scheme == .dark ? .clear : .black.opacity(CP.Player.CoverShadow.opacity), radius: CP.Player.CoverShadow.radius / 2,
            y: CP.Player.CoverShadow.offsetY)
    }

    private func controls(_ c: NowPlaying, width: CGFloat, tight: Bool = false) -> some View {
        let gapBar = tight ? CP.Player.LandscapePhone.tightGap : CP.Player.titleToBar
        let gapCtl = tight ? CP.Player.LandscapePhone.tightGap : CP.Player.barToControls
        return VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: CP.Player.courseGap) {
                    Text(c.info.episodeTitle).zFont(S.playerTitle).foregroundStyle(C.labelPrimary).lineLimit(2)
                    Button {
                        model.goToSeries(c.seriesId)
                    } label: {
                        HStack(spacing: Tok.Space.textGap) {
                            Text(c.info.seriesTitle).zFont(S.body).foregroundStyle(C.labelSecondary).lineLimit(1)
                            ZIcon(
                                name: "chevron-forward", size: CP.SectionTitle.arrowSize * CP.SectionTitle.inlineArrowScale,
                                color: C.labelSecondary)
                        }
                        .frame(minHeight: CP.Player.courseMinHeight).contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("\(c.info.seriesTitle)，前往课程")
                }
                Spacer(minLength: Tok.Space.scale[1])
                NativeMenu(items: moreGroups) {
                    ZStack {
                        Circle().fill(C.backgroundSecondary).frame(width: CP.Player.moreButton, height: CP.Player.moreButton)
                        ZIcon(name: "ellipsis-horizontal", size: CP.Player.moreIcon, color: C.labelPrimary)
                    }.minTouch()
                }
                .accessibilityLabel("更多操作")
            }
            ProgressBar(
                position: scrub ?? p.position, duration: p.duration, onScrub: { scrub = $0 },
                onCommit: { v in
                    p.seek(to: v); scrub = nil
                }, onStep: { p.seek(by: $0) }
            )
            .padding(.top, gapBar)
            HStack {
                Text(clock(scrub ?? p.position)).zFont(S.caption).monospacedDigit().foregroundStyle(C.labelSecondary)
                Spacer()
                Text(rightLabel).zFont(S.caption).monospacedDigit().foregroundStyle(C.labelSecondary)
            }
            .padding(.top, CP.Player.timeTop)
            controlRow.padding(.top, gapCtl).padding(.horizontal, CP.Player.controlsSideMargin - CP.Player.coverSideMargin)
        }
        .frame(width: width)
    }

    private var rightLabel: String {
        switch p.sleep {
        case .end: return sleepLabel(nil)
        case .timer: return sleepLabel(p.sleepLeft ?? 0)
        case .off: return remainingClock(scrub ?? p.position, p.duration)
        }
    }

    private var controlRow: some View {
        HStack {
            // 倍速：系统单选菜单（和“播客”一样）
            NativeMenu(items: { [PLAYBACK_RATES.map { r in MenuItem(title: rateMenuTitle(r), checked: p.rate == r) { p.setRate(r) } }] }) {
                Text(String(format: "%g×", p.rate)).zFont(S.rateLabel, maxScale: Tok.Font.MaxScale.rateLabel).foregroundStyle(
                    C.labelSecondary
                ).minTouch()
            }
            .accessibilityLabel("播放速度 \(String(format: "%g", p.rate)) 倍，点按更改")
            Spacer()
            Button {
                p.seek(by: -SEEK_BACK_SECONDS)
            } label: {
                SeekIcon(forward: false, size: CP.Player.seekIcon).minTouch()
            }
            .buttonStyle(PressableStyle()).accessibilityLabel("后退 \(Int(SEEK_BACK_SECONDS)) 秒")
            Spacer()
            Button {
                p.toggle()
            } label: {
                ZIcon(name: p.looksPlaying ? "pause" : "play", size: CP.Player.playIcon).minTouch()
            }
            .buttonStyle(PressableStyle()).accessibilityLabel(p.looksPlaying ? "暂停" : "播放")
            Spacer()
            Button {
                p.seek(by: SEEK_FORWARD_SECONDS)
            } label: {
                SeekIcon(forward: true, size: CP.Player.seekIcon).minTouch()
            }
            .buttonStyle(PressableStyle()).accessibilityLabel("前进 \(Int(SEEK_FORWARD_SECONDS)) 秒")
            Spacer()
            NativeMenu(items: { [sleepItems()] }) {
                ZIcon(name: "moon", size: CP.Player.moonIcon, color: p.sleep == .off ? C.labelTertiary : C.labelPrimary).minTouch()
            }
            .accessibilityLabel(sleepA11y)
        }
    }

    private var sleepA11y: String {
        switch p.sleep {
        case .off: return "睡眠定时，未开启"
        case .end: return "睡眠定时，本集结束时"
        case .timer: return "睡眠定时，剩余 \(Int(((p.sleepLeft ?? 0) / 60).rounded(.up))) 分钟"
        }
    }

    private func sleepItems() -> [MenuItem] {
        SLEEP_CHOICES.map { ch in
            MenuItem(title: ch.title, checked: p.sleep.choiceId == ch.id) {
                if ch.id == "off" {
                    p.setSleep(.off)
                } else if ch.id == "end" {
                    p.setSleep(.end)
                } else if let m = ch.minutes {
                    p.setSleep(.timer(deadline: sleepClock() + Double(m) * 60, minutes: m))
                }
            }
        }
    }

    private func moreGroups() -> [[MenuItem]] {
        guard let c = p.current else { return [] }
        let f = menuFacts?.episodeId == c.episodeId ? menuFacts : nil
        let e = EpisodeItem(
            episodeId: c.episodeId, seriesId: c.seriesId, title: c.info.episodeTitle, progress: f?.progress, dlState: f?.dlState)
        let fav = f?.favorite ?? false
        return [
            model.downloadItems(for: e) + [model.markItem(e)],
            [
                MenuItem(title: fav ? "取消收藏课程" : "收藏课程", icon: fav ? "bookmark" : "bookmark-outline") {
                    model.toggleFavorite(c.seriesId, title: c.info.seriesTitle, coverPath: c.info.coverPath)
                },
                MenuItem(title: "前往课程", icon: "arrow-forward-circle-outline") { model.goToSeries(c.seriesId) },
            ],
        ]
    }
}

/// 倍速菜单里的文字：“1×（正常）”“1.5×”。
func rateMenuTitle(_ r: Double) -> String { r == 1 ? "1×（正常）" : String(format: "%g×", r) }

/// 播放进度：外观是系统滑块（UISlider），整条都能拖。
/// ：iOS 26 起用系统的“无把手”媒体进度样式（UISlider.Style.thumbless，和“播客”一样只有一条线）；
/// iOS 18 没有这个样式（iOS 18 之后直接是 26），用和 Android 一样的深色小圆点、细轨道。SwiftUI 的 Slider 换不了把手，所以用 UIKit 的 UISlider。
/// 系统滑块只能按住圆点拖，圆点小、不好按，所以上面盖一层拖动手势：手指在条上任何地方按下拖动，进度按手指移动的距离走
/// （和“播客”一样，不会一按就跳到手指的位置）。拖动时只更新显示的时间，松手才跳转。读屏是一个可调节的元素（上下滑一次 ±15 秒）。
struct ProgressBar: View {
    var position: Double
    var duration: Double
    var onScrub: (Double) -> Void
    var onCommit: (Double) -> Void
    var onStep: (Double) -> Void
    @State private var width: CGFloat = 1
    /// 这次拖动：手指按下的位置（区分是不是同一次拖动）和那时的播放位置
    @State private var drag: (start: CGPoint, from: Double)?

    var body: some View {
        let total = max(duration, 0.0001)
        // 系统滑块只负责画，不接触摸：不然它和上面的拖动手势抢同一次触摸，会跳两次或这次拖动被取消
        MediaSlider(value: min(position, total), total: total, enabled: duration > 0)
            .frame(height: Tok.ProgressBar.touchHeight)
            .allowsHitTesting(false)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                width = max($0, 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("播放进度")
            .accessibilityValue("已播放 \(clock(position))，剩余 \(clock(max(0, duration - position)))")
            .accessibilityAdjustableAction { d in
                let step = Double(Tok.Player.seekBackSeconds)  // 读屏上下滑一次 ±15 秒
                onStep(d == .increment ? step : -step)
            }
            // 拖动层和滑块一样大（盖在上面，不改排版）
            .overlay {
                Color.clear.contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { g in
                                guard duration > 0 else { return }
                                // 按下的位置变了＝新的一次拖动（上一次即使被系统取消、没走到松手，也不会带着旧的起点）
                                if drag?.start != g.startLocation { drag = (g.startLocation, min(position, total)) }
                                onScrub(value(drag!.from, g, total))
                            }
                            .onEnded { g in
                                guard duration > 0 else { drag = nil; return }
                                let from = drag?.start == g.startLocation ? drag!.from : min(position, total)
                                drag = nil
                                onCommit(value(from, g, total))
                            }
                    )
                    .accessibilityHidden(true)
            }
    }

    private func value(_ from: Double, _ g: DragGesture.Value, _ total: Double) -> Double {
        min(max(from + Double(g.translation.width / width) * total, 0), total)
    }
}

/// 系统滑块（UISlider），配成媒体进度的样子，颜色用 progressFill / progressTrack：
/// iOS 26 起是系统的无把手样式（轨道高度也用系统的）；更早的系统用深色小圆点把手（progressBar.thumb）、细轨道（progressBar.height），和 Android 一致。
/// 只负责画，触摸和读屏由 ProgressBar 管。
private struct MediaSlider: UIViewRepresentable {
    var value: Double
    var total: Double
    var enabled: Bool

    func makeUIView(context: Context) -> Slider {
        let s = Slider()
        s.minimumTrackTintColor = Tok.Color.progressFill.uiColor
        s.maximumTrackTintColor = Tok.Color.progressTrack.uiColor
        s.isAccessibilityElement = false
        if #available(iOS 26.0, *) { s.sliderStyle = .thumbless } else { s.useDot() }
        return s
    }

    func updateUIView(_ s: Slider, context: Context) {
        s.maximumValue = Float(total)
        s.value = Float(value)
        s.isEnabled = enabled
    }

    final class Slider: UISlider {
        /// iOS 18：自己画的小圆点和细轨道
        private var dot = false

        func useDot() {
            dot = true
            updateThumb()
            // 深浅色切换时重画圆点（图片不会自己跟着变色）
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (s: Slider, _: UITraitCollection) in s.updateThumb() }
        }

        private func updateThumb() {
            let d = Tok.ProgressBar.thumb
            let color = Tok.Color.progressFill.uiColor.resolvedColor(with: traitCollection)
            let img = UIGraphicsImageRenderer(size: CGSize(width: d, height: d)).image { _ in
                color.setFill()
                UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: d, height: d)).fill()
            }
            setThumbImage(img, for: .normal)
            setThumbImage(img, for: .disabled)
        }

        override func trackRect(forBounds bounds: CGRect) -> CGRect {
            guard dot else { return super.trackRect(forBounds: bounds) }
            let h = Tok.ProgressBar.height
            return CGRect(x: bounds.minX, y: bounds.midY - h / 2, width: bounds.width, height: h)
        }
    }
}
