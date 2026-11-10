import Foundation

// 最基础的几条外部数据校验（课程 / 集 ID、标题、相对路径、线路地址、JSON 数字）和拼地址。
// App（iPhone、iPad、Apple TV、Mac）和小组件都编译这个文件：小组件自己读 index.json 时用同样的规则。
// 规则与 v1.0 validate.ts、Android Validate.kt 逐条一致。

enum Limits {
    static let maxIdLength = 100
    static let maxTitleLength = 200
    static let maxDescriptionLength = 5000
    static let maxPathLength = 300
    static let maxDomainItems = 10
    static let maxEpisodeDuration = 24 * 3600
    static let maxUpdatedAt: Double = 1e11
    static let maxFeatured = 50
}

/// UTF-8 字节数。
func utf8ByteLength(_ s: String) -> Int { s.utf8.count }

// MARK: - 基本类型

/// 课程 ID、集 ID：文字（\p{L}）、十进制数字（\p{Nd}）、下划线、连字符，NFC 标准写法，1–100 个字符（按 UTF-16 码元计，与 v1.0 一致）。
func isValidId(_ v: Any?) -> Bool {
    guard let s = v as? String else { return false }
    let n = s.utf16.count
    guard n >= 1, n <= Limits.maxIdLength else { return false }
    // 按码位比：String 的 == 是规范等价比较，NFD 和 NFC 永远“相等”，起不到检查作用
    guard s.unicodeScalars.elementsEqual(s.precomposedStringWithCanonicalMapping.unicodeScalars) else { return false }
    for u in s.unicodeScalars {
        if u == "_" || u == "-" { continue }
        let p = u.properties.generalCategory
        switch p {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: continue
        default: return false
        }
    }
    return true
}

/// 相对路径：不带协议和域名、不以“/”开头、不含“..”；另外不允许反斜杠、控制字符、空白、?、#。
func isValidRelativePath(_ v: Any?) -> Bool {
    guard let s = v as? String else { return false }
    let n = s.utf16.count
    if n == 0 || n > Limits.maxPathLength { return false }
    // 和 Android 一样按 UTF-16 码元逐字匹配：Swift 的 hasPrefix、contains 按字符（字素簇）比，
    // “/”后面跟组合符号时会认不出开头的“/”
    let ns = s as NSString
    func has(_ p: String) -> Bool { ns.range(of: p, options: .literal).location != NSNotFound }
    if s.utf16.first == 0x2F || has("..") || has("\\") { return false }
    if s.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil || has("//") { return false }
    for u in s.utf16 where u <= 0x20 || u == 0x7F || u == 0x3F /* ? */ || u == 0x23 /* # */ { return false }
    return true
}

func isTitle(_ v: Any?) -> String? {
    guard let s = v as? String else { return nil }
    let n = s.utf16.count
    guard n >= 1, n <= Limits.maxTitleLength, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return s
}

private let originRegex = try! NSRegularExpression(
    pattern:
        "^https://(\\[[0-9A-Fa-f:.]{2,45}\\]|[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*)(?::[0-9]{1,5})?\\z"
)

/// https://域名[:端口]，不带路径、不带结尾斜杠、不带账号密码。IPv6 须带方括号。
func isHttpsOrigin(_ v: Any?) -> Bool {
    guard let s = v as? String, s.utf16.count <= 253 else { return false }
    return originRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

/// JSONSerialization 把 true/false 也读成 NSNumber，这里区分出真正的数字。
func jsonNumber(_ v: Any?) -> Double? {
    guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    return n.doubleValue
}

/// encodeURI 的等价物：保留 URL 里的保留字符和不需要编码的字符，其余（中文等）按 UTF-8 百分号编码。
func buildUrl(_ origin: String, _ path: String) -> URL? {
    var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    allowed.insert(charactersIn: ";,/?:@&=+$-_.!~*'()#")
    guard let enc = path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
    return URL(string: origin + "/" + enc)
}
