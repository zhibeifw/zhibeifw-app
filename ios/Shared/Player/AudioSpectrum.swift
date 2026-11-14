#if !os(watchOS)
import Accelerate
import AVFoundation

/// 连续采样按固定窗口分成四个频段；窗口内各频段使用相同时间，不添加显示延迟。
final class AudioSpectrum {
    private let size = 1024
    private let setup = vDSP_DFT_zop_CreateSetup(nil, 1024, .FORWARD)
    private var input = [Float](repeating: 0, count: 1024)
    private let imaginary = [Float](repeating: 0, count: 1024)
    private var realOut = [Float](repeating: 0, count: 1024)
    private var imaginaryOut = [Float](repeating: 0, count: 1024)
    private var used = 0
    private var start = 0.0
    private var expectedTime: Double?
    private var sampleRate = 0.0

    deinit { if let setup { vDSP_DFT_DestroySetup(setup) } }

    func capture(_ buffers: UnsafeMutablePointer<AudioBufferList>, format: AudioStreamBasicDescription,
                 time: Double) -> [(Double, [Double])] {
        guard let setup, format.mSampleRate > 0 else { return [] }
        let audio = UnsafeMutableAudioBufferListPointer(buffers)
        let floating = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        guard floating || format.mBitsPerChannel == 16 else { return [] }
        let bytes = floating ? 4 : 2
        guard let first = audio.first, first.mNumberChannels > 0 else { return [] }
        let frames = Int(first.mDataByteSize) / bytes / Int(first.mNumberChannels)
        if sampleRate != format.mSampleRate || expectedTime.map({ abs(time - $0) > 0.01 }) == true {
            used = 0
        }
        sampleRate = format.mSampleRate
        expectedTime = time + Double(frames) / sampleRate
        var results: [(Double, [Double])] = []
        for frame in 0..<frames {
            var mono: Float = 0
            var channels = 0
            for buffer in audio {
                guard let data = buffer.mData else { continue }
                let channelCount = Int(buffer.mNumberChannels)
                for channel in 0..<channelCount {
                    let index = frame * channelCount + channel
                    guard (index + 1) * bytes <= Int(buffer.mDataByteSize) else { continue }
                    let value = floating ? data.assumingMemoryBound(to: Float.self)[index]
                        : Float(data.assumingMemoryBound(to: Int16.self)[index]) / 32768
                    mono += value.isFinite ? value : 0
                    channels += 1
                }
            }
            if used == 0 { start = time + Double(frame) / sampleRate }
            input[used] = channels > 0 ? mono / Float(channels) : 0
            used += 1
            if used == size {
                vDSP_DFT_Execute(setup, input, imaginary, &realOut, &imaginaryOut)
                var energy = [Double](repeating: 0, count: 4)
                for bin in 1..<(size / 2) {
                    let frequency = Double(bin) * sampleRate / Double(size)
                    let band = frequency < 250 ? 0 : frequency < 1000 ? 1 : frequency < 4000 ? 2 : 3
                    let r = Double(realOut[bin]), i = Double(imaginaryOut[bin])
                    energy[band] += r * r + i * i
                }
                // 幅度按窗口长度归一化，不做自动增益或各频段独立放大。
                let levels = energy.map { min(1, 2 * sqrt($0) / Double(size)) }
                results.append((start, levels))
                used = 0
            }
        }
        return results
    }
}
#endif
