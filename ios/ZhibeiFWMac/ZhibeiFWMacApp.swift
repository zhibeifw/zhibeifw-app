import SwiftUI
import Observation

/// Mac 版入口。共用的状态与动作在 AppCore（ios/Shared/App）；Mac 自己的界面状态在 MacModel。
/// 只有一个主窗口（和 Mac 上的“播客”“音乐”一样），另有“关于智悲佛网”窗口；菜单栏多一个“控制”菜单。
@main
struct ZhibeiFWMacApp: App {
    @State private var model = MacModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window("智悲佛网", id: "main") {
            MacRootView()
                .environment(model)
                .environment(model.core)
                .task { await model.core.boot() }
                .onChange(of: scenePhase) { _, p in
                    if p == .active { model.core.onForeground() }
                    if p == .background { model.core.onBackground() }
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { MacCommands(model: model) }

        Window("关于智悲佛网", id: "about") {
            MacAboutView()
                .environment(model.core)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// 侧边栏的一项。
enum MacSection: Hashable {
    case home
    case category(String)
    case recent, favorites
}

/// 内容区页面栈里能进的页面。
enum MacRoute: Hashable {
    case series(String)
}

/// Mac 版的 App 模型：AppCore 加上 Mac 自己的界面状态（侧边栏选中项、页面栈、搜索词、播放页）。
@MainActor
@Observable
final class MacModel {
    @ObservationIgnored let core: AppCore
    var section: MacSection? = .home {
        didSet { if section != oldValue { path = [] } }
    }
    var path: [MacRoute] = []
    var query = ""
    var playerOpen = false

    /// “前往课程”：收起播放页，在当前内容区里进这门课；最上面已经是这门课就不再进一层。
    func goToSeries(_ seriesId: String) {
        playerOpen = false
        query = ""
        let r = MacRoute.series(seriesId)
        if path.last != r { path.append(r) }
    }

    init() {
        core = AppCore()
        // Mac 上选一集只开始播放、不弹播放页（和 Mac 上的“播客”一样）；点工具栏里的集名打开播放页
        core.presentPlayer = nil
        core.prefetchHomeCovers = { home in
            let cards = home.ongoing + home.featured + home.categories.flatMap { $0.series.prefix(6) }
            ImageLoader.shared.prefetch(cards.map { (path: $0.coverPath, requested: COVER_THUMB_WIDTHS.last!) })
        }
    }
}

/// 菜单栏：“关于智悲佛网”放在 App 菜单的第一项（系统默认位置）；“控制”菜单放播放相关的命令和快捷键。
struct MacCommands: Commands {
    let model: MacModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于智悲佛网") { openWindow(id: "about") }
        }
        // 只有一个主窗口：去掉“新建窗口”
        CommandGroup(replacing: .newItem) {}
        CommandMenu("控制") {
            MacControlMenu(model: model)
        }
    }
}

/// “控制”菜单的内容。没有在播的一集时都不可用。
private struct MacControlMenu: View {
    let model: MacModel
    private var p: PlayerController? { model.core.player }

    var body: some View {
        let has = p?.current != nil
        Button(p?.looksPlaying == true ? "暂停" : "播放") { p?.toggle() }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!has)
        Button("后退 \(Int(SEEK_BACK_SECONDS)) 秒") { p?.seek(by: -SEEK_BACK_SECONDS) }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(!has)
        Button("前进 \(Int(SEEK_FORWARD_SECONDS)) 秒") { p?.seek(by: SEEK_FORWARD_SECONDS) }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(!has)
        Divider()
        Menu("播放速度") {
            ForEach(PLAYBACK_RATES, id: \.self) { r in
                Toggle(rateMenuTitle(r), isOn: Binding(get: { p?.rate == r }, set: { _ in p?.setRate(r) }))
            }
        }
        .disabled(!has)
        Menu("睡眠定时") {
            ForEach(SLEEP_CHOICES) { ch in
                Toggle(ch.title, isOn: Binding(get: { p?.sleep.choiceId == ch.id }, set: { _ in p?.setSleep(sleepSetting(ch)) }))
            }
        }
        .disabled(!has)
        Divider()
        Button("显示播放页") { model.playerOpen = true }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!has)
    }
}
