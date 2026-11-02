import SwiftUI

/// 主页。
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.windowWidth) private var W
    @Environment(\.dynamicTypeSize) private var dts

    var body: some View {
        let h = model.home
        PageScaffold(
            title: "主页", showBack: false, onRefresh: { await model.syncCatalog(userInitiated: true) },
            trailing: {
                Button {
                    model.nav.push(.about)
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("关于智悲佛网")
            }
        ) {
            VStack(alignment: .leading, spacing: 0) {
                if model.syncFailed {
                    BannerView(text: "无法更新，显示的是上一次更新的内容", actions: [("重试", { Task { await model.syncCatalog(userInitiated: true) } })])
                        .padding(.bottom, CP.Banner.bottomGap)
                }
                if model.upgrade.outdated && !model.upgrade.outdatedDismissed {
                    BannerView(
                        text: "此版本过旧，已无法获得最新的内容更新，请到 App Store 更新",
                        actions: [("关闭", { model.upgrade.outdatedDismissed = true })]
                            + (NetConfig.iosStoreURL.isEmpty
                                ? [] : [("更新", { if let u = URL(string: NetConfig.iosStoreURL) { UIApplication.shared.open(u) } })])
                    )
                    .padding(.bottom, CP.Banner.bottomGap)
                }
                VStack(alignment: .leading, spacing: Tok.Space.sectionGap) {
                    if !h.ongoing.isEmpty {
                        section("新课程", nil) {
                            CardRow(cards: h.ongoing, large: true, subtitleOf: { c in c.lastTitle.map { "更新至 \($0)" } }) {
                                model.nav.push(.series($0.id))
                            }
                        }
                    }
                    if !h.featured.isEmpty {
                        section("编辑精选", nil) {
                            CardRow(cards: h.featured, large: false, titleOf: { $0.featureTitle ?? $0.title }) {
                                model.nav.push(.series($0.id))
                            }
                        }
                    }
                    ForEach(h.categories) { c in
                        section(c.name, { model.nav.push(.category(c.id)) }) {
                            CardRow(cards: c.series, large: false) { model.nav.push(.series($0.id)) }
                        }
                    }
                }
            }
        }
        // 后台自动检查更新时，导航栏正中显示系统转圈 + “正在更新…”（居中、圈在左字在右）；
        // 放在导航栏里，出现、消失都不挤动内容
        .toolbar {
            if model.autoUpdating {
                ToolbarItem(placement: .principal) { UpdatingHint() }.hidingSharedBackground()
            }
        }
    }

    private func section<C: View>(_ title: String, _ action: (() -> Void)?, @ViewBuilder _ row: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Tok.Space.sectionTitleToRow) {
            SectionTitle(title: title, action: action)
            row()
        }
    }
}

/// 主页顶部正中的“正在更新…”：系统转圈（small）在左 + 小字在右。
private struct UpdatingHint: View {
    var body: some View {
        HStack(spacing: CP.UpdatingHint.gap) {
            ProgressView().controlSize(.small)
            Text("正在更新…").zFont(S.caption).foregroundStyle(C.labelSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension ToolbarContent {
    /// iOS 26 起导航栏按钮自带玻璃底；这里只是一行状态文字，不要底
    @ToolbarContentBuilder func hidingSharedBackground() -> some ToolbarContent {
        if #available(iOS 26.0, *) { self.sharedBackgroundVisibility(.hidden) } else { self }
    }
}
