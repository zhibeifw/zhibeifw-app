package com.zhibeifw.app

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import com.zhibeifw.app.core.UpdateChannel

internal object ChannelUpdates {
    val channel = UpdateChannel.STORE

    fun open(context: Context, origin: String?, version: String, apkPath: String, notify: (String) -> Unit) {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=com.zhibeifw.app"))
            .setPackage("com.android.vending")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            notify("此设备无法打开 Google Play 商店")
        }
    }
}
