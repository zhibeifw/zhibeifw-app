package com.zhibeifw.app.player

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.ForwardingAudioSink
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs

/** 只读取解码后的样本，不改变交给系统播放的数据。 */
class AudioWaveform {
    private val samples = ArrayDeque<Pair<Long, List<Float>>>()
    private val spectrum = AudioSpectrum()
    private var lastCapture: Long? = null
    private var expectedTime: Long? = null
    private var rate = 0
    private var channels = 0

    @Synchronized fun clear() {
        samples.clear()
        spectrum.reset()
        lastCapture = null
        expectedTime = null
    }

    @Synchronized fun capture(buffer: ByteBuffer, encoding: Int, timeUs: Long, sampleRate: Int, channelCount: Int) {
        if (lastCapture == timeUs || sampleRate <= 0 || channelCount <= 0) return
        val bytes = when (encoding) {
            C.ENCODING_PCM_16BIT -> 2
            C.ENCODING_PCM_FLOAT -> 4
            else -> return
        }
        if (rate != sampleRate || channels != channelCount || expectedTime?.let { abs(timeUs - it) > 10_000 } == true) clear()
        rate = sampleRate
        channels = channelCount
        lastCapture = timeUs
        val data = buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN)
        val frames = data.remaining() / bytes / channelCount
        for (frame in 0 until frames) {
            var mono = 0.0
            repeat(channelCount) {
                val value = if (bytes == 2) data.short.toDouble() / 32768 else data.float.toDouble()
                mono += if (value.isFinite()) value else 0.0
            }
            val time = timeUs + frame * 1_000_000L / sampleRate
            spectrum.append(mono / channelCount, time, sampleRate)?.let { samples.addLast(it) }
        }
        expectedTime = timeUs + frames * 1_000_000L / sampleRate
        while (samples.size > 1000) samples.removeFirst()
    }

    @Synchronized fun levels(timeUs: Long): List<Float> =
        samples.lastOrNull { it.first <= timeUs && timeUs - it.first < 300_000 }?.second ?: List(4) { 0f }
}

@OptIn(UnstableApi::class)
class WaveformAudioSink(sink: AudioSink, private val waveform: AudioWaveform) : ForwardingAudioSink(sink) {
    private var encoding = C.ENCODING_INVALID
    private var offsetUs = 0L
    private var sampleRate = 0
    private var channelCount = 0

    override fun configure(config: AudioSink.AudioSinkConfig) {
        encoding = config.format.pcmEncoding
        sampleRate = config.format.sampleRate
        channelCount = config.format.channelCount
        waveform.clear()
        super.configure(config)
    }

    override fun setOutputStreamOffsetUs(outputStreamOffsetUs: Long) {
        offsetUs = outputStreamOffsetUs
        waveform.clear()
        super.setOutputStreamOffsetUs(outputStreamOffsetUs)
    }

    override fun handleBuffer(buffer: ByteBuffer, presentationTimeUs: Long, encodedAccessUnitCount: Int): Boolean {
        waveform.capture(buffer, encoding, presentationTimeUs - offsetUs, sampleRate, channelCount)
        return super.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount)
    }

    override fun flush() { waveform.clear(); super.flush() }
    override fun reset() { waveform.clear(); super.reset() }
}
