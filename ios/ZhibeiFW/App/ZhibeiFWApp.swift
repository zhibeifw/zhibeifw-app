import SwiftUI
import UIKit

@main
struct ZhibeiFWApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.boot() }
                .onOpenURL { model.openWidgetLink($0) }
                .task { WidgetLog.note("App 界面起来了 phase=\(model.phase)") }
                .onChange(of: scenePhase) { _, p in
                    if p == .active { model.onForeground() }
                    if p == .background { model.onBackground() }
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var backgroundCompletion: (() -> Void)?

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppFiles().prepare()
        _ = BackgroundDownloader.shared  // 尽早接上后台下载会话，系统交回的结果不丢
        _ = Connectivity.shared  // 尽早开始看网络：启动时判断有没有网，读到的才是真实状态，不是初始值
        return true
    }

    /// 场景用自己的代理，才能收到长按 App 图标菜单的点击（QuickActionSceneDelegate）
    func application(
        _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        c.delegateClass = QuickActionSceneDelegate.self
        return c
    }

    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void
    ) {
        // 后台下载会话的事件：系统唤醒 App 处理完成的下载
        AppDelegate.backgroundCompletion = completionHandler
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.shared.mask
    }
}

/// 屏幕方向：手机只有全屏播放页能横屏；平板全部方向。
final class OrientationLock {
    static let shared = OrientationLock()
    var playerOpen = false {
        didSet {
            guard UIDevice.current.userInterfaceIdiom == .phone, oldValue != playerOpen else { return }
            for scene in UIApplication.shared.connectedScenes {
                guard let ws = scene as? UIWindowScene else { continue }
                ws.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                if !playerOpen { ws.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in } }
            }
        }
    }
    var mask: UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        return playerOpen ? .allButUpsideDown : .portrait
    }
}
