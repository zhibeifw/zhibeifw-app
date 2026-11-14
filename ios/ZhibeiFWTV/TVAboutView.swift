import SwiftUI
import CoreImage.CIFilterBuiltins

let CONTACT_EMAIL = "hello@zhibeifw.com"

/// 关于：设置与关于两个分组，下方居中显示应用名称和版本。
/// 电视上没有浏览器、也不能发邮件：联系进去显示电邮地址；隐私政策、源代码进去是二维码和网址。
struct TVAboutView: View {
    @Environment(AppCore.self) private var core
    @State private var clearing = false
    @State private var checking = false
    @State private var clearResult: String?
    @State private var routeResult: String?

    var body: some View {
        List {
            Section("设置") {
                Button { clearCache() } label: { row("清除缓存", clearing ? "正在清除…" : clearResult) }
                Button { refreshRoutes() } label: { row("刷新网络线路", checking ? "正在检测…" : routeResult) }
            }
            Section {
                NavigationLink(value: TVRoute.contact) { row("联系", CONTACT_EMAIL) }
                NavigationLink(value: TVRoute.privacy) { row("隐私政策", nil) }
                NavigationLink(value: TVRoute.source) { row("源代码", nil) }
            } header: {
                Text("关于")
            } footer: {
                VStack(spacing: 8) {
                    Text("智悲佛网")
                    Text("版本 " + AppInfo.version)
                }
                .font(.caption)
                .frame(maxWidth: .infinity)
                .padding(.top, 30)
            }
        }
        .frame(maxWidth: 1000)
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

/// 联系：电邮地址（电视上不能发邮件，大字显示，抄下来用手机或电脑发）。
struct TVContactView: View {
    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "envelope").font(.system(size: 80)).foregroundStyle(.secondary)
            Text("联系我们").font(.title3).foregroundStyle(.secondary)
            Text(CONTACT_EMAIL).font(.title).fontWeight(.semibold)
                .focusable()  // 页面上总要有一个能选中的，返回键才有地方落
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 隐私政策、源代码：二维码（手机扫码打开）和网址。电视上打不开网页。
/// 隐私政策的全文另外填在 App Store Connect 的“Apple TV 隐私政策”文字栏里，在电视的 App Store 页面上能读到。
struct TVLinkView: View {
    let title: String
    let url: URL

    var body: some View {
        VStack(spacing: 30) {
            Text(title).font(.title3).foregroundStyle(.secondary)
            if let img = qrImage(url.absoluteString) {
                Image(decorative: img, scale: 1)
                    .interpolation(.none)  // 放大时方块保持清晰，不糊
                    .resizable()
                    .frame(width: 360, height: 360)
                    .padding(28)
                    .background(Color.white)  // 二维码要白底黑码、四周留白边，深色模式下手机才扫得出（功能需要，不是装饰）
            }
            Text("用手机扫码查看").font(.callout).foregroundStyle(.secondary)
            Text(url.absoluteString).font(.title3)
                .focusable()  // 页面上总要有一个能选中的，遥控器按键才有反应
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 用系统的 CoreImage 生成二维码（不用第三方库）。
private func qrImage(_ text: String) -> CGImage? {
    let f = CIFilter.qrCodeGenerator()
    f.message = Data(text.utf8)
    f.correctionLevel = "M"
    guard let out = f.outputImage else { return nil }
    return CIContext().createCGImage(out, from: out.extent)
}
