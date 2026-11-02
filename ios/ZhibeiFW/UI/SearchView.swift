import SwiftUI
import UIKit

private var hasTabSearch: Bool {
    if #available(iOS 26.0, *) { return true } else { return false }
}

/// 搜索页：按键盘上的“搜索”才开始搜；没搜之前显示“输入课程名搜索”（分类磁贴在“分类”标签）。
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.windowWidth) private var W
    @State private var localText = ""
    /// iOS 26 用根视图上系统搜索框的文字，iOS 18 用页面里的搜索栏
    private var text: String { hasTabSearch ? model.searchQuery : localText }
    @State private var result: Store.SearchResult?

    var body: some View {
        let m = Layout.pageMargin(W)
        PageScaffold(title: "搜索", showBack: false) {
            VStack(alignment: .leading, spacing: 0) {
                // iOS 18–25：页面里的系统搜索栏（UISearchBar）；iOS 26 搜索框在底部“搜索”标签上，这里不放
                if !hasTabSearch {
                    SystemSearchBar(text: $localText, placeholder: "课程名", maxLength: MAX_QUERY_LENGTH, onSearch: runSearch) { result = nil }
                        .frame(maxWidth: .infinity, minHeight: CP.SearchField.height)  // 不让系统按内容算宽度，“取消”键留在屏幕里
                        .accessibilityLabel("搜索课程名")
                        .padding(.horizontal, m - Tok.Space.searchBarInset)
                        .padding(.top, CP.SearchField.topGap - CP.PageTitle.bottomGap)
                }

                if let r = result {
                    results(r).padding(.top, CP.Tile.topGap)
                } else {
                    // 没搜之前：系统的空状态提示
                    EmptyStateView(text: "输入课程名搜索").padding(.top, Tok.Space.scale[6] * 3)
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .onChange(of: model.searchSubmitted) { runSearch() }
        .onChange(of: model.searchQuery) { _, v in
            if v.count > MAX_QUERY_LENGTH { model.searchQuery = String(v.prefix(MAX_QUERY_LENGTH)) }
            if v.isEmpty { result = nil }
        }
    }

    private func runSearch() {
        let q = normalizeText(text)
        guard !q.isEmpty else { return }
        result = try? model.store.searchSeries(text)
    }

    @ViewBuilder private func results(_ r: Store.SearchResult) -> some View {
        if r.rows.isEmpty {
            EmptyStateView(text: "未找到相关内容").padding(.top, Tok.Space.scale[6] * 3)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if r.fallback {
                    Text("已显示“\(r.matched)”的结果").zFont(S.caption).foregroundStyle(C.labelSecondary).padding(
                        .horizontal, Layout.pageMargin(W))
                }
                LazyVStack(spacing: 0) {
                    ForEach(r.rows) { c in ListRowView(card: c) { model.nav.push(.series(c.id)) } }
                }
            }
        }
    }

}

/// 分类页（一级页）：分类磁贴，点进分类完整课程列表。
struct CategoriesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.windowWidth) private var W
    @Environment(\.dynamicTypeSize) private var dts
    @State private var tiles: [CategoryTile] = []

    var body: some View {
        PageScaffold(title: "分类", showBack: false) {
            tileGrid.padding(.top, CP.Tile.topGap)
        }
        .task(id: model.catalogVersion) { tiles = (try? model.store.loadCategories()) ?? [] }
    }

    private var tileGrid: some View {
        let large = Layout.isLargeText(fontScale(dts))
        let cols = large ? 1 : Layout.tileColumns(W)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: CP.Tile.gap), count: cols), spacing: CP.Tile.gap) {
            ForEach(tiles) { t in
                Button {
                    model.nav.push(.category(t.id))
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: Tok.Radius.tile, style: .continuous).fill(
                            resolveCategoryColor(t.color, id: t.id).color)
                        VStack {
                            HStack {
                                Spacer();
                                ZIcon(
                                    name: resolveCategoryIcon(t.icon, id: t.id), size: CP.Tile.iconSize,
                                    color: C.onColor.opacity(CP.Tile.iconOpacity))
                            }
                            Spacer()
                            HStack {
                                Text(t.name).zFont(S.tileText).foregroundStyle(C.onColor).lineLimit(large ? nil : 1); Spacer()
                            }
                        }
                        .padding(CP.Tile.padding)
                    }
                    .frame(minHeight: CP.Tile.height)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("\(t.name)，点按查看全部课程")
            }
        }
        .padding(.horizontal, Layout.pageMargin(W))
    }
}

/// 分类完整课程列表：无限下拉加载。
struct CategoryView: View {
    var categoryId: String
    @Environment(AppModel.self) private var model
    @State private var rows: [SeriesCard] = []
    @State private var done = false
    @State private var busy = false
    @State private var loaded = false
    private let pageSize = 40

    var body: some View {
        PageScaffold(title: model.store.categoryName(categoryId) ?? categoryId) {
            if loaded && rows.isEmpty {
                EmptyStateView(text: "暂无课程").padding(.top, Tok.Space.scale[6] * 3)
            }
            LazyVStack(spacing: CP.SeriesRow.gap) {
                ForEach(rows) { c in
                    SeriesRowView(id: c.id, title: c.title, meta: [seriesStatusText(c.status)], coverPath: c.coverPath) {
                        model.nav.push(.series(c.id))
                    }
                    .onAppear { if c.id == rows.last?.id { more() } }
                }
            }
        }
        .task(id: model.catalogVersion) { reload() }
    }

    private func reload() {
        rows = (try? model.store.loadCategorySeries(categoryId, limit: pageSize, offset: 0)) ?? []
        done = rows.count < pageSize
        loaded = true
    }

    private func more() {
        guard !done, !busy else { return }
        busy = true
        defer { busy = false }
        let next = (try? model.store.loadCategorySeries(categoryId, limit: pageSize, offset: rows.count)) ?? []
        var seen = Set(rows.map(\.id))
        rows += next.filter { seen.insert($0.id).inserted }
        if next.count < pageSize { done = true }
    }
}

/// UIKit 的系统搜索栏（极简样式，没有额外的底框）。
struct SystemSearchBar: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var maxLength: Int
    var onSearch: () -> Void
    var onClear: () -> Void

    func makeUIView(context: Context) -> UISearchBar {
        let b = UISearchBar()
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        b.setContentHuggingPriority(.defaultLow, for: .horizontal)
        b.searchBarStyle = .minimal
        b.placeholder = placeholder
        b.autocorrectionType = .no
        b.autocapitalizationType = .none
        b.returnKeyType = .search
        b.delegate = context.coordinator
        return b
    }

    func updateUIView(_ b: UISearchBar, context: Context) {
        if b.text != text { b.text = text }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UISearchBarDelegate {
        var parent: SystemSearchBar
        init(_ p: SystemSearchBar) { parent = p }

        func searchBarTextDidBeginEditing(_ b: UISearchBar) {
            b.setShowsCancelButton(true, animated: true)
        }
        func searchBarTextDidEndEditing(_ b: UISearchBar) { if (b.text ?? "").isEmpty { b.setShowsCancelButton(false, animated: true) } }
        func searchBar(_ b: UISearchBar, textDidChange t: String) {
            let v = t.count > parent.maxLength ? String(t.prefix(parent.maxLength)) : t
            if v != t { b.text = v }
            parent.text = v
            if v.isEmpty { parent.onClear() }
        }
        func searchBarSearchButtonClicked(_ b: UISearchBar) { b.resignFirstResponder(); parent.onSearch() }
        func searchBarCancelButtonClicked(_ b: UISearchBar) {
            b.text = ""; parent.text = ""; parent.onClear()
            b.resignFirstResponder(); b.setShowsCancelButton(false, animated: true)
        }
    }
}
