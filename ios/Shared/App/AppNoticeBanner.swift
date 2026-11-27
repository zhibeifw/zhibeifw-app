#if os(iOS) || os(macOS) || os(visionOS)
import SwiftUI

struct AppNoticeBanner: View {
    let notice: AppNotice
    let dismiss: () -> Void
    private typealias Banner = Tok.Component.Banner
    private typealias Notice = Tok.Component.AppNotice
    private typealias TextStyle = Tok.Font.Style

    private var noticeForeground: some ShapeStyle {
        #if os(visionOS)
        HierarchicalShapeStyle.primary
        #else
        Tok.Color.appNoticeForeground.color
        #endif
    }

    var body: some View {
        HStack(alignment: .center, spacing: Notice.actionGap) {
            Group {
                if let link = notice.link {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Notice.actionGap) {
                            message.fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 0)
                            action(link)
                        }
                        VStack(alignment: .leading, spacing: Notice.actionGap) {
                            message.fixedSize(horizontal: false, vertical: true)
                            action(link)
                        }
                    }
                } else {
                    message.fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: Notice.closeIconSize, weight: TextStyle.bannerAction.fontWeight))
                    #if os(visionOS)
                    .visionHitTarget()
                    #else
                    .frame(minWidth: Banner.height, minHeight: Banner.height)
                    .contentShape(Rectangle())
                    #endif
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭公告")
        }
        .padding(.horizontal, Banner.paddingH)
        .padding(.vertical, Notice.paddingV)
        .frame(minHeight: Banner.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(noticeForeground)
        #if os(visionOS)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Banner.radius))
        #else
        .background(Tok.Color.appNoticeBackground.color, in: RoundedRectangle(cornerRadius: Banner.radius))
        #endif
        .accessibilityElement(children: .contain)
    }

    private var message: some View {
        Text(notice.message).zFont(TextStyle.bannerText)
    }

    private func action(_ link: AppNotice.Link) -> some View {
        Link(destination: link.url) {
            HStack(spacing: Notice.actionGap) {
                Text(link.label)
                Image(systemName: "chevron.forward").accessibilityHidden(true)
            }
            .zFont(TextStyle.bannerAction)
            .foregroundStyle(noticeForeground)
            .fixedSize(horizontal: false, vertical: true)
            #if os(visionOS)
            .visionHitTarget()
            #else
            .frame(minHeight: Banner.height)
            #endif
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
