import SwiftUI

/// 最近收听：选一集接着播。
struct TVRecentView: View {
    @Environment(AppCore.self) private var core
    @State private var rows: [RecentRow] = []

    var body: some View {
        Group {
            if rows.isEmpty {
                Text("还没有收听记录").foregroundStyle(.secondary)
            } else {
                List(rows) { r in
                    Button {
                        core.playFromRecent(r, open: true)
                    } label: {
                        HStack(spacing: 32) {
                            CoverImage(path: r.coverPath, colorId: r.seriesId, radius: 8)
                                .frame(width: 192, height: TVLayout.coverHeight(192))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(r.epTitle).lineLimit(2)
                                Text(r.seriesTitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(r.gone ? "已下架" : progressText(r.progress, knownDuration: r.epDuration))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task(id: [core.catalogVersion, core.progressVersion]) {
            rows = (try? core.store.loadRecent(limit: 200)) ?? []
        }
    }
}

/// 收藏：选一门课进课程页。
struct TVFavoritesView: View {
    @Environment(AppCore.self) private var core
    @State private var rows: [FavoriteRow] = []

    var body: some View {
        Group {
            if rows.isEmpty {
                Text("还没有收藏的课程").foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(TVLayout.smallCardWidth), spacing: TVLayout.cardGap), count: 4),
                        alignment: .leading, spacing: 60
                    ) {
                        ForEach(rows) { f in
                            TVSeriesCard(card: SeriesCard(id: f.id, title: f.title, coverPath: f.coverPath, status: f.status ?? ""),
                                         width: TVLayout.smallCardWidth)
                        }
                    }
                    .padding(TVLayout.pageMargin)
                }
            }
        }
        .task(id: [core.catalogVersion, core.favoritesVersion]) {
            rows = (try? core.store.loadFavorites()) ?? []
        }
    }
}
