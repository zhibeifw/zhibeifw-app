import Foundation

enum SiriEpisodeName {
    static func matches(_ title: String, spoken: String) -> Bool {
        let title = normalizeText(title).filter { !$0.isWhitespace }
        let spoken = normalizeText(spoken).filter { !$0.isWhitespace }
        if title == spoken { return !title.isEmpty }
        guard let first = number(title), let second = number(spoken) else { return false }
        return first == second
    }

    private static func number(_ text: String) -> Int? {
        guard text.range(of: "^第?[0-9一二三四五六七八九十百千万零〇两]+[集课讲]?$", options: .regularExpression) != nil else { return nil }
        var value = text
        if value.first == "第" { value.removeFirst() }
        if let last = value.last, "集课讲".contains(last) { value.removeLast() }
        if let number = Int(value) { return number }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .spellOut
        return formatter.number(from: value)?.intValue
    }
}

extension Store {
    /// 只匹配完整的课程与集数名称，不把课程列表位置当作集数。
    func siriEpisodes(matching name: String) throws -> [SiriEpisode] {
        let query = normalizeText(name).filter { !$0.isWhitespace }
        guard !query.isEmpty else { return [] }
        return try db.all("""
            SELECT e.id, e.series_id, e.title, s.title AS series_title
            FROM catalog_episode e JOIN catalog_series s ON s.id = e.series_id
            ORDER BY s.id, e.pos
            """).compactMap { row in
                let course = row.str("series_title"), episode = row.str("title")
                let prefix = normalizeText(course).filter { !$0.isWhitespace }
                guard query.hasPrefix(prefix),
                      SiriEpisodeName.matches(episode, spoken: String(query.dropFirst(prefix.count))) else { return nil }
                return SiriEpisode(id: row.str("id"), seriesID: row.str("series_id"), title: episode, courseTitle: course)
            }
    }
}
