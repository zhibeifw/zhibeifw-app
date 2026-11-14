package com.zhibeifw.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.zhibeifw.app.design.generated.Tok
import com.zhibeifw.app.player.PlayerHolder
import kotlinx.coroutines.delay
import kotlin.math.pow
import com.zhibeifw.app.design.C

@Composable
fun AudioWaveformIcon() {
    val context = LocalContext.current
    var levels by remember { mutableStateOf(List(4) { 0f }) }
    LaunchedEffect(Unit) {
        val player = PlayerHolder.get(context)
        while (true) {
            levels = if (player.isPlaying) PlayerHolder.waveform.levels(player.currentPosition * 1000) else List(4) { 0f }
            delay(50)
        }
    }
    val spec = Tok.Component.AudioWaveform
    Row(Modifier.size(spec.width.dp, spec.height.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(spec.spacing.dp)) {
        levels.forEach { level ->
            Box(Modifier.width(spec.barWidth.dp)
                .height(maxOf(spec.barWidth, spec.height * (level * spec.spectrumGain).coerceIn(0f, 1f).pow(spec.spectrumExponent)).dp)
                .background(C.labelPrimary(), CircleShape))
        }
    }
}
