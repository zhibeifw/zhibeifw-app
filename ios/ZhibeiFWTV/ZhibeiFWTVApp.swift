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

/// 电视上是顶部的标签：主页、分类、资料库、搜索（和 iPhone 一样），再加“关于”（iPhone 在主页右上角）。
/// 有在播的一集时最左边多一个“正在播放”（和系统“音乐”App 一样），代替 iPhone 的播放胶囊。
enum TVTab: Hashable { case nowPlaying, home, categories, library, search, about }

/// 页面地址（和 iPhone 的 Route 对应；没有“已下载”）。
enum TVRoute: Hashable {
    case series(String)
    case category(String)
    case recent, favorites, privacy, contact, source
}

/// Apple TV 版的 App 模型：AppCore 加上电视自己的界面状态（当前标签、各标签的页面栈、播放页）。
@MainActor
@Observable
final class TVModel {
    @ObservationIgnored let core: AppCore
    var playerOpen = false
    var tab: TVTab = .home {
        didSet { if tab != .nowPlaying { browseTab = tab } }
    }
    /// 最近一次停留的普通标签（不是“正在播放”）：从“正在播放”前往课程、或播放停了标签消失时回到这里
    private(set) var browseTab: TVTab = .home
    var homePath: [TVRoute] = []
    var categoriesPath: [TVRoute] = []
    var libraryPath: [TVRoute] = []
    var searchPath: [TVRoute] = []
    var aboutPath: [TVRoute] = []

    /// “前往课程”：收起播放页，在当前标签里进这门课；最上面已经是这门课就不再进一层。
    func goToSeries(_ seriesId: String) {
        playerOpen = false
        let r = TVRoute.series(seriesId)
        if tab == .nowPlaying { tab = browseTab }
        switch tab {
        case .nowPlaying, .home: if homePath.last != r { homePath.append(r) }
        case .categories: if categoriesPath.last != r { categoriesPath.append(r) }
        case .library: if libraryPath.last != r { libraryPath.append(r) }
        case .search: if searchPath.last != r { searchPath.append(r) }
        case .about:  // 关于里没有课程：到主页里进
            tab = .home
            if homePath.last != r { homePath.append(r) }
        }
    }

    /// 播放停了，“正在播放”标签随之消失：正停在这个标签上就回到原来的标签。
    func nowPlayingEnded() {
        if tab == .nowPlaying { tab = browseTab }
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
