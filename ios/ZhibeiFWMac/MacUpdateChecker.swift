import AppKit
import Observation

/// Mac 的检查更新（照 Android 官网版）。读 upgrade.json 的 "mac" 段：
/// - 官网版（Developer ID 签名、从官网下载）：有新版本弹“发现新版本”，“立刻更新”用浏览器下载 dmg，“稍后提醒”同一版本 7 天内不再自动弹；
///   低于最低版本时主页顶部显示“此版本过旧”；关于窗口有“检查更新”。
/// - Mac App Store 版：按 Apple 的规定不自己提示更新、不下载，只在低于最低版本时显示“此版本过旧，请到 App Store 更新”（和 iPhone 一样）。
/// 每 24 小时自动查一次（启动、回到前台时），网络失败沿用上次的结论。
@MainActor
@Observable
final class MacUpdateChecker {
    /// 低于最低版本：主页顶部的提示条（本次运行内关闭后不再显示）
    private(set) var outdated = false
    var outdatedDismissed = false
    /// 有新版本时弹的对话框
    var dialog: (version: String, dmgPath: String)?
    /// Mac App Store 装的包里有 App Store 收据；官网版没有
    let channel: UpdateChannel =
        Bundle.main.appStoreReceiptURL.map { FileManager.default.fileExists(atPath: $0.path) } == true ? .store : .site

    private static let kRemindVersion = "update.mac.remindVersion"
    private static let kRemindAt = "update.mac.remindAt"

    /// 返回手动检查时显示在关于窗口里的结果文字；自动检查返回 nil。
    @discardableResult
    func check(manual: Bool) async -> String? {
        let now = Date().timeIntervalSince1970 * 1000
        let last = Prefs.d.object(forKey: Prefs.kUpdateChecked) as? Double
        guard manual || shouldAutoCheck(lastCheckedAt: last, now: now) else {
            applySaved(manual: false)
            return nil
        }
        let r = await Network.shared.request(
            UPGRADE_PATH, etag: Prefs.d.string(forKey: Prefs.kUpdateEtag), maxBytes: FileKind.upgrade.limit)
        let result: String?
        switch r {
        case .ok(let data, let etag):
            guard let u = parseUpgrade(data) else {
                applySaved(manual: false)
                return manual ? "检查失败" : nil
            }
            Prefs.d.set(String(data: data, encoding: .utf8), forKey: Prefs.kUpdateBody)
            Prefs.d.set(etag, forKey: Prefs.kUpdateEtag)
            Prefs.d.set(now, forKey: Prefs.kUpdateChecked)
            result = apply(u, manual: manual)
        case .notModified:
            Prefs.d.set(now, forKey: Prefs.kUpdateChecked)
            result = applySaved(manual: manual) ?? "已是最新版本"
        default:
            applySaved(manual: false)  // 网络失败：沿用上次的结论（“此版本过旧”提示条不因离线而消失）
            result = "检查失败"
        }
        return manual ? result : nil
    }

    @discardableResult
    private func applySaved(manual: Bool) -> String? {
        guard let body = Prefs.d.string(forKey: Prefs.kUpdateBody), let u = parseUpgrade(body) else { return nil }
        return apply(u, manual: manual)
    }

    private func apply(_ file: UpgradeFile, manual: Bool) -> String {
        // 没有 "mac" 段（还没发过 Mac 官网版）：当作已是最新
        guard let u = macUpgradeFile(file) else { outdated = false; return "已是最新版本" }
        switch decideUpdate(current: AppInfo.version, u, channel: channel) {
        case .outdated:
            outdated = true
            return channel == .site ? "版本过旧，请到官网更新" : "版本过旧，请到 App Store 更新"
        case .optional(let version, let dmgPath):
            outdated = false
            let remind = (Prefs.d.string(forKey: Self.kRemindVersion)).map {
                RemindLater(version: $0, at: Prefs.d.double(forKey: Self.kRemindAt))
            }
            if manual || !suppressedByRemindLater(remind, version: version, now: Date().timeIntervalSince1970 * 1000) {
                dialog = (version, dmgPath)
            }
            return "有新版本 \(version)"
        case .none:
            outdated = false
            return "已是最新版本"
        }
    }

    /// 稍后提醒：同一版本 7 天内不再自动弹。
    func remindLater(_ version: String) {
        dialog = nil
        Prefs.d.set(version, forKey: Self.kRemindVersion)
        Prefs.d.set(Date().timeIntervalSince1970 * 1000, forKey: Self.kRemindAt)
    }

    /// 立刻更新：用浏览器打开 dmg 的直链（当前线路；正在刷新线路时用最近一次选出的），用户打开 dmg 拖进“应用程序”替换旧版。
    func openDownload(_ dmgPath: String) {
        dialog = nil
        guard let origin = Network.shared.currentOrigin ?? Prefs.d.string(forKey: Prefs.kLastService),
            let url = buildUrl(origin, dmgPath)
        else { return }
        NSWorkspace.shared.open(url)
    }
}
