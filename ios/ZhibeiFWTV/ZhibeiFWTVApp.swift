import SwiftUI

/// Apple TV 版入口。界面还没做：这一版只用来确认共用代码（ios/Shared）能在 tvOS 上编译、运行。
@main
struct ZhibeiFWTVApp: App {
    var body: some Scene {
        WindowGroup { PlaceholderView() }
    }
}

private struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("智悲佛网").font(.largeTitle).foregroundStyle(C.labelPrimary)
            Text("Apple TV 版开发中").font(.title3).foregroundStyle(C.labelSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.background)
    }
}
