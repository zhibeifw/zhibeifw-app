package com.zhibeifw.app

import android.os.Bundle
import androidx.annotation.OptIn
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.test.platform.app.InstrumentationRegistry
import com.zhibeifw.app.player.PlaybackConnections
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(UnstableApi::class)
class PlaybackConnectionTest {
    @Test
    fun onlyTrustedControllersCanControlTheCurrentEpisode() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        instrumentation.runOnMainSync {
            val player = ExoPlayer.Builder(context).build()
            val session = MediaSession.Builder(context, player).setCallback(PlaybackConnections).build()
            try {
                fun connect(trusted: Boolean): MediaSession.ConnectionResult {
                    val controller = MediaSession.ControllerInfo.createTestOnlyControllerInfo(
                        "test.controller", 123, 12345, 1, 1, trusted, Bundle.EMPTY, true
                    )
                    return PlaybackConnections.onConnect(session, controller)
                }
                assertFalse(connect(false).isAccepted)
                val result = connect(true)
                assertTrue(result.isAccepted)
                val commands = result.availablePlayerCommands
                assertTrue(commands.contains(Player.COMMAND_PLAY_PAUSE))
                assertTrue(commands.contains(Player.COMMAND_SEEK_BACK))
                assertTrue(commands.contains(Player.COMMAND_SEEK_FORWARD))
                assertFalse(commands.contains(Player.COMMAND_SET_MEDIA_ITEM))
                assertFalse(commands.contains(Player.COMMAND_CHANGE_MEDIA_ITEMS))
                assertFalse(commands.contains(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM))
            } finally {
                session.release()
                player.release()
            }
        }
    }
}
