import Observation

enum Route: Hashable {
    case category(String)
    case series(String)
    case recent, favorites, library
    case libraryCourse(String)
    case about
}

enum Tab: Hashable { case home, categories, library, search }

/// 页面导航：当前标签和每个标签自己的页面栈。系统的 TabView、NavigationStack 直接绑定到这里。
@MainActor
@Observable
final class Navigator {
    var tab: Tab = .home
    var homePath: [Route] = []
    var categoriesPath: [Route] = []
    var libraryPath: [Route] = []
    var searchPath: [Route] = []
    @ObservationIgnored private let pushGuard = PushGuard()

    /// 当前标签的页面栈
    var path: [Route] {
        get {
            switch tab {
            case .home: homePath
            case .categories: categoriesPath
            case .library: libraryPath
            case .search: searchPath
            }
        }
        set {
            switch tab {
            case .home: homePath = newValue
            case .categories: categoriesPath = newValue
            case .library: libraryPath = newValue
            case .search: searchPath = newValue
            }
        }
    }

    /// 进一层。连点同一个入口只进一次。
    func push(_ r: Route) {
        guard pushGuard.allow("\(tab)-\(r)") else { return }
        path.append(r)
    }

    /// 当前标签最上面是不是这门课。
    func isShowingSeries(_ seriesId: String) -> Bool {
        if case .series(let s)? = path.last { return s == seriesId }
        return false
    }
}
