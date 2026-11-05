import SwiftUI
import CoreImage.CIFilterBuiltins

/// 关于：和 iPhone 同样的几项。电视上没有浏览器，隐私政策、源代码给二维码，用手机扫码打开。
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
            HStack(spacing: 60) {
                QRCard(title: "隐私政策", url: NetConfig.privacyURL)
                QRCard(title: "源代码", url: NetConfig.sourceURL)
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

/// 一个网址的二维码 + 标题 + 网址文字。
private struct QRCard: View {
    let title: String
    let url: URL

    var body: some View {
        VStack(spacing: 20) {
            if let img = qrImage(url.absoluteString) {
                Image(decorative: img, scale: 1)
                    .interpolation(.none)  // 放大时保持方块清晰，不糊
                    .resizable()
                    .frame(width: 300, height: 300)
                    .padding(24)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 16))  // 深色模式下也是白底黑码，手机才扫得出
            }
            Text(title).font(.headline)
            Text("用手机扫码查看").font(.caption).foregroundStyle(.secondary)
            Text(url.absoluteString).font(.caption2).foregroundStyle(.tertiary)
        }
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
