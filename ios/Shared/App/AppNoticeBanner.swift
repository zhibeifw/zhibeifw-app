#if os(iOS) || os(macOS) || os(visionOS)
import SwiftUI

struct AppNoticeBanner: View {
    let notice: AppNotice
    let dismiss: () -> Void
    private typealias Banner = Tok.Component.Banner
    private typealias Notice = Tok.Component.AppNotice
    private typealias TextStyle = Tok.Font.Style
    #if !os(macOS)
    @ScaledMetric(relativeTo: .caption) private var actionSize = TextStyle.appNoticeAction.size
    #else
    private let actionSize = TextStyle.appNoticeAction.size
    #endif

    private var noticeForeground: some ShapeStyle {
        #if os(visionOS)
        HierarchicalShapeStyle.primary
        #else
        Tok.Color.appNoticeForeground.color
        #endif
    }

    private var closeGap: CGFloat {
        #if os(visionOS)
        Notice.actionGap
        #else
        Notice.inlineCloseGap
        #endif
    }

    var body: some View {
        HStack(alignment: .center, spacing: closeGap) {
            Group {
                if let link = notice.link {
                    if notice.message.rangeOfCharacter(from: .newlines) != nil ||
                        link.label.rangeOfCharacter(from: .newlines) != nil
                    {
                        paragraph(link)
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 0) {
                                message.fixedSize(horizontal: true, vertical: false)
                                Spacer(minLength: Notice.actionGap)
                                action(link)
                            }
                            paragraph(link)
                        }
                    }
                } else {
                    message.fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, Notice.paddingV)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: Notice.closeIconSize, weight: TextStyle.appNoticeAction.fontWeight))
                    #if os(visionOS)
                    .visionHitTarget()
                    #else
                    .frame(minWidth: Notice.controlSize, minHeight: Notice.controlSize)
                    .contentShape(Rectangle())
                    #endif
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭公告")
        }
        .padding(.leading, Banner.paddingH)
        .padding(.vertical, Notice.compactPaddingV)
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
        Text(notice.message).zFont(TextStyle.appNoticeText)
    }

    private func action(_ link: AppNotice.Link) -> some View {
        Link(destination: link.url) {
            Text(link.label)
                .zFont(TextStyle.appNoticeAction)
                .foregroundStyle(Tok.Color.appNoticeLink.color)
                .fixedSize()
                .padding(.horizontal, Notice.actionGap)
                #if os(visionOS)
                .visionHitTarget()
                #else
                .frame(minWidth: Notice.controlSize, minHeight: Notice.controlSize)
                .contentShape(Rectangle())
                #endif
        }
        .buttonStyle(.plain)
    }

    private func paragraph(_ link: AppNotice.Link) -> some View {
        let title = link.label.count <= 8 ? link.label.replacingOccurrences(
            of: "(?<=[一-龯])(?=[一-龯])", with: "\u{2060}", options: .regularExpression
        ) : link.label
        var label = AttributedString(title)
        label.foregroundColor = Tok.Color.appNoticeLink.color
        label.font = .system(size: actionSize.rounded(.toNearestOrEven), weight: TextStyle.appNoticeAction.fontWeight)
        #if !os(visionOS)
        label.link = link.url
        #endif
        var content = AttributedString(notice.message + " ")
        content.append(label)
        let text = Text(content)
            .zFont(TextStyle.appNoticeText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, Notice.paddingV)
            .padding(.trailing, Notice.actionGap - closeGap)
        #if os(visionOS)
        return Link(destination: link.url) {
            text.frame(maxWidth: .infinity, alignment: .leading).visionHitTarget()
        }
        .buttonStyle(.plain)
        #else
        return text.tint(Tok.Color.appNoticeLink.color)
        #endif
    }
}
#endif
