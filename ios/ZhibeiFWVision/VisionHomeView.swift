import SwiftUI

struct VisionHomeView: View {
    @Environment(AppCore.self) private var core
    @Environment(VisionModel.self) private var model
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tok.Component.Vision.sectionGap) {
                if model.upgrade.showsNotice {
                    StoreUpgradeNotice(checker: model.upgrade)
                        .padding(.horizontal, Tok.Component.Vision.pageMargin)
                }
                if core.syncFailed {
                    Text("无法更新，显示上次内容").foregroundStyle(.secondary)
                        .padding(.horizontal, Tok.Component.Vision.pageMargin)
                }
                if !core.home.ongoing.isEmpty {
                    VisionCardShelf(title: "最新课程", cards: core.home.ongoing, large: true)
                }
                if !core.home.featured.isEmpty {
                    VisionCardShelf(title: "编辑精选", cards: core.home.featured)
                }
                ForEach(core.home.categories) { category in
                    VisionCardShelf(title: category.name, cards: category.series, category: category.id)
                }
            }
            .padding(.vertical, Tok.Component.Vision.pageMargin)
        }
    }
}

struct VisionCardShelf: View {
    let title: String
    let cards: [SeriesCard]
    var large = false
    var category: String? = nil
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title).font(.title2).fontWeight(.semibold)
                Spacer()
                if let category {
                    NavigationLink(value: VisionRoute.category(category, title)) { Text("查看全部").visionHitTarget() }
                }
            }
            .padding(.horizontal)
            .padding(.horizontal, Tok.Component.Vision.pageMargin)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Tok.Component.Vision.cardGap) {
                    ForEach(cards) { card in
                        VisionCourseCard(
                            id: card.id, title: card.featureTitle ?? card.title, cover: card.coverPath,
                            subtitle: card.lastTitle.map { "更新至 " + $0 }, large: large)
                    }
                }
                .padding(.horizontal, Tok.Component.Vision.pageMargin)
                .padding(.vertical)
            }
        }
    }
}

struct VisionCourseCard: View {
    let id: String
    let title: String
    let cover: String
    var subtitle: String? = nil
    var large = false
    var fillsWidth = false
    var body: some View {
        NavigationLink(value: VisionRoute.series(id)) {
            VStack(alignment: .leading) {
                VisionArtwork(path: cover, large: true)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Tok.Radius.cardLarge))
                Text(title).font(.headline).lineLimit(2)
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
            }
            .padding()
            .frame(
                width: fillsWidth ? nil : (large ? Tok.Component.Vision.largeCardWidth : Tok.Component.Vision.cardWidth),
                alignment: .leading
            )
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: Tok.Radius.cardLarge))
            .visionDebugBoundary()
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

struct VisionCategoriesView: View {
    let rows: [CategoryTile]
    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Tok.Component.Vision.categoryMinWidth), spacing: Tok.Component.Vision.cardGap)],
                spacing: Tok.Component.Vision.cardGap
            ) {
                ForEach(rows) { row in
                    NavigationLink(value: VisionRoute.category(row.id, row.name)) {
                        Color.clear
                            .aspectRatio(Tok.Component.Vision.categoryAspectRatio, contentMode: .fit)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: SymbolName.all[resolveCategoryIcon(row.icon, id: row.id)] ?? "book")
                                    .font(.system(size: Tok.Component.Vision.categoryIconSize))
                                    .opacity(Tok.Component.Tile.iconOpacity)
                                    .padding(Tok.Component.Vision.cardGap)
                                    .accessibilityHidden(true)
                            }
                            .overlay(alignment: .bottomLeading) {
                                Text(row.name).font(.title3).bold()
                                    .padding(Tok.Component.Vision.cardGap)
                            }
                            .foregroundStyle(.white)
                            .background(resolveCategoryColor(row.color, id: row.id).color)
                            .clipShape(RoundedRectangle(cornerRadius: Tok.Radius.cardLarge))
                            .contentShape(RoundedRectangle(cornerRadius: Tok.Radius.cardLarge))
            .visionDebugBoundary()
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                }
            }
            .padding(Tok.Component.Vision.pageMargin)
        }
    }
}

struct VisionFavoritesView: View {
    let rows: [FavoriteRow]
    @Environment(AppCore.self) private var core
    var body: some View {
        if rows.isEmpty {
            ContentUnavailableView("暂无收藏", systemImage: "bookmark")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Tok.Component.Vision.cardWidth))], alignment: .leading) {
                    ForEach(rows) { row in
                        VisionCourseCard(
                            id: row.id, title: row.title, cover: row.coverPath,
                            subtitle: row.gone ? "已下架" : seriesStatusText(row.status), fillsWidth: true
                        )
                        .contextMenu { Button("取消收藏") { core.removeFavorite(row.id) } }
                    }
                }
                .padding(Tok.Component.Vision.pageMargin)
            }
        }
    }
}
