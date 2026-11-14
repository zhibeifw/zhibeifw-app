import SwiftUI

/// 商店渠道的内容版本提示，不阻挡浏览和播放。
struct StoreUpgradeNotice: View {
    let checker: UpgradeChecker
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading) {
            Text("此版本过旧，已无法获得最新的内容更新，请到 App Store 更新")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: Tok.Component.Vision.hitGap) {
                Button {
                    checker.outdatedDismissed = true
                } label: {
                    actionLabel("关闭")
                }
                if !NetConfig.iosStoreURL.isEmpty, let url = URL(string: NetConfig.iosStoreURL) {
                    Button {
                        openURL(url)
                    } label: {
                        actionLabel("更新")
                    }
                }
            }
        }
    }

    private func actionLabel(_ title: String) -> some View {
        #if os(visionOS)
            Text(title).visionHitTarget()
        #else
            Text(title)
        #endif
    }
}
