import Foundation
import Observation

/// 检查更新（iOS 只看 minVersion：低于它在主页显示“此版本过旧”，更新走 App Store）。
@MainActor
@Observable
final class UpgradeChecker {
    /// “此版本过旧”提示条（本次运行内关闭后不再显示）。
    private(set) var outdated = false
    var outdatedDismissed = false

    func check(manual: Bool) async {
        let now = Date().timeIntervalSince1970 * 1000
        let last = Prefs.d.object(forKey: Prefs.kUpdateChecked) as? Double
        guard manual || shouldAutoCheck(lastCheckedAt: last, now: now) else {
            applySaved()
            return
        }
        let r = await Network.shared.request(
            UPGRADE_PATH, etag: Prefs.d.string(forKey: Prefs.kUpdateEtag), maxBytes: FileKind.upgrade.limit)
        switch r {
        case .ok(let data, let etag):
            guard let u = parseUpgrade(data) else { return }
            Prefs.d.set(String(data: data, encoding: .utf8), forKey: Prefs.kUpdateBody)
            Prefs.d.set(etag, forKey: Prefs.kUpdateEtag)
            Prefs.d.set(now, forKey: Prefs.kUpdateChecked)
            apply(u)
        case .notModified:
            Prefs.d.set(now, forKey: Prefs.kUpdateChecked)
            applySaved()
        default: break
        }
    }

    private func applySaved() {
        if let body = Prefs.d.string(forKey: Prefs.kUpdateBody), let u = parseUpgrade(body) { apply(u) }
    }

    private func apply(_ u: UpgradeFile) {
        if case .outdated = decideUpdate(current: AppInfo.version, u, channel: .store) { outdated = true } else { outdated = false }
    }
}
