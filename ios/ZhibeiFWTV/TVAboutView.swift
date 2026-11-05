import SwiftUI

/// 关于：和 iPhone 同样的几项。电视上没有浏览器：隐私政策的全文打包在 App 里直接显示，源代码只显示网址。
struct TVAboutView: View {
    @Environment(AppCore.self) private var core
    @State private var clearing = false
    @State private var checking = false
    @State private var clearResult: String?
    @State private var routeResult: String?

    var body: some View {
        HStack(alignment: .top, spacing: 100) {
            VStack(spacing: 24) {
                Image("Logo").resizable().scaledToFit().frame(width: 200).accessibilityLabel("智悲佛网 Logo")
                Text("智悲佛网").font(.title2).fontWeight(.semibold)
                Text("联系：hello@zhibeifw.com").font(.callout)
                VStack(spacing: 20) {
                    Button { clearCache() } label: {
                        row("清除缓存", clearing ? "正在清除…" : clearResult)
                    }
                    Button { refreshRoutes() } label: {
                        row("刷新网络线路", checking ? "正在检测…" : routeResult)
                    }
                }
                .frame(width: 640)
                .padding(.top, 20)
                Spacer()
                Text("智悲佛网 版权所有").font(.caption).foregroundStyle(.secondary)
                Text("版本 " + AppInfo.version).font(.caption).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 40) {
                NavigationLink(value: TVRoute.privacy) { row("隐私政策", nil) }
                    .frame(width: 640)
                // 源代码只显示网址（电视上打不开网页）
                VStack(alignment: .leading, spacing: 8) {
                    Text("源代码").font(.headline)
                    Text(NetConfig.sourceURL.absoluteString).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(TVLayout.pageMargin)
    }

    private func row(_ title: String, _ value: String?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let value { Text(value).foregroundStyle(.secondary) }
        }
    }

    private func clearCache() {
        guard !clearing else { return }
        clearing = true
        Task {
            defer { clearing = false }
            do { try ImageLoader.shared.clear(); OriginWatcher.shared.bump(); clearResult = "已清除" } catch {
                clearResult = "清除失败"
            }
        }
    }

    private func refreshRoutes() {
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            routeResult = await core.refreshRoutes()
        }
    }
}

/// 隐私政策全文（打包在 App 里的 privacy.txt，和网站上的一致；改了网站上的文字要同步改这个文件）。
/// 遥控器只能在能选中的东西之间移动：按段落拆开、每段都能选中，上下键一段段往下读。
struct TVPrivacyView: View {
    private let paragraphs: [String] = {
        guard let url = Bundle.main.url(forResource: "privacy", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }()

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                Text("隐私政策").font(.title2).fontWeight(.semibold)
                if paragraphs.isEmpty {
                    Text("隐私政策：\(NetConfig.privacyURL.absoluteString)").focusable()
                }
                ForEach(paragraphs.indices, id: \.self) { i in
                    Text(paragraphs[i]).font(.callout).focusable()
                }
            }
            .frame(maxWidth: 1400, alignment: .leading)
            .padding(TVLayout.pageMargin)
        }
    }
}
