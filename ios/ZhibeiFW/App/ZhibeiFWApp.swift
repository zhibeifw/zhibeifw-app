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
        return true
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

/// 隐藏系统导航栏后仍保留边缘右滑返回。iOS 26 的整屏右滑返回保持系统默认（集行没有滑动手势，不会和它抢）。
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }
    public func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { viewControllers.count > 1 }
}
