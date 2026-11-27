import Foundation

struct AppNotice: Equatable {
    struct Link: Equatable {
        let label: String
        let url: URL
    }

    static let path = "app-notice.json"
    static let sizeLimit = 4096

    let dismissalKey: String
    let message: String
    let link: Link?
}

func parseAppNotice(_ data: Data) -> AppNotice? {
    struct Configuration: Decodable {
        struct Link: Decodable {
            let label: String
            let url: String
        }

        let enabled: Bool
        let id: String?
        let message: String
        let link: Link?

        private enum CodingKeys: String, CodingKey { case enabled, id, message, link }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try fields.decode(Bool.self, forKey: .enabled)
            id = try? fields.decode(String.self, forKey: .id)
            message = try fields.decode(String.self, forKey: .message)
            link = try? fields.decode(Link.self, forKey: .link)
        }
    }

    guard data.count <= AppNotice.sizeLimit, let config = try? JSONDecoder().decode(Configuration.self, from: data),
        config.enabled
    else { return nil }
    let message = config.message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty, message.utf16.count <= 180 else { return nil }
    var link: AppNotice.Link?
    if let candidate = config.link {
        let label = candidate.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = candidate.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty, label.utf16.count <= 32, address.utf16.count <= 1000, !address.contains("\\"),
            address.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
            let url = URLComponents(string: address),
            url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
            let destination = url.url
        {
            link = AppNotice.Link(label: label, url: destination)
        }
    }
    let id = config.id?.wholeMatch(of: /[A-Za-z0-9_-]{1,64}/).map { String($0.output) }
    return AppNotice(dismissalKey: id.map { "id:" + $0 } ?? "message:" + message, message: message, link: link)
}
