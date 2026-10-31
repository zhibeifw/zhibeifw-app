import SwiftUI

// 播放胶囊。主页 / 搜索两个标签用系统的标签栏（见 RootView），
// 胶囊本身的底由系统画：iOS 26 是标签栏上方附件位的液态玻璃，更早的系统是系统的模糊材质。

struct PlayerCapsule: View {
    var collapsed: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.player
        let cur = p?.current
        let h = collapsed ? Tok.Nav.collapsedHeight : Tok.Nav.capsuleHeight
        HStack(spacing: CP.Capsule.textGap) {
            Button {
                model.openPlayer()
            } label: {
                HStack(spacing: CP.Capsule.textGap) {
                    if let c = cur {
                        CoverImage(
                            path: c.info.coverPath, colorId: c.seriesId, radius: CP.Capsule.thumbRadius,
                            localFile: model.files.coverFile(seriesId: c.seriesId)
                        )
                        .aspectRatio(contentMode: .fill)
                        .frame(
                            width: min(CP.Capsule.thumb, h - 2 * CP.Capsule.thumbInset),
                            height: min(CP.Capsule.thumb, h - 2 * CP.Capsule.thumbInset))
                        Text("\(c.info.seriesTitle) \(c.info.episodeTitle)")
                            .zFont(S.buttonText, maxScale: Tok.Font.MaxScale.capsule).foregroundStyle(C.labelPrimary).lineLimit(1)
                    } else {
                        ZIcon(name: "musical-notes", size: CP.Capsule.emptyIcon, color: C.labelSecondary)
                            .frame(
                                width: min(CP.Capsule.thumb, h - 2 * CP.Capsule.thumbInset),
                                height: min(CP.Capsule.thumb, h - 2 * CP.Capsule.thumbInset)
                            )
                            .background(
                                RoundedRectangle(cornerRadius: CP.Capsule.thumbRadius, style: .continuous).fill(C.backgroundSecondary))
                        Text("未在播放").zFont(S.buttonText, maxScale: Tok.Font.MaxScale.capsule).foregroundStyle(C.labelSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(cur == nil)
            .accessibilityLabel(cur.map { "正在播放：\($0.info.seriesTitle) \($0.info.episodeTitle)，点按打开播放页" } ?? "未在播放")

            Button {
                p?.toggle()
            } label: {
                ZIcon(
                    name: (p?.looksPlaying ?? false) ? "pause" : "play", size: CP.Capsule.playIcon,
                    color: cur == nil ? C.iconDisabled : C.labelPrimary
                )
                .frame(width: CP.Capsule.iconTouch, height: CP.Capsule.iconTouch).contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(cur == nil)
            .accessibilityLabel((p?.looksPlaying ?? false) ? "暂停" : "播放")

            if !collapsed {
                Button {
                    p?.seek(by: SEEK_FORWARD_SECONDS)
                } label: {
                    SeekIcon(forward: true, size: CP.Capsule.forwardIcon, color: cur == nil ? C.iconDisabled : C.labelPrimary)
                        .frame(width: CP.Capsule.iconTouch, height: CP.Capsule.iconTouch).contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .disabled(cur == nil)
                .accessibilityLabel("前进 \(Int(SEEK_FORWARD_SECONDS)) 秒")
                .transition(.opacity)
            }
        }
        .padding(.leading, CP.Capsule.paddingH)
        .padding(.trailing, CP.Capsule.paddingH / 2)
        .frame(height: h)
        .contentShape(Capsule())
    }
}
