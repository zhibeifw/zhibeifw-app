package com.zhibeifw.app

import android.content.Context
import android.content.Intent
import com.zhibeifw.app.core.UpdateChannel
import com.zhibeifw.app.net.buildUrl

internal object ChannelUpdates {
    val channel = UpdateChannel.SITE

    fun open(context: Context, origin: String?, version: String, apkPath: String, notify: (String) -> Unit) {
        if (origin == null) {
            notify("网络线路尚未就绪，请稍后重试")
            return
        }
        context.startActivity(UpdateInstallActivity.intent(context, buildUrl(origin, apkPath), version)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
