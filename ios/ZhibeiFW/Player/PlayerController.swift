import AVFoundation
import MediaPlayer
import UIKit
import Observation

// 播放控制器。播放状态以系统播放器为准：
//  · 在不在出声：AVPlayer.timeControlStatus（KVO）；想不想播：AVPlayer.rate（KVO，喊了 play 就是 1，缓冲中也是 1）；
//  · 锁屏、控制中心、耳机、拔耳机、来电在 App 外的暂停/播放，都改的是同一个 AVPlayer，KVO 即时反映到界面；
//  · 播完接下一集靠 AVPlayerItemDidPlayToEndTime 通知；锁屏信息在换集的同一时刻更新；
//  · 睡眠定时、定时存进度挂在 AVPlayer 的周期时间观察者上（播放中在后台也照常回调），不靠界面计时器。
// 只有一处界面层状态：点了播放、还在找地址（第一次选线路）的那一小段时间（pendingStart），图标先变暂停。

enum PlayerError: Equatable { case cannotPlay, damaged, gone }

struct NowPlaying: Equatable {
    var info: EpisodeInfo
    var ctx: PlayContext
    var episodeId: String { info.episodeId }
    var seriesId: String { info.seriesId }
}

let SAVE_INTERVAL_SEC: Double = 5
let STALL_LIMIT_SEC: Double = 30
let PROBE_AFTER_SEC: Double = 5
/// 后退 15 秒、前进 30 秒。
let SEEK_BACK_SECONDS: Double = Double(Tok.Player.seekBackSeconds)
let SEEK_FORWARD_SECONDS: Double = Double(Tok.Player.seekForwardSeconds)

@MainActor
@Observable
final class PlayerController {
    private(set) var current: NowPlaying?
    private(set) var isPlaying = false  // 真的在出声
    private(set) var systemWantsPlay = false  // AVPlayer.rate > 0
    private(set) var pendingStart = false
    private(set) var buffering = false
    private(set) var streaming = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var rate: Double = 1
    private(set) var sleep: SleepSetting = .off
    private(set) var sleepLeft: Double?
    var error: PlayerError?

    /// 界面上显示“暂停”图标：在出声，或用户刚点了播放、还在加载。
    var looksPlaying: Bool { isPlaying || systemWantsPlay || pendingStart }

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private let store: Store
    @ObservationIgnored private let files: AppFiles
    @ObservationIgnored var onProgressSaved: (() -> Void)?
    @ObservationIgnored var onDamaged: ((String) -> Void)?
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var lastSavedAt: Double = -.infinity
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var positionKnown = false
    @ObservationIgnored private var markedDone = false
    /// 用户想听：点了播放 / 继续以后为真，自己点暂停（含睡眠定时、拔耳机、锁屏暂停）后为假；打断结束时据此决定接不接着播
    @ObservationIgnored private var wantsPlay = false
    @ObservationIgnored private var needsReload = false
    @ObservationIgnored private var stallTask: Task<Void, Never>?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSeek: (to: Double, until: Date)?
    @ObservationIgnored private var durationRecorded = false
    @ObservationIgnored private var artwork: MPMediaItemArtwork?

    init(store: Store, files: AppFiles) {
        self.store = store
        self.files = files
        player.automaticallyWaitsToMinimizeStalling = true
        configureSession()
        observePlayer()
        setupRemoteCommands()
    }

    // MARK: 系统回调

    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            // 拔耳机自动暂停（oldDeviceUnavailable）。系统本身也会暂停，这里确保并存下位置。
            guard
                let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(
                    AVAudioSession.RouteChangeReason.init(rawValue:)),
                reason == .oldDeviceUnavailable
            else { return }
            MainActor.assumeIsolated { self?.pause() }
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            // 来电、导航播报等打断：按系统默认，开始时系统暂停（状态由 KVO 反映，这里存下位置）；
            // 结束时系统建议接着播、而打断前用户想听（没自己点暂停），就接着播（Android 同）
            guard
                let t = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            else { return }
            let opts = AVAudioSession.InterruptionOptions(rawValue: n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated {
                guard let self else { return }
                if t == .began { self.saveNow(); return }
                if opts.contains(.shouldResume) { self.resumeAfterInterruption() }
            }
        }
        nc.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, (n.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.onFinished()
            }
        }
        nc.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, (n.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.armStall()
            }
        }
    }

    private func observePlayer() {
        observers.append(
            player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
                let st = p.timeControlStatus
                Task { @MainActor in self?.onTimeControl(st) }
            })
        observers.append(
            player.observe(\.rate, options: [.initial, .new]) { [weak self] p, _ in
                let r = p.rate
                Task { @MainActor in self?.onRate(r) }
            })
        observers.append(
            player.observe(\.currentItem?.status, options: [.new]) { [weak self] p, _ in
                let failed = p.currentItem?.status == .failed
                Task { @MainActor in if failed { self?.onItemFailed() } }
            })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) {
            [weak self] t in
            MainActor.assumeIsolated { self?.onTick(t.seconds) }
        }
    }

    private func onTimeControl(_ st: AVPlayer.TimeControlStatus) {
        guard current != nil else { isPlaying = false; return }
        let was = isPlaying
        isPlaying = st == .playing
        buffering = st == .waitingToPlayAtSpecifiedRate
        if st == .playing { clearStall(); error = nil }
        if st == .waitingToPlayAtSpecifiedRate { armStall() }
        if st == .paused { clearStall() }
        if was && !isPlaying && st == .paused && positionKnown && !markedDone { saveNow() }  // 在 App 外暂停：记下停的位置
        updateNowPlayingRate()
    }

    private func onRate(_ r: Float) {
        systemWantsPlay = r > 0
        if r > 0 { pendingStart = false }
    }

    private func onItemFailed() {
        guard let c = current, positionKnown || pendingStart else { return }
        // 已下载的本地文件放不了：文件坏了（截断、0 字节等），按“下载文件已损坏”处理，改回未下载，免得一直重试一个坏文件
        if !streaming {
            onDamaged?(c.episodeId)
            fail(.damaged)
            return
        }
        // 在线音频加载失败（网络不通等）：统一提示“网络异常”。播放器里是一个失败的音频，再点要整个重新加载
        fail(.cannotPlay)
    }

    private func onTick(_ seconds: Double) {
        guard current != nil, !markedDone else { return }
        if case .timer = sleep, tickSleep() { return }
        guard positionKnown else { return }
        var pos = seconds.isFinite ? seconds : 0
        if let ps = pendingSeek {
            if Date() >= ps.until || abs(pos - ps.to) < 1.5 { pendingSeek = nil } else { pos = ps.to }
        }
        position = pos
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 {
            if duration == 0 || abs(duration - d) > 0.5 { duration = d }
            if !durationRecorded, let c = current { durationRecorded = true; try? store.recordDuration(c.episodeId, d) }
        }
        // 定时保存不通知各页面重读：正在播的这一集页面上用的是播放器的实时位置
        if isPlaying && abs(pos - lastSavedAt) >= SAVE_INTERVAL_SEC { save(pos, duration, notify: false) }
    }

    // MARK: 进度保存

    private func save(_ pos: Double, _ dur: Double, for np: NowPlaying? = nil, notify: Bool = true) {
        guard let c = np ?? current else { return }
        do {
            try store.recordPlayback(
                episodeId: c.episodeId, seriesId: c.seriesId, position: pos, duration: dur,
                seriesTitle: c.info.seriesTitle, episodeTitle: c.info.episodeTitle, coverPath: c.info.coverPath)
            lastSavedAt = pos
            if notify { onProgressSaved?() }
        } catch { NSLog("保存播放进度出错：\(error)") }  // 写库失败不影响播放，下一次再存
    }

    func saveNow() {
        guard current != nil, positionKnown, !markedDone else { return }
        save(position, duration)
    }

    // MARK: 卡住

    private func clearStall() { stallTask?.cancel(); stallTask = nil; probeTask?.cancel(); probeTask = nil }

    private func armStall() {
        guard stallTask == nil, systemWantsPlay || pendingStart, let c = current else { return }
        let gen = generation
        if streaming {
            let path = c.info.audioPath
            probeTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(PROBE_AFTER_SEC * 1e9))
                guard !Task.isCancelled else { return }
                let code = await Network.shared.headStatus(path)
                guard let self, !Task.isCancelled, gen == self.generation, self.stallTask != nil, code == 404 || code == 410 else { return }
                self.fail(.gone)
            }
        }
        stallTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(STALL_LIMIT_SEC * 1e9))
            guard !Task.isCancelled, let self, gen == self.generation else { return }
            self.fail(.cannotPlay)
        }
    }

    private func fail(_ e: PlayerError) {
        clearStall()
        player.pause()
        pendingStart = false
        needsReload = true
        isPlaying = false
        buffering = false
        error = e
    }

    // MARK: 播放

    /// 从集 ID 开始播放；目录里没有、又没有已下载完成的记录时返回 false。
    @discardableResult
    func start(_ episodeId: String, ctx: PlayContext) -> Bool {
        guard let info = try? store.getEpisodeInfo(episodeId) else { return false }
        play(info, ctx: ctx)
        return true
    }

    func play(_ info: EpisodeInfo, ctx: PlayContext) {
        dropExpiredSleep()
        wantsPlay = true
        generation += 1
        let gen = generation
        if let prev = current, positionKnown, !markedDone { save(position, duration, for: prev) }
        markedDone = false
        positionKnown = false
        durationRecorded = false
        clearStall()
        pendingSeek = nil
        player.pause()
        current = NowPlaying(info: info, ctx: ctx)
        position = 0; duration = 0; error = nil; buffering = true
        pendingStart = true
        artwork = nil
        updateNowPlayingInfo()

        // 优先用已下载的本地文件（离线可播）
        let local = files.localAudio(for: info.episodeId, store: store)
        if case .missing = local {
            onDamaged?(info.episodeId)
            fail(.damaged)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            var url: URL?
            var isLocal = false
            if case .file(let u) = local {
                url = u; isLocal = true
            } else if let origin = await Network.shared.ensureRoutes() {
                url = buildUrl(origin, info.audioPath)
            }
            guard gen == self.generation else { return }
            guard let url else { self.fail(.cannotPlay); return }
            let prog = self.store.loadProgress(info.episodeId)
            var startAt = (prog.map { $0.completed ? 0 : $0.position }) ?? 0
            let known = prog?.duration ?? 0
            self.needsReload = false
            self.streaming = !isLocal
            self.position = startAt
            self.duration = known
            self.positionKnown = true
            let item = AVPlayerItem(url: url)
            item.audioTimePitchAlgorithm = .timeDomain
            self.player.replaceCurrentItem(with: item)
            if startAt > 1 {
                var ok = await self.player.seek(
                    to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                guard gen == self.generation else { return }
                // 精确定位没成功（弱网、还没缓冲好）：再按默认容差试一次，差一两秒没关系，别把记住的进度丢掉
                if !ok {
                    ok = await self.player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600))
                    guard gen == self.generation else { return }
                }
                if !ok { startAt = 0; self.position = 0 }  // 两次都失败：从头播，不算无法播放
            }
            if self.pendingStart { self.player.playImmediately(atRate: Float(self.rate)) }  // 加载期间用户点了暂停：加载好但不出声
            self.save(startAt, known)  // 一播放即记入“最近”
            self.updateNowPlayingInfo()
            self.loadArtwork(info)
        }
    }

    func toggle() {
        guard current != nil else { return }
        if needsReload { retry(); return }
        if looksPlaying { pause() } else { resume() }
    }

    func resume() {
        guard let c = current else { return }
        dropExpiredSleep()
        wantsPlay = true
        if needsReload || player.currentItem == nil { play(c.info, ctx: c.ctx); return }
        if positionKnown { player.playImmediately(atRate: Float(rate)) } else { pendingStart = true }
    }

    func pause() {
        guard current != nil else { return }
        wantsPlay = false
        pendingStart = false
        clearStall()
        player.pause()
        if positionKnown && !markedDone { save(position, duration) }
    }

    /// 打断结束、系统建议接着播：播完、出错、标记已听完后不算（那些情况要用户自己再点）
    private func resumeAfterInterruption() {
        guard wantsPlay, current != nil, !needsReload, !markedDone else { return }
        if positionKnown { player.playImmediately(atRate: Float(rate)) } else { pendingStart = true }
    }

    func retry() {
        guard let c = current else { return }
        error = nil
        play(c.info, ctx: c.ctx)
    }

    func seek(by delta: Double) {
        guard current != nil, positionKnown, !markedDone else { return }
        let to = max(0, duration > 0 ? min(duration, position + delta) : position + delta)
        seek(to: to)
    }

    func seek(to sec: Double) {
        guard current != nil, positionKnown, !markedDone else { return }
        position = sec
        pendingSeek = (sec, Date().addingTimeInterval(1))
        player.seek(to: CMTime(seconds: sec, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlayingRate() }
        }
    }

    func setRate(_ r: Double) {
        rate = r
        if player.rate > 0 { player.rate = Float(r) }
        updateNowPlayingRate()
    }

    func setSleep(_ s: SleepSetting) {
        sleep = s
        sleepLeft = s.secondsLeft(now: sleepClock())
    }

    /// 已经过了点的睡眠定时（暂停着的时候到点：时间回调只在播放中走）：清掉，免得一开始播放就被它停下。
    private func dropExpiredSleep() {
        if case .timer = sleep, (sleep.secondsLeft(now: sleepClock()) ?? 0) <= 0 {
            sleep = .off
            sleepLeft = nil
        }
    }

    /// 返回 true 表示到点暂停了。
    @discardableResult
    private func tickSleep() -> Bool {
        guard case .timer = sleep else { return false }
        let left = sleep.secondsLeft(now: sleepClock()) ?? 0
        if left <= 0 {
            pause()
            sleep = .off
            sleepLeft = nil
            return true
        }
        if left != sleepLeft { sleepLeft = left }
        return false
    }

    /// 界面倒计时：前台每秒刷新一次显示（只是显示；到点暂停由播放器时间回调保证）。
    func refreshSleepDisplay() { _ = tickSleep() }

    /// 用户把正在播放的这一集标为已听完：停止，之后不把旧位置写回；再点播放从头重新加载。
    @discardableResult
    func stopAsCompleted(_ episodeId: String) -> Bool {
        guard current?.episodeId == episodeId else { return false }
        generation += 1
        markedDone = true
        positionKnown = false
        pendingStart = false
        clearStall()
        player.pause()
        needsReload = true
        position = 0
        error = nil
        return true
    }

    /// 正在播放的这一集的下载被删除：停掉并清空。
    func stopIfCurrent(_ episodeId: String) {
        guard current?.episodeId == episodeId else { return }
        generation += 1
        positionKnown = false
        markedDone = false
        pendingStart = false
        clearStall()
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        position = 0; duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func onFinished() {
        guard let c = current else { return }
        let dur = duration > 0 ? duration : position
        save(dur, dur)  // 播完：算听完
        if sleep == .end {  // 睡眠定时“单集结束时”优先于接下一集
            sleep = .off; sleepLeft = nil
            player.pause()
            needsReload = true
            return
        }
        var next: String?
        switch c.ctx {
        case .series(let sid): next = pickNext((try? store.seriesEpisodeIds(sid)) ?? [], current: c.episodeId)
        case .library(let sid): next = pickNext((try? store.doneEpisodeIds(sid)) ?? [], current: c.episodeId)
        case .single: next = nil
        }
        if let n = next, let info = try? store.getEpisodeInfo(n) {
            play(info, ctx: c.ctx)  // 自动接下一集：锁屏信息在 play() 里同时更新
        } else {
            needsReload = true
            position = 0
        }
    }

    // MARK: 锁屏与控制中心

    private func setupRemoteCommands() {
        // 系统没有承诺这些回调一定在主线程上：交给主线程去做，不用 assumeIsolated（不在主线程时会让进程中止）
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }; return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }; return .success
        }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }; return .success
        }
        cc.skipForwardCommand.preferredIntervals = [NSNumber(value: SEEK_FORWARD_SECONDS)]
        cc.skipBackwardCommand.preferredIntervals = [NSNumber(value: SEEK_BACK_SECONDS)]
        cc.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.seek(by: SEEK_FORWARD_SECONDS) }; return .success
        }
        cc.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.seek(by: -SEEK_BACK_SECONDS) }; return .success
        }
        cc.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in self?.seek(to: t) }
            return .success
        }
        // 不放“上一集 / 下一集”
        cc.nextTrackCommand.isEnabled = false
        cc.previousTrackCommand.isEnabled = false
    }

    private func updateNowPlayingInfo() {
        guard let c = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: c.info.episodeTitle,
            MPMediaItemPropertyArtist: c.info.seriesTitle,
            MPMediaItemPropertyAlbumTitle: c.info.seriesTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let a = artwork { info[MPMediaItemPropertyArtwork] = a }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingRate() {
        guard current != nil, var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? rate : 0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = rate
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// 锁屏封面：本机有这门课的封面（下载时存的）优先，离线也有；否则走封面缓存/网络。
    private func loadArtwork(_ info: EpisodeInfo) {
        let gen = generation
        let local = files.coverFile(seriesId: info.seriesId)
        guard !info.coverPath.isEmpty || FileManager.default.fileExists(atPath: local.path) else { return }
        Task { [weak self] in
            let img = await ImageLoader.shared.load(
                info.coverPath.isEmpty ? "local:\(info.seriesId)" : info.coverPath, maxPixel: 600,
                localFile: FileManager.default.fileExists(atPath: local.path) ? local : nil)
            guard let self, let img, gen == self.generation else { return }
            self.artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            self.updateNowPlayingInfo()
        }
    }
}
