import SwiftUI

struct UnavailableCourseView: View {
    let title: String?
    let favorited: Bool
    let removeFavorite: () -> Void
    #if os(tvOS)
    @FocusState private var actionFocused: Bool
    #endif

    var body: some View {
        ContentUnavailableView {
            Label(title ?? "这门课已下架", systemImage: "book.closed")
        } description: {
            if title != nil { Text("已下架") }
        } actions: {
            if favorited {
                Button(action: removeFavorite) {
                    Text("取消收藏")
                        .fixedSize(horizontal: true, vertical: false)
                        #if os(visionOS)
                        .visionHitTarget()
                        #endif
                }
                .buttonStyle(.bordered)
                #if os(tvOS)
                .focused($actionFocused)
                #endif
            }
        }
        #if os(tvOS)
        .defaultFocus($actionFocused, true)
        #endif
    }
}
