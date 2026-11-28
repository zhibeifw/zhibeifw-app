import AppKit
import CoreServices
import Observation
import Security

/// Mac 的检查更新（照 Android 官网版）。读 upgrade.json 的 "mac" 段：
/// - 官网版（Developer ID 签名、从官网下载）：有新版本弹“发现新版本”，“立刻更新”在 App 内下载 DMG，“稍后提醒”同一版本 7 天内不再自动弹；
///   低于最低版本时主页顶部显示“此版本过旧”；关于窗口有“检查更新”。
/// - Mac App Store 版：按 Apple 的规定不自己提示更新、不下载，只在低于最低版本时显示“此版本过旧，请到 App Store 更新”（和 iPhone 一样）。
/// 每 24 小时自动查一次（启动、回到前台时），网络失败沿用上次的结论。
@MainActor
@Observable
final class MacUpdateChecker {
    enum Download {
        case transferring(Double?)
        case ready(URL)
        case failed
    }

    /// 低于最低版本：主页顶部的提示条（本次运行内关闭后不再显示）
    private(set) var outdated = false
    var outdatedDismissed = false
    /// 有新版本时弹的对话框
    var dialog: (version: String, dmgPath: String)?
    private(set) var download: Download?
    @ObservationIgnored private var downloadSession: URLSession?
    @ObservationIgnored private var downloadID: UUID?
    /// 只有 Developer ID 签名的包（“直接分发”导出的官网版）才算官网版；App Store 版、TestFlight、送审版、
    /// Xcode 直接运行的开发版都按商店版处理，不显示“检查更新”（看收据不可靠：送审版、开发版都可能没有收据）
    let channel: UpdateChannel = MacUpdateChecker.isDeveloperIDSigned() ? .site : .store

    /// 用系统的签名检查：签名证书链是 Apple 的，且最末一级是 Developer ID Application 证书（Apple 规定的证书扩展 1.2.840.113635.100.6.1.13）。
    private static func isDeveloperIDSigned() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var req: SecRequirement?
        let text = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" as CFString
        guard SecRequirementCreateWithString(text, [], &req) == errSecSuccess, let req else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }

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
            if download == nil,
                manual || !suppressedByRemindLater(remind, version: version, now: Date().timeIntervalSince1970 * 1000)
            {
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

    func startDownload(_ dmgPath: String) {
        dialog = nil
        guard channel == .site, download == nil else { return }
        guard let origin = Network.shared.currentOrigin ?? Prefs.d.string(forKey: Prefs.kLastService),
            let url = buildUrl(origin, dmgPath)
        else {
            download = .failed
            return
        }
        let id = UUID()
        downloadID = id
        download = .transferring(nil)
        let delegate = MacUpdateDownloadDelegate { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.downloadID == id, case .transferring(let previous)? = self.download,
                    previous != fraction
                else { return }
                self.download = .transferring(fraction)
            }
        } finished: { [weak self] installer in
            Task { @MainActor in
                guard let self, self.downloadID == id, case .transferring? = self.download else {
                    if let installer { try? FileManager.default.removeItem(at: installer.deletingLastPathComponent()) }
                    return
                }
                self.downloadSession = nil
                self.download = installer.map(Download.ready) ?? .failed
            }
        }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        downloadSession = session
        session.downloadTask(with: url).resume()
    }

    func closeDownload() {
        downloadID = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        download = nil
    }

    func openInstaller(_ file: URL) {
        if NSWorkspace.shared.open(file) { closeDownload() }
        else { download = .failed }
    }
}

private final class MacUpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let report: @Sendable (Double?) -> Void
    private let finished: @Sendable (URL?) -> Void

    init(report: @escaping @Sendable (Double?) -> Void, finished: @escaping @Sendable (URL?) -> Void) {
        self.report = report
        self.finished = finished
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        report(totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200,
            let source = downloadTask.originalRequest?.url
        else { finished(nil); return }

        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let installer = directory.appendingPathComponent(source.lastPathComponent)
        do {
            let quarantine: [String: Any] = [
                kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
                kLSQuarantineDataURLKey as String: source,
            ]
            try (location as NSURL).setResourceValue(quarantine, forKey: .quarantinePropertiesKey)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            try fm.moveItem(at: location, to: installer)
            finished(installer)
        } catch {
            try? fm.removeItem(at: directory)
            finished(nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if error != nil { finished(nil) }
        session.finishTasksAndInvalidate()
    }
}
