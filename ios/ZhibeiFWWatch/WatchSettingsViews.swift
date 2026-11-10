import SwiftUI

struct WatchSettingsView: View {
    @Environment(AppCore.self) private var core
    @State private var checkingRoutes = false
    @State private var clearing = false
    @State private var routeResult: String?
    @State private var clearResult: String?

    var body: some View {
        List {
            Section("设置") {
                Button {
                    guard !clearing else { return }
                    clearing = true
                    Task {
                        defer { clearing = false }
                        do {
                            try ImageLoader.shared.clear()
                            OriginWatcher.shared.bump()
                            clearResult = "已清除"
                        } catch { clearResult = "清除失败，请重试" }
                        if let clearResult { AccessibilityNotification.Announcement(clearResult).post() }
                    }
                } label: {
                    VStack(alignment: .leading) {
                        Text("清除缓存")
                        if let clearResult { Text(clearResult).font(.footnote).foregroundStyle(.secondary) }
                    }
                }

                Button {
                    guard !checkingRoutes else { return }
                    checkingRoutes = true
                    Task {
                        routeResult = await core.refreshRoutes()
                        checkingRoutes = false
                        if let routeResult { AccessibilityNotification.Announcement(routeResult).post() }
                    }
                } label: {
                    VStack(alignment: .leading) {
                        Text("刷新网络线路")
                        if checkingRoutes {
                            Text("正在检测…").font(.footnote).foregroundStyle(.secondary)
                        } else if let routeResult {
                            Text(routeResult).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                NavigationLink("联系", value: WatchRoute.contact)
                NavigationLink("隐私政策", value: WatchRoute.privacy)
                NavigationLink("源代码", value: WatchRoute.source)
            } header: {
                Text("关于")
            } footer: {
                VStack {
                    Text("智悲佛网")
                    Text("版本 \(AppInfo.version)")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("设置")
    }
}

struct WatchPrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                Text(verbatim: WatchPrivacyPolicy.text)
                Text(verbatim: "\n" + NetConfig.privacyURL.absoluteString)
                    .font(.footnote)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("隐私政策")
    }
}

struct WatchSourceView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                Text("本 App 的源代码采用 Apache License 2.0 开源。\n")
                Text(verbatim: NetConfig.sourceURL.absoluteString)
                    .font(.footnote)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("源代码")
    }
}

struct WatchContactView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                Text("电子邮件").font(.headline)
                Text(verbatim: "hello@zhibeifw.com")
                    .font(.footnote)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("联系")
    }
}
