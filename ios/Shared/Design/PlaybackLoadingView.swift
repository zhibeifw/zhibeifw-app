import SwiftUI

/// 保留图标原占位，加载动画不阻止外层播放按钮接收暂停操作。
struct PlaybackLoadingView<Content: View>: View {
    let loading: Bool
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            content.opacity(loading ? 0 : 1)
            if loading {
                ProgressView().controlSize(.small).accessibilityLabel("正在加载")
            }
        }
    }
}
