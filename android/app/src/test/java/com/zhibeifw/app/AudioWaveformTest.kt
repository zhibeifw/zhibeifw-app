package com.zhibeifw.app

import androidx.media3.common.C
import com.zhibeifw.app.player.AudioWaveform
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.*
import org.junit.Assert.*
import org.junit.Test

class AudioWaveformTest {
    private fun tone(bin: Int, count: Int = 1024, start: Int = 0): ByteBuffer {
        val buffer = ByteBuffer.allocate(count * 4).order(ByteOrder.LITTLE_ENDIAN)
        repeat(count) { buffer.putFloat((.1 * sin(2 * PI * bin * (start + it) / 1024)).toFloat()) }
        buffer.flip()
        return buffer
    }
    @Test fun separatesBandsWithoutConsumingPlaybackBuffer() {
        listOf(4, 12, 48, 128).forEachIndexed { band, bin ->
            val meter = AudioWaveform()
            val buffer = tone(bin)
            meter.capture(buffer, C.ENCODING_PCM_FLOAT, 1_000_000, 48000, 1)
            assertEquals(0, buffer.position())
            val levels = meter.levels(1_000_000)
            assertEquals(.1f, levels[band], .0001f)
            levels.forEachIndexed { index, value -> if (index != band) assertTrue(value < .0001f) }
            assertTrue(meter.levels(900_000).all { it == 0f })
        }
    }
    @Test fun joinsBuffersAndIgnoresRepeatedPartialWrite() {
        val meter = AudioWaveform()
        val first = tone(12, 512)
        meter.capture(first, C.ENCODING_PCM_FLOAT, 0, 48000, 1)
        meter.capture(first, C.ENCODING_PCM_FLOAT, 0, 48000, 1)
        assertTrue(meter.levels(0).all { it == 0f })
        meter.capture(tone(12, 512, 512), C.ENCODING_PCM_FLOAT, 10_666, 48000, 1)
        assertEquals(.1f, meter.levels(0)[1], .0001f)
    }
    @Test fun seekAndClearDiscardOldSamples() {
        val meter = AudioWaveform()
        meter.capture(tone(4), C.ENCODING_PCM_FLOAT, 2_000_000, 48000, 1)
        val silence = ByteBuffer.allocate(4096)
        meter.capture(silence, C.ENCODING_PCM_FLOAT, 1_000_000, 48000, 1)
        assertTrue(meter.levels(2_000_000).all { it == 0f })
        meter.clear()
        assertTrue(meter.levels(1_000_000).all { it == 0f })
    }
}
