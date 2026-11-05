import SwiftUI

/// 电视卡片尺寸（点）。电视按 1920 × 1080 点排版，三米外看：卡片比手机大得多。
enum TVLayout {
    static let pageMargin: CGFloat = 80
    static let largeCardWidth: CGFloat = 548
    static let smallCardWidth: CGFloat = 400
    static let cardGap: CGFloat = 40
    static let coverRadius: CGFloat = 12
    static func coverHeight(_ w: CGFloat) -> CGFloat { (w * 9 / 16).rounded() }
}

/// 首页：新课程、编辑精选、各分类，每行横向滚动。
struct TVHomeView: View {
    @Environment(AppCore.self) private var core

    var body: some View {
        let home = core.home
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 60) {
                if core.syncFailed {
                    Text("无法更新，显示的是上一次更新的内容").font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, TVLayout.pageMargin)
                }
                if !home.ongoing.isEmpty {
                    TVCardRow(title: "新课程", cards: home.ongoing, width: TVLayout.largeCardWidth)
                }
                if !home.featured.isEmpty {
                    TVCardRow(title: "编辑精选", cards: home.featured, width: TVLayout.smallCardWidth)
                }
                ForEach(home.categories) { c in
                    // 分类行的标题可以选：进这个分类的全部课程（和 iPhone 一样）
                    TVCardRow(title: c.name, cards: c.series, width: TVLayout.smallCardWidth, more: .category(c.id))
                }
            }
            .padding(.vertical, 40)
        }
    }
}

/// 一行卡片：标题 + 横向滚动。
struct TVCardRow: View {
    let title: String
    let cards: [SeriesCard]
    let width: CGFloat
    /// 标题可以选时进的页面（分类）
    var more: TVRoute? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Group {
                if let more {
                    NavigationLink(value: more) {
                        Label(title, systemImage: "chevron.right").labelStyle(TitleThenIcon())
                    }
                    .buttonStyle(.borderless)
                } else {
                    Text(title)
                }
            }
            .font(.title3).fontWeight(.semibold).padding(.horizontal, TVLayout.pageMargin)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: TVLayout.cardGap) {
                    ForEach(cards) { card in TVSeriesCard(card: card, width: width) }
                }
                .padding(.horizontal, TVLayout.pageMargin)
                .padding(.vertical, 20)  // 聚焦时卡片放大，上下留出空间
            }
            .scrollClipDisabled()
        }
    }
}

/// 课程卡片：封面 + 课程名。用系统的卡片按钮样式（聚焦时放大、带阴影和光泽）。
struct TVSeriesCard: View {
    let card: SeriesCard
    let width: CGFloat
    /// 收藏页：长按确认键出“取消收藏”
    var onRemoveFavorite: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let onRemoveFavorite {
                link.contextMenu {
                    Button(role: .destructive, action: onRemoveFavorite) {
                        Label("取消收藏", systemImage: "bookmark.slash")
                    }
                }
            } else {
                link
            }
            VStack(alignment: .leading, spacing: 4) {
                // 和 iPhone 一致：编辑精选用精选标题，新课程下面写“更新至 最后一集”
                Text(card.featureTitle ?? card.title).font(.callout).lineLimit(2)
                if let last = card.lastTitle {
                    Text("更新至 \(last)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private var link: some View {
        NavigationLink(value: TVRoute.series(card.id)) {
            CoverImage(path: card.coverPath, colorId: card.id, radius: TVLayout.coverRadius)
                .frame(width: width, height: TVLayout.coverHeight(width))
        }
        .buttonStyle(.card)
    }
}

/// 文字在前、箭头在后（“分类名 ›”）。
struct TitleThenIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.title
            configuration.icon.font(.callout).foregroundStyle(.secondary)
        }
    }
}
