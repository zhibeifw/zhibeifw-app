import SwiftUI
import Observation
import UIKit
import Intents

@main
struct ZhibeiFWVisionApp: App {
    @UIApplicationDelegateAdaptor(VisionSiriDelegate.self) private var delegate
    @State private var model = VisionModel.shared
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            VisionRootView().environment(model).environment(model.core)
                .task {
                    await model.core.boot()
                    if INPreferences.siriAuthorizationStatus() == .notDetermined {
                        INPreferences.requestSiriAuthorization { _ in }
                    }
                }
                .onOpenURL { model.openWidgetLink($0) }
                .onChange(of: phase) { _, phase in
                    if phase == .active { model.core.onForeground() }
                    if phase == .background {
                        model.core.onBackground()
                        Task { await model.widgets.writeNow() }
                    }
                }
        }
    }
}

enum VisionSection: String, CaseIterable, Identifiable {
    case home = "主页", categories = "分类", recent = "最近播放", favorites = "收藏", search = "搜索", about = "关于"
    var id: Self { self }
    var icon: String {
        switch self {
        case .home: "house"
        case .categories: "square.grid.2x2"
        case .recent: "clock"
        case .favorites: "bookmark"
        case .search: "magnifyingglass"
        case .about: "info.circle"
        }
    }
}

enum VisionRoute: Hashable { case series(String), category(String, String) }

@MainActor @Observable
final class VisionModel {
    static let shared = VisionModel()
    let core = AppCore()
    let upgrade = UpgradeChecker()
    @ObservationIgnored private(set) var widgets: WidgetFeeder!
    @ObservationIgnored private var pendingLink: URL?
    var section: VisionSection? = .home {
        didSet { if section != oldValue { path = [] } }
    }
    var paths: [VisionSection: [VisionRoute]] = [:]
    var path: [VisionRoute] {
        get { paths[section ?? .home, default: []] }
        set { paths[section ?? .home] = newValue }
    }
    var versions: [Int] { [core.catalogVersion, core.progressVersion, core.favoritesVersion] }
    private init() {
        core.presentPlayer = nil
        widgets = WidgetFeeder(core: core)
        core.onReady = { [weak self] in
            guard let self else { return }
            self.widgets.start()
            Task { await self.upgrade.check(manual: false) }
            if let url = self.pendingLink {
                self.pendingLink = nil
                self.openWidgetLink(url)
            }
        }
    }

    func openWidgetLink(_ url: URL) {
        guard let link = WidgetLink(url) else { return }
        guard core.phase == .ready else { pendingLink = url; return }
        switch link {
        case .series(let id), .player(let id): showSeries(id)
        }
    }

    func togglePlaybackFromWidget(_ id: String) async {
        guard await readyForWidget(), let player = core.player else { return }
        let on = player.current?.episodeId != id || !player.looksPlaying
        if player.current?.episodeId == id {
            if on && !player.looksPlaying { player.resume() }
            if !on && player.looksPlaying { player.pause() }
        } else if on {
            player.start(id, ctx: .single)
        }
        // 先按要切到的状态写，按钮马上变
        widgets.quickUpdateNowPlaying(playing: on)
        // 播放：等声音真的出来（或出错、最多 10 秒）再结束这个动作。苹果对音频动作的要求：动作结束前要开始出声，
        // 否则 App 在后台被叫起来时，动作一结束就被挂起，播放起不来（小组件上又变回播放键）
        guard on else { return }
        for _ in 0..<100 where !player.isPlaying && player.error == nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        WidgetLog.note("按钮：出声=\(player.isPlaying) 出错=\(player.error != nil)")
        if !player.isPlaying { widgets.quickUpdateNowPlaying(playing: false) }
    }

    private func readyForWidget() async -> Bool {
        await core.boot()
        for _ in 0..<100 where core.phase != .ready {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return core.phase == .ready
    }

    func showSeries(_ id: String) {
        if path.last != .series(id) { path.append(.series(id)) }
    }
}

struct VisionRootView: View {
    @Environment(VisionModel.self) private var model
    @Environment(AppCore.self) private var core
    @State private var refreshingRoutes = false
    var body: some View {
        @Bindable var model = model
        Group {
            switch core.phase {
            case .ready:
                TabView(selection: $model.section) {
                    ForEach(VisionSection.allCases) { item in
                    NavigationStack(path: Binding(
                        get: { model.paths[item, default: []] },
                        set: { model.paths[item] = $0 }
                    )) {
                        VisionBrowseView(section: item)
                            .navigationDestination(for: VisionRoute.self) { route in
                                switch route {
                                case .series(let id): VisionSeriesView(id: id)
                                case .category(let id, let name): VisionCategoryView(id: id, name: name)
                                }
                            }

                    }
                    .tabItem { Label(item.rawValue, systemImage: item.icon) }
                    .tag(Optional(item))
                    }
                }
            case .dbError: ContentUnavailableView("无法打开资料库", systemImage: "exclamationmark.triangle")
            case .initializing(_, true):
                VStack(spacing: Tok.Component.Vision.hitGap) {
                    Text("暂时无法连接")
                    Button { Task { await core.runInitialization() } } label: { Text("重试").visionHitTarget() }
                        .disabled(refreshingRoutes)
                    Button {
                        refreshingRoutes = true
                        Task {
                            _ = await Network.shared.refreshRoutes()
                            await core.runInitialization()
                            refreshingRoutes = false
                        }
                    } label: {
                        Text(refreshingRoutes ? "正在检测…" : "刷新网络线路").visionHitTarget()
                    }
                    .disabled(refreshingRoutes)
                }
            default: ProgressView("载入课程")
            }
        }
        .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            if core.player?.current != nil {
                VisionMiniPlayer()
                    .glassBackgroundEffect()
                    .padding(.top, Tok.Component.Vision.playerWindowGap)
            }
        }
        .alert(
            core.alert?.title ?? "", isPresented: Binding(get: { core.alert != nil }, set: { if !$0 { core.alert = nil } }),
            presenting: core.alert
        ) { spec in
            ForEach(spec.buttons) { button in
                Button(button.title, role: button.role) {
                    core.alert = nil; button.action()
                }
            }
        } message: { spec in
            if let message = spec.message { Text(message) }
        }
    }
}

final class VisionSiriDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        guard intent is INPlayMediaIntent else { return nil }
        return SiriMediaHandler.shared
    }
}
