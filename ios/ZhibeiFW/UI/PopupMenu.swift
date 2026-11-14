import SwiftUI

// 菜单与课程简介弹窗：用系统自带的（PLATFORM-DIFFERENCES A16）。

struct MenuItem: Identifiable {
    /// 同一组里的标题不重复：用标题当身份，每次重画不会被当成一组新的
    var id: String { title }
    var title: String
    var icon: String? = nil
    var destructive = false
    var checked: Bool? = nil  // 非 nil：可勾选菜单（排序、睡眠定时），左边是对勾位
    var action: () -> Void
}

struct SheetSpec: Identifiable {
    let id = UUID()
    var title: String
    var category: String?
    var body: String
}

/// 系统菜单（菜单改用系统的）。“•••”、排序、睡眠定时都用它；
/// 组之间用系统的分组线，破坏性项系统红色；单选的组用系统 Picker（对勾由系统画）。图标用 SF Symbols。
struct NativeMenu<L: View>: View {
    var items: () -> [[MenuItem]]
    @ViewBuilder var label: () -> L

    var body: some View {
        Menu {
            ForEach(Array(items().enumerated()), id: \.offset) { _, group in
                if group.contains(where: { $0.checked != nil }) {
                    // 单选（睡眠定时、排序）：用系统的 Picker，对勾由系统画，和“播客”App 一样
                    Picker(
                        "",
                        selection: Binding(
                            get: { group.firstIndex { $0.checked == true } ?? -1 },
                            set: { i in if group.indices.contains(i) { group[i].action() } }
                        )
                    ) {
                        ForEach(Array(group.enumerated()), id: \.offset) { i, it in Text(it.title).tag(i) }
                    }
                    .pickerStyle(.inline)
                } else {
                    Section {
                        ForEach(group) { it in
                            Button(role: it.destructive ? .destructive : nil, action: it.action) {
                                if let sym = sfSymbol(it.icon) { Label(it.title, systemImage: sym) } else { Text(it.title) }
                            }
                        }
                    }
                }
            }
        } label: {
            label()
        }
        .menuOrder(.fixed)  // 从下往上弹时也保持原来的顺序
    }
}

/// 菜单项图标：项目里的图标名（Ionicons 风格）→ 系统图标。
func sfSymbol(_ name: String?) -> String? {
    switch name {
    case "arrow-down-circle-outline": "arrow.down.circle"
    case "pause-circle-outline": "pause.circle"
    case "close-circle-outline": "xmark.circle"
    case "trash-outline": "trash"
    case "checkmark-circle-outline": "checkmark.circle"
    case "rectangle.badge.checkmark": "rectangle.badge.checkmark"
    case "rectangle.badge.minus": "rectangle.badge.minus"
    case "arrow-forward-circle-outline": "arrow.forward.circle"
    case "bookmark": "bookmark.fill"
    case "bookmark-outline": "bookmark"
    case "arrow-down": "arrow.down"
    case "arrow-up": "arrow.up"
    default: nil
    }
}

// MARK: - 课程简介：系统底部弹窗，半屏起、可拉到全屏，下拉关闭

struct DescriptionSheet: View {
    var spec: SheetSpec
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(spec.title).zFont(S.sheetSeriesTitle).foregroundStyle(C.labelPrimary)
                    if let c = spec.category { Text(c).zFont(S.body).foregroundStyle(C.labelSecondary).padding(.top, CP.Sheet.categoryTop) }
                    Text(spec.body).zFont(S.sheetBody).foregroundStyle(C.labelPrimary).padding(.top, CP.Sheet.bodyTop).textSelection(
                        .enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Tok.Space.pageMargin)
                .padding(.top, CP.Sheet.contentTop)
                .padding(.bottom, Tok.Space.pageMargin)
            }
            .navigationTitle("关于")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }.accessibilityLabel("关闭")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
