package com.zhibeifw.app.player

import kotlin.math.*

/** 同一1024采样窗口的四频段幅度，与Apple端使用相同分界和归一化。 */
internal class AudioSpectrum {
    private val size = 1024
    private val input = DoubleArray(size)
    private val real = DoubleArray(size)
    private val imaginary = DoubleArray(size)
    private var used = 0
    private var startUs = 0L

    fun reset() { used = 0 }

    fun append(value: Double, timeUs: Long, sampleRate: Int): Pair<Long, List<Float>>? {
        if (used == 0) startUs = timeUs
        input[used++] = if (value.isFinite()) value else 0.0
        if (used < size) return null
        used = 0
        for (i in 0 until size) {
            val reversed = Integer.reverse(i) ushr (32 - 10)
            real[reversed] = input[i]
            imaginary[reversed] = 0.0
        }
        var length = 2
        while (length <= size) {
            val angle = -2 * PI / length
            val stepReal = cos(angle)
            val stepImaginary = sin(angle)
            for (start in 0 until size step length) {
                var wr = 1.0
                var wi = 0.0
                for (j in 0 until length / 2) {
                    val a = start + j
                    val b = a + length / 2
                    val br = real[b] * wr - imaginary[b] * wi
                    val bi = real[b] * wi + imaginary[b] * wr
                    real[b] = real[a] - br
                    imaginary[b] = imaginary[a] - bi
                    real[a] += br
                    imaginary[a] += bi
                    val next = wr * stepReal - wi * stepImaginary
                    wi = wr * stepImaginary + wi * stepReal
                    wr = next
                }
            }
            length *= 2
        }
        val energy = DoubleArray(4)
        for (bin in 1 until size / 2) {
            val frequency = bin.toDouble() * sampleRate / size
            val band = when { frequency < 250 -> 0; frequency < 1000 -> 1; frequency < 4000 -> 2; else -> 3 }
            energy[band] += real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
        }
        return startUs to energy.map { (2 * sqrt(it) / size).toFloat().coerceIn(0f, 1f) }
    }
}
