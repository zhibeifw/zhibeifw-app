import SwiftUI
import Observation

/// Apple TV 版入口。共用的状态与动作在 AppCore（ios/Shared/App）；这里只多一个“播放页开着没有”。
@main
struct ZhibeiFWTVApp: App {
    @State private var model = TVModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(model)
                .environment(model.core)
                .task { await model.core.boot() }
                .onChange(of: scenePhase) { _, p in
                    if p == .active { model.core.onForeground() }
                    if p == .background { model.core.onBackground() }
                }
        }
    }
}

enum TVTab: Hashable { case home, recent, favorites, about }

/// Apple TV 版的 App 模型：AppCore 加上电视自己的界面状态（当前标签、各标签的页面栈、播放页）。
@MainActor
@Observable
final class TVModel {
    @ObservationIgnored let core: AppCore
    var playerOpen = false
    var tab: TVTab = .home
    var homePath: [SeriesLink] = []
    var recentPath: [SeriesLink] = []
    var favoritesPath: [SeriesLink] = []

    /// “前往课程”：收起播放页，在当前标签里进这门课；最上面已经是这门课就不再进一层。
    func goToSeries(_ seriesId: String) {
        playerOpen = false
        let link = SeriesLink(id: seriesId)
        switch tab {
        case .about:  // 关于页没有页面栈：到首页里进
            tab = .home
            if homePath.last != link { homePath.append(link) }
        case .home: if homePath.last != link { homePath.append(link) }
        case .recent: if recentPath.last != link { recentPath.append(link) }
        case .favorites: if favoritesPath.last != link { favoritesPath.append(link) }
        }
    }

    init() {
        core = AppCore()
        core.presentPlayer = { [weak self] in
            guard let self, self.core.player.current != nil else { return }
            self.playerOpen = true
        }
        // 电视上卡片都用 640 小图（1080p 一倍、4K 两倍屏都够清楚）；每行只取前几张
        core.prefetchHomeCovers = { home in
            let cards = home.ongoing + home.featured + home.categories.flatMap { $0.series.prefix(5) }
            ImageLoader.shared.prefetch(cards.map { (path: $0.coverPath, requested: COVER_THUMB_WIDTHS.last!) })
        }
    }
}
