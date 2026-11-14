import Foundation
import Observation

/// Apple 商店渠道只看 minVersion：低于它在主页提示，更新走 App Store。
@MainActor
@Observable
final class UpgradeChecker {
    /// “此版本过旧”提示条（本次运行内关闭后不再显示）。
    private(set) var outdated = false
    var outdatedDismissed = false
    var showsNotice: Bool { outdated && !outdatedDismissed }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let now: () -> Double
    @ObservationIgnored private let request: (String?) async -> NetResult

    init(
        defaults: UserDefaults = Prefs.d,
        currentVersion: String = AppInfo.version,
        now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 },
        request: @escaping (String?) async -> NetResult = { etag in
            await Network.shared.request(UPGRADE_PATH, etag: etag, maxBytes: FileKind.upgrade.limit)
        }
    ) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.now = now
        self.request = request
    }

    func check(manual: Bool) async {
        let now = now()
        let last = defaults.object(forKey: Prefs.kUpdateChecked) as? Double
        guard manual || shouldAutoCheck(lastCheckedAt: last, now: now) else {
            applySaved()
            return
        }
        let r = await request(defaults.string(forKey: Prefs.kUpdateEtag))
        switch r {
        case .ok(let data, let etag):
            guard let u = parseUpgrade(data) else { applySaved(); return }
            defaults.set(String(data: data, encoding: .utf8), forKey: Prefs.kUpdateBody)
            defaults.set(etag, forKey: Prefs.kUpdateEtag)
            defaults.set(now, forKey: Prefs.kUpdateChecked)
            apply(u)
        case .notModified:
            defaults.set(now, forKey: Prefs.kUpdateChecked)
            applySaved()
        default: applySaved()  // 网络失败：沿用上次的结论（“此版本过旧”提示条不因离线而消失）
        }
    }

    private func applySaved() {
        if let body = defaults.string(forKey: Prefs.kUpdateBody), let u = parseUpgrade(body) { apply(u) }
    }

    private func apply(_ u: UpgradeFile) {
        if case .outdated = decideUpdate(current: currentVersion, u, channel: .store) { outdated = true } else { outdated = false }
    }
}
