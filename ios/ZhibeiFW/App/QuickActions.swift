import UIKit

/// 长按 App 图标弹出的菜单（主屏幕快速操作）：最近播放、收藏、已下载，点了进资料库里对应的那一页。
/// 菜单项写在 Info.plist 的 UIApplicationShortcutItems（系统的标准做法，不用代码动态加）。
enum QuickAction: String {
    case recent = "com.zhibeifw.app.recent"
    case favorites = "com.zhibeifw.app.favorites"
    case downloads = "com.zhibeifw.app.downloads"

    /// App 模型建好后接上；系统交来菜单项时 App 模型可能还没建好，先记下
    @MainActor static var handler: ((QuickAction) -> Void)?
    @MainActor static var pending: QuickAction?

    @MainActor
    static func perform(_ item: UIApplicationShortcutItem) {
        guard let a = QuickAction(rawValue: item.type) else { return }
        if let h = handler { h(a) } else { pending = a }
    }
}

/// 系统把长按菜单的点击交给场景：App 没开着时在建场景时交来，开着时调 performActionFor
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem { MainActor.assumeIsolated { QuickAction.perform(item) } }
    }

    func windowScene(
        _ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void
    ) {
        MainActor.assumeIsolated { QuickAction.perform(shortcutItem) }
        completionHandler(true)
    }
}
