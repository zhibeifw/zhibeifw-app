import SwiftUI

/// 分类：彩色磁贴（颜色、图标和 iPhone 一样），选一个进这个分类的全部课程。
struct TVCategoriesView: View {
    @Environment(AppCore.self) private var core
    @State private var tiles: [CategoryTile] = []

    var body: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: TVLayout.cardGap), count: 4), spacing: TVLayout.cardGap) {
                ForEach(tiles) { t in
                    NavigationLink(value: TVRoute.category(t.id)) {
                        ZStack {
                            resolveCategoryColor(t.color, id: t.id).color
                            VStack {
                                HStack {
                                    Spacer()
                                    ZIcon(name: resolveCategoryIcon(t.icon, id: t.id), size: 56, color: C.onColor.opacity(0.85))
                                }
                                Spacer()
                                HStack {
                                    Text(t.name).font(.title3).fontWeight(.semibold).foregroundStyle(C.onColor).lineLimit(1)
                                    Spacer()
                                }
                            }
                            .padding(28)
                        }
                        .frame(height: 200)
                    }
                    .buttonStyle(.card)
                }
            }
            .padding(TVLayout.pageMargin)
        }
        .task(id: core.catalogVersion) { tiles = (try? core.store.loadCategories()) ?? [] }
    }
}

/// 一个分类的全部课程：卡片网格，滚到底再取下一页（每页 40 门，和 iPhone 一样）。
struct TVCategoryView: View {
    @Environment(AppCore.self) private var core
    let categoryId: String
    @State private var rows: [SeriesCard] = []
    @State private var done = false
    @State private var loaded = false
    @State private var title = ""
    private let pageSize = 40

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                Text(title).font(.title2).fontWeight(.semibold)
                if loaded && rows.isEmpty {
                    Text("暂无课程").foregroundStyle(.secondary)
                }
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(TVLayout.smallCardWidth), spacing: TVLayout.cardGap), count: 4),
                    alignment: .leading, spacing: 60
                ) {
                    ForEach(rows) { c in
                        TVSeriesCard(card: c, width: TVLayout.smallCardWidth)
                            .onAppear { if c.id == rows.last?.id { more() } }
                    }
                }
            }
            .padding(TVLayout.pageMargin)
        }
        .task(id: core.catalogVersion) { reload() }
    }

    private func reload() {
        title = core.store.categoryName(categoryId) ?? categoryId
        rows = (try? core.store.loadCategorySeries(categoryId, limit: pageSize, offset: 0)) ?? []
        done = rows.count < pageSize
        loaded = true
    }

    private func more() {
        guard !done else { return }
        let next = (try? core.store.loadCategorySeries(categoryId, limit: pageSize, offset: rows.count)) ?? []
        var seen = Set(rows.map(\.id))
        rows += next.filter { seen.insert($0.id).inserted }
        if next.count < pageSize { done = true }
    }
}
