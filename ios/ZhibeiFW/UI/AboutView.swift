import SwiftUI
import SafariServices

/// 关于智悲佛网。居中小标题，不用大标题；不接入悬浮导航。
struct AboutView: View {
    @Environment(AppModel.self) private var model
    @State private var clearing = false
    @State private var checking = false
    /// 清除缓存、刷新网络线路的结果显示在那一行右边（HIG：普通结果不用弹窗）
    @State private var clearResult: String?
    @State private var routeResult: String?
    @State private var safari: URL?

    var body: some View {
        List {
            Section("设置") {
                row(title: "清除缓存", value: clearing ? "正在清除…" : clearResult) { clearCache() }
                row(title: "刷新网络线路", value: checking ? "正在检测…" : routeResult) { refreshRoutes() }
            }
            Section {
                row(title: "联系", value: "hello@zhibeifw.com", selectable: true)
                row(title: "隐私政策", arrow: true) { openWeb(NetConfig.privacyURL) }
                row(title: "源代码", arrow: true) { openWeb(NetConfig.sourceURL) }
            } header: {
                Text("关于")
            } footer: {
                footer.frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.vertical)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $safari) { SafariView(url: $0).ignoresSafeArea() }
    }

    private var footer: some View {
        VStack(spacing: CP.About.footerGap) {
            Text("智悲佛网").zFont(S.caption).foregroundStyle(C.labelSecondary)
            Text("版本 " + AppInfo.version).zFont(S.caption).foregroundStyle(C.labelTertiary)
        }
    }

    @ViewBuilder
    private func row(
        title: String, value: String? = nil, selectable: Bool = false, arrow: Bool = false, action: (() -> Void)? = nil
    ) -> some View {
        let content = HStack(spacing: Tok.Space.scale[2]) {
            Text(title).zFont(S.body).foregroundStyle(C.labelPrimary)
            Spacer(minLength: 0)
            if let value {
                if selectable {
                    Text(value).zFont(S.body).foregroundStyle(C.labelSecondary).textSelection(.enabled)
                } else {
                    Text(value).zFont(S.body).foregroundStyle(C.labelSecondary).multilineTextAlignment(.trailing)
                }
            }
            if arrow { ZIcon(name: "chevron-forward", size: CP.SectionTitle.arrowSize, color: C.labelTertiary) }
        }
        .frame(minHeight: CP.About.rowMinHeight)
        .contentShape(Rectangle())
        if let action { Button(action: action) { content }.buttonStyle(PressableStyle()) } else { content }
    }

    /// 打开网页的统一方式：① App 内浏览器；② 系统打开链接；③ 弹“无法打开网页”。没网先提示。
    private func openWeb(_ url: URL) {
        guard Connectivity.shared.connected else { model.alert = AlertSpec(title: "需要联网才能查看"); return }
        if url.scheme == "https" { safari = url; return }
        UIApplication.shared.open(url) { ok in if !ok { model.alert = AlertSpec(title: "无法打开网页") } }
    }

    private func clearCache() {
        guard !clearing else { return }
        clearing = true
        Task {
            defer { clearing = false }
            do { try ImageLoader.shared.clear(); OriginWatcher.shared.bump(); clearResult = announce("已清除") } catch {
                clearResult = announce("清除失败")
            }
        }
    }

    private func refreshRoutes() {
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            routeResult = announce(await model.refreshRoutes())
        }
    }

    /// 结果写在行上，同时让读屏念出来（不弹窗时读屏用户也能知道结果）
    private func announce(_ text: String) -> String {
        AccessibilityNotification.Announcement(text).post()
        return text
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
