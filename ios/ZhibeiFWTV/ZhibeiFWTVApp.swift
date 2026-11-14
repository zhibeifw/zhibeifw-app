import SwiftUI
import Observation
import UIKit
import Intents

/// Apple TV 版入口。共用的状态与动作在 AppCore（ios/Shared/App）；电视自己的界面状态在 TVModel。
@main
struct ZhibeiFWTVApp: App {
    @UIApplicationDelegateAdaptor(TVSiriDelegate.self) private var delegate
    @State private var model = TVModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(model)
                .environment(model.core)
                .task {
                    await model.core.boot()
                    if INPreferences.siriAuthorizationStatus() == .notDetermined {
                        INPreferences.requestSiriAuthorization { _ in }
                    }
                }
                .onChange(of: scenePhase) { _, p in
                    if p == .active { model.core.onForeground() }
                    if p == .background { model.core.onBackground() }
                }
        }
    }
}

/// 电视上是顶部的标签：主页、分类、资料库（和 iPhone 一样）、“正在播放”（代替 iPhone 的播放胶囊），
/// 最后是只有图标的搜索和“关于”（iPhone 的关于在主页右上角）。
enum TVTab: Hashable { case nowPlaying, home, categories, library, search, about }

/// 页面地址（和 iPhone 的 Route 对应；没有“已下载”）。
enum TVRoute: Hashable {
    case series(String)
    case category(String)
    case recent, favorites, privacy, contact, source
}

/// Apple TV 版的 App 模型：AppCore 加上电视自己的界面状态（当前标签、各标签的页面栈）。
@MainActor
@Observable
final class TVModel {
    static let shared = TVModel()
    @ObservationIgnored let upgrade = UpgradeChecker()
    @ObservationIgnored let core: AppCore
    var tab: TVTab = .home {
        didSet { if tab != .nowPlaying { browseTab = tab } }
    }
    /// 最近一次停留的普通标签（不是“正在播放”）：从“正在播放”前往课程时回到这里
    private(set) var browseTab: TVTab = .home
    var homePath: [TVRoute] = []
    var categoriesPath: [TVRoute] = []
    var libraryPath: [TVRoute] = []
    var searchPath: [TVRoute] = []
    var aboutPath: [TVRoute] = []

    /// “前往课程”：从“正在播放”回到原来的标签，在里面进这门课；最上面已经是这门课就不再进一层。
    func goToSeries(_ seriesId: String) {
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

    init() {
        core = AppCore()
        core.onReady = { [weak self] in
            Task { await self?.upgrade.check(manual: false) }
        }
        // 选一集开始播放：切到“正在播放”标签（不另弹全屏播放页，和系统“音乐”App 一样）
        core.presentPlayer = { [weak self] in
            guard let self, self.core.player.current != nil else { return }
            self.tab = .nowPlaying
        }
        // 电视上卡片都用 640 小图（1080p 一倍、4K 两倍屏都够清楚）；每行只取前几张
        core.prefetchHomeCovers = { home in
            let cards = home.ongoing + home.featured + home.categories.flatMap { $0.series.prefix(5) }
            ImageLoader.shared.prefetch(cards.map { (path: $0.coverPath, requested: COVER_THUMB_WIDTHS.last!) })
        }
    }
}

final class TVSiriDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        guard intent is INPlayMediaIntent else { return nil }
        return SiriMediaHandler.shared
    }
}
