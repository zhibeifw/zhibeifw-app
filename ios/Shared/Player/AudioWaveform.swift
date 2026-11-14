#if !os(watchOS)
import AVFoundation
import MediaToolbox
import SwiftUI

/// 从播放数据提取四频段强度；按媒体时间读取，避免解码预缓冲让动画提前。
final class AudioWaveform: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(Double, [Double])] = []
    private let spectrum = AudioSpectrum()
    private var format = AudioStreamBasicDescription()

    @MainActor
    func attach(to item: AVPlayerItem) async {
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first,
            !Task.isCancelled else { return }
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(self).toOpaque(),
            init: { _, info, storage in
                storage.pointee = info
                if let info { _ = Unmanaged<AudioWaveform>.fromOpaque(info).retain() }
            },
            finalize: { tap in
                Unmanaged<AudioWaveform>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                Unmanaged<AudioWaveform>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue().format = format.pointee
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                var range = CMTimeRange.zero
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, &range, framesOut) == noErr else { return }
                let meter = Unmanaged<AudioWaveform>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                meter.capture(buffers, time: range.start.seconds)
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
            let tap else { return }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
    }

    private func capture(_ buffers: UnsafeMutablePointer<AudioBufferList>, time: Double) {
        guard time.isFinite else { return }
        let captured = spectrum.capture(buffers, format: format, time: time)
        lock.lock()
        if let last = samples.last, time < last.0 || time - last.0 > 0.3 {
            samples.removeAll(keepingCapacity: true)
        }
        samples.append(contentsOf: captured)
        if samples.count > 1000 { samples.removeFirst(samples.count - 1000) }
        lock.unlock()
    }

    func levels(at time: Double) -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return samples.last(where: { $0.0 <= time && time - $0.0 < 0.3 })?.1 ?? Array(repeating: 0, count: 4)
    }
}

struct AudioWaveformIcon: View {
    let player: PlayerController
    private func displayLevel(_ level: Double) -> Double {
        let scaled = min(1, max(0, level * Tok.Component.AudioWaveform.spectrumGain))
        return pow(scaled, Tok.Component.AudioWaveform.spectrumExponent)
    }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !player.isPlaying)) { _ in
            let levels = player.audioWaveform.levels(at: player.player.currentTime().seconds)
            HStack(alignment: .center, spacing: Tok.Component.AudioWaveform.spacing) {
                ForEach(0..<4) { index in
                    Capsule().frame(width: Tok.Component.AudioWaveform.barWidth,
                        height: max(Tok.Component.AudioWaveform.barWidth,
                            Tok.Component.AudioWaveform.height
                                * displayLevel(levels[index])))
                }
            }
            .frame(width: Tok.Component.AudioWaveform.width, height: Tok.Component.AudioWaveform.height)
        }
        .accessibilityHidden(true)
    }
}

#endif
