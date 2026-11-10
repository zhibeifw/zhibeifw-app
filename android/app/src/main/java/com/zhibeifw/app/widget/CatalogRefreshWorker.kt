package com.zhibeifw.app.widget

import android.content.Context
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.zhibeifw.app.ZhibeiApp
import java.util.concurrent.TimeUnit

/**
 * 后台取目录（和 iOS 的 BackgroundRefresh 一样）：每 2 小时左右取一次 index.json（没变服务器回 304，几乎不下载），
 * 有新课就更新小组件。什么时候真的执行由系统定（省电模式、没网时往后推）。
 * 另外“最新课程”小组件每 2 小时的系统刷新（updatePeriodMillis）也会叫它做一次：两条路一起，系统分开算。
 */
class CatalogRefreshWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result {
        val model = (applicationContext as ZhibeiApp).model
        return try {
            model.refreshInBackground()
            Result.success()
        } catch (e: Exception) {
            Log.w("CatalogRefresh", "后台取目录出错", e)
            Result.success()  // 不重试：下一个周期再取
        }
    }

    companion object {
        private const val PERIODIC = "catalogRefresh"
        private const val ONCE = "catalogRefreshNow"
        private val needsNetwork = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

        /** App 启动时登记（已登记就保留原来的时间表） */
        fun schedule(ctx: Context) {
            val req = PeriodicWorkRequestBuilder<CatalogRefreshWorker>(2, TimeUnit.HOURS).setConstraints(needsNetwork).build()
            WorkManager.getInstance(ctx).enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.KEEP, req)
        }

        /** 小组件被系统定时刷新时叫一次（正在做就不重复） */
        fun runOnce(ctx: Context) {
            val req = OneTimeWorkRequestBuilder<CatalogRefreshWorker>().setConstraints(needsNetwork).build()
            WorkManager.getInstance(ctx).enqueueUniqueWork(ONCE, ExistingWorkPolicy.KEEP, req)
        }
    }
}
