package com.zhibeifw.app.data

import android.util.Log
import com.zhibeifw.app.core.FileKind
import com.zhibeifw.app.core.parseIndex
import com.zhibeifw.app.net.NetResult
import com.zhibeifw.app.net.Network
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

// ETag 同步，与 iOS CatalogSync.swift 一致。

enum class FileStatus { UPDATED, UNCHANGED, INVALID, FAILED, MISSING }

data class SyncSummary(val index: FileStatus) {
    val failed get() = index == FileStatus.FAILED
    val changed get() = index == FileStatus.UPDATED
}

object CatalogSync {
    suspend fun syncIndex(store: Store, net: Network): FileStatus {
        // 读库、选线路出错都按“同步失败”处理，不往外抛（调用方多在没有错误处理的协程里）
        val etag = withContext(Dispatchers.IO) { runCatching { store.etag(INDEX_PATH) }.getOrNull() }
        val r = try {
            net.request(INDEX_PATH, etag, FileKind.INDEX.limit)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w("CatalogSync", "取目录失败", e); return FileStatus.FAILED
        }
        return when (r) {
            NetResult.NotModified -> FileStatus.UNCHANGED
            NetResult.NotFound -> FileStatus.MISSING
            is NetResult.Error -> FileStatus.FAILED
            is NetResult.Ok -> withContext(Dispatchers.IO) {
                val parsed = parseIndex(String(r.body, Charsets.UTF_8))
                    ?: return@withContext FileStatus.INVALID
                try {
                    store.replaceIndex(parsed)
                    store.setEtag(INDEX_PATH, r.etag)
                    FileStatus.UPDATED
                } catch (e: Exception) {
                    Log.w("CatalogSync", "写目录失败", e)
                    FileStatus.FAILED
                }
            }
        }
    }

    suspend fun sync(store: Store, net: Network) = SyncSummary(syncIndex(store, net))

    /** 首次初始化：同步一次，index.json 成功（更新到了或没变化）才算完成并记下。 */
    suspend fun initialize(store: Store, net: Network): Boolean {
        val s = syncIndex(store, net)
        if (s == FileStatus.UPDATED || s == FileStatus.UNCHANGED) {
            return withContext(Dispatchers.IO) { runCatching { store.markInitialized() }.isSuccess }
        }
        return false
    }

    const val INIT_ATTEMPTS = 3
    val INIT_DELAYS_MS = listOf(2000L, 4000L)

    /** 首次初始化的自动重试：最多 3 次，间隔 2 秒、4 秒。 */
    suspend fun initializeWithRetry(
        store: Store,
        net: Network,
        sleep: suspend (Long) -> Unit = { delay(it) },
        onAttempt: (Int) -> Unit = {}
    ): Boolean {
        for (n in 1..INIT_ATTEMPTS) {
            onAttempt(n)
            if (initialize(store, net)) return true
            if (n < INIT_ATTEMPTS) sleep(INIT_DELAYS_MS[minOf(n - 1, INIT_DELAYS_MS.size - 1)])
        }
        return false
    }
}
