import AVKit
import SwiftUI

/// 全屏播放页：系统的播放界面（AVKit 的 AVPlayerViewController）。
/// 进度条、播放暂停、触控板拖动、左右键快退快进、向下轻扫的信息面板都是系统的；
/// 音频没有画面，画面中间自己画：模糊的封面底、大封面、课程名和集名（苹果推荐的做法：画在 contentOverlayView 里）。
/// 进度条上方的菜单：倍速、睡眠定时、更多（标记已听完、收藏课程、前往课程），文字和 iPhone 一样。
/// 播放器本身还是 PlayerController 的那个 AVPlayer：在系统界面里暂停、拖动，PlayerController 照样记进度。
struct TVPlayerView: View {
    @Environment(AppCore.self) private var core
    @Environment(TVModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let p = core.player, let c = p.current {
            // 菜单里的勾选状态、收藏、已听完：变了才重建菜单（读这几个值，SwiftUI 才会在它们变时更新）
            let facts = MenuFacts(
                rate: p.rate, sleepId: p.sleep.choiceId, favorite: favorite(c), completed: completed(c), error: p.error)
            SystemPlayer(player: p, now: c, facts: facts, core: core, model: model)
                .ignoresSafeArea()
        } else {
            // 播放器停了（比如这一集被标为已听完）：没什么可显示的，收起
            Color.clear.onAppear { dismiss() }
        }
    }

    private func favorite(_ c: NowPlaying) -> Bool {
        _ = core.favoritesVersion
        return core.store.isFavorite(c.seriesId)
    }

    private func completed(_ c: NowPlaying) -> Bool {
        _ = core.progressVersion
        return core.store.loadProgress(c.episodeId)?.completed ?? false
    }
}

private struct MenuFacts: Equatable {
    var rate: Double
    var sleepId: String
    var favorite: Bool
    var completed: Bool
    var error: PlayerError?
}

private struct SystemPlayer: UIViewControllerRepresentable {
    let player: PlayerController
    let now: NowPlaying
    let facts: MenuFacts
    let core: AppCore
    let model: TVModel

    final class Coordinator {
        var host: UIHostingController<AnyView>?
        var metadataFor: (episodeId: String, item: ObjectIdentifier)?
        var facts: MenuFacts?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player.player
        // tvOS 的系统播放界面没有 updatesNowPlayingInfoCenter、speeds 这两个设置：
        // “正在播放”信息照旧由 PlayerController 写；倍速用下面我们自己的菜单
        // 画面中间：封面和标题，铺在系统控件下面
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.view.backgroundColor = .clear
        vc.addChild(host)
        if let overlay = vc.contentOverlayView {
            host.view.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: overlay.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            ])
        }
        host.didMove(toParent: vc)
        context.coordinator.host = host
        update(vc, context.coordinator)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        update(vc, context.coordinator)
    }

    private func update(_ vc: AVPlayerViewController, _ co: Coordinator) {
        co.host?.rootView = AnyView(
            TVNowPlayingArt(now: now, error: facts.error).environment(core))
        if co.facts != facts {
            co.facts = facts
            vc.transportBarCustomMenuItems = menus()
        }
        // 信息面板（向下轻扫）：集名、课程名、封面。换了一集（或重新加载了音频）才重写
        if let item = player.player.currentItem,
            co.metadataFor?.episodeId != now.episodeId || co.metadataFor?.item != ObjectIdentifier(item)
        {
            co.metadataFor = (now.episodeId, ObjectIdentifier(item))
            item.externalMetadata = metadata()
        }
    }

    private func menus() -> [UIMenuElement] {
        let rates = UIMenu(
            title: "播放速度", image: UIImage(systemName: "speedometer"),
            children: PLAYBACK_RATES.map { r in
                UIAction(title: rateMenuTitle(r), state: facts.rate == r ? .on : .off) { _ in player.setRate(r) }
            })
        let sleep = UIMenu(
            title: "睡眠定时", image: UIImage(systemName: facts.sleepId == "off" ? "moon" : "moon.fill"),
            children: SLEEP_CHOICES.map { ch in
                UIAction(title: ch.title, state: facts.sleepId == ch.id ? .on : .off) { _ in player.setSleep(sleepSetting(ch)) }
            })
        let seriesId = now.seriesId, episodeId = now.episodeId, info = now.info
        let done = facts.completed, fav = facts.favorite
        let more = UIMenu(
            title: "更多", image: UIImage(systemName: "ellipsis"),
            children: [
                UIAction(title: done ? "标记为未听完" : "标记为已听完", image: UIImage(systemName: "checkmark.circle")) { _ in
                    core.markCompleted(episodeId, seriesId: seriesId, completed: !done)
                },
                UIAction(title: fav ? "取消收藏课程" : "收藏课程", image: UIImage(systemName: fav ? "bookmark.fill" : "bookmark")) { _ in
                    core.toggleFavorite(seriesId, title: info.seriesTitle, coverPath: info.coverPath)
                },
                UIAction(title: "前往课程", image: UIImage(systemName: "arrow.forward.circle")) { _ in
                    model.goToSeries(seriesId)
                },
            ])
        // 加载失败：系统的播放键不会重新加载音频，放一个“重试”（画面中间的按钮选不到：焦点在系统控件上）
        if facts.error == .cannotPlay {
            let retry = UIAction(title: "重试", image: UIImage(systemName: "arrow.clockwise")) { _ in player.retry() }
            return [retry, rates, sleep, more]
        }
        return [rates, sleep, more]
    }

    private func metadata() -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value
            m.extendedLanguageTag = "und"
            return m
        }
        var items = [
            item(.commonIdentifierTitle, now.info.episodeTitle as NSString),
            item(.iTunesMetadataTrackSubTitle, now.info.seriesTitle as NSString),
        ]
        if let img = ImageLoader.shared.anyCached(now.info.coverPath), let data = img.jpegData(compressionQuality: 0.8) {
            items.append(item(.commonIdentifierArtwork, data as NSData))
        }
        return items
    }
}

/// 画面中间：模糊、调淡的封面铺底，上面是大封面、课程名、集名；出错时显示原因（在系统控件下面）。
private struct TVNowPlayingArt: View {
    let now: NowPlaying
    let error: PlayerError?

    var body: some View {
        ZStack {
            C.background
            CoverImage(path: now.info.coverPath, colorId: now.seriesId, radius: 0)
                .blur(radius: 80)
                .opacity(0.35)
            VStack(spacing: 40) {
                CoverImage(path: now.info.coverPath, colorId: now.seriesId, radius: 20)
                    .frame(width: 800, height: TVLayout.coverHeight(800))
                VStack(spacing: 12) {
                    Text(now.info.episodeTitle).font(.title2).fontWeight(.semibold).lineLimit(2)
                    Text(now.info.seriesTitle).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1200)
                if let error {
                    // 重试在进度条上方的菜单里
                    Text(errorText(error)).foregroundStyle(C.danger)
                }
            }
            .padding(.bottom, 160)  // 给下面系统的进度条留出地方
        }
        .ignoresSafeArea()
    }

    private func errorText(_ e: PlayerError) -> String {
        switch e {
        case .cannotPlay: "暂时无法播放，请检查网络后重试"
        case .damaged: "这一集的文件已损坏"
        case .gone: "这一集已下架"
        }
    }
}
