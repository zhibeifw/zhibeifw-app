import SwiftUI

/// 搜索：系统的电视搜索框（屏幕键盘，也可以用 Siri 遥控器听写），按课程名搜，和 iPhone 同一套查询。
/// 电视上没有“搜索”键：停止输入一会儿就自动搜。
struct TVSearchView: View {
    @Environment(AppCore.self) private var core
    @State private var query = ""
    @State private var result: Store.SearchResult?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 30) {
                if result == nil {
                    // 没搜之前：和 iPhone 一样的提示
                    Text("输入课程名或拼音首字母搜索，比如 jgj 找“金刚经”").foregroundStyle(.secondary)
                }
                if let r = result {
                    if r.rows.isEmpty {
                        Text("未找到相关内容").foregroundStyle(.secondary)
                    } else {
                        if r.fallback {
                            Text("已显示“\(r.matched)”的结果").font(.callout).foregroundStyle(.secondary)
                        }
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.fixed(TVLayout.smallCardWidth), spacing: TVLayout.cardGap), count: 4),
                            alignment: .leading, spacing: 60
                        ) {
                            ForEach(r.rows) { c in TVSeriesCard(card: c, width: TVLayout.smallCardWidth) }
                        }
                    }
                }
            }
            .padding(TVLayout.pageMargin)
        }
        .searchable(text: $query, prompt: "课程名或拼音首字母")
        .onChange(of: query) { _, v in
            if v.count > MAX_QUERY_LENGTH { query = String(v.prefix(MAX_QUERY_LENGTH)) }
        }
        // 输入停 0.4 秒再搜；又输入了就取消上一次（task(id:) 换 id 时会取消旧任务）
        .task(id: query) {
            let q = query
            guard !normalizeText(q).isEmpty else { result = nil; return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let store = core.store!
            // 搜不到整句时会从开头逐字加长多查几次，放到后台，不卡输入
            let r = await Task.detached(priority: .userInitiated) { try? store.searchSeries(q) }.value
            guard !Task.isCancelled else { return }
            result = r
        }
    }
}
