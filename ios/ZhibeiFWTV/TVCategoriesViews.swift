import SwiftUI

/// 分类：系统按钮（系统图标 + 分类名），选一个进这个分类的全部课程。
struct TVCategoriesView: View {
    @Environment(AppCore.self) private var core
    @State private var tiles: [CategoryTile] = []

    var body: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: TVLayout.cardGap), count: 4), spacing: TVLayout.cardGap) {
                ForEach(tiles) { t in
                    NavigationLink(value: TVRoute.category(t.id)) {
                        Label(t.name, systemImage: categorySymbol(t))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(TVLayout.pageMargin)
        }
        .task(id: core.catalogVersion) { tiles = (try? core.store.loadCategories()) ?? [] }
    }

    /// 分类图标对应的系统图标（SF Symbols，和 iPhone 同一张对照表）；只有我们自绘、没有系统图标的，用系统的“书”。
    private func categorySymbol(_ t: CategoryTile) -> String {
        SymbolName.all[resolveCategoryIcon(t.icon, id: t.id)] ?? "book"
    }
}

/// 一个分类的全部课程：卡片网格，滚到底再取下一页（每页 40 门，和 iPhone 一样）。
struct TVCategoryView: View {
    @Environment(AppCore.self) private var core
    let categoryId: String
    @State private var rows: [SeriesCard]
    @State private var done: Bool
    @State private var loaded = true
    @State private var title: String
    private static let pageSize = 40
    private var pageSize: Int { Self.pageSize }

    /// 进页面时就把第一页读好（本机数据库，很快）：第一帧就有能选中的卡片。
    /// 不然页面刚推进来时没有能选中的东西，这时按返回键，系统会当成退出 App。
    init(categoryId: String, store: Store) {
        self.categoryId = categoryId
        let first = (try? store.loadCategorySeries(categoryId, limit: Self.pageSize, offset: 0)) ?? []
        _rows = State(initialValue: first)
        _done = State(initialValue: first.count < Self.pageSize)
        _title = State(initialValue: store.categoryName(categoryId) ?? categoryId)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                Text(title).font(.title2).fontWeight(.semibold)
                if loaded && rows.isEmpty {
                    Text("暂无课程").foregroundStyle(.secondary).focusable()
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
