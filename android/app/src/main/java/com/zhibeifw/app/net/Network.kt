package com.zhibeifw.app.net

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network as AndroidNetwork
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.zhibeifw.app.core.FileKind
import com.zhibeifw.app.core.orderOrigins
import com.zhibeifw.app.core.parseDomains
import com.zhibeifw.app.data.DOMAINS_PATH
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

// 所有网络请求集中在这一个模块。用系统自带的 HttpURLConnection，不用 OkHttp。
// 地址一律是“当前可用的域名 + / + 相对路径”。只走 HTTPS（网络安全配置关闭明文）。

object NetConfig {
    /** 内置的域名（3 到 5 个，每个 App 版本换一批）。所有域名绑定同一个存储桶，内容完全一样。 */
    val builtinDomains = listOf("https://zbfw.org", "https://zbfw.app")
    const val RACE_STAGGER_MS = 1500L
    const val RACE_TIMEOUT_MS = 5000

    /** 空闲超时：连续这么久没收到数据才算超时（HttpURLConnection 的 readTimeout 就是这个语义）。 */
    const val IDLE_TIMEOUT_MS = 15000
    const val HEAD_TIMEOUT_MS = 5000
    const val PRIVACY_URL = "https://zhibeifw.com/privacy"
    const val SOURCE_URL = "https://github.com/zhibeifw/zhibeifw-app"
}

sealed class NetResult {
    data class Ok(val body: ByteArray, val etag: String?) : NetResult()
    object NotModified : NetResult()
    object NotFound : NetResult()
    data class Error(val reason: String) : NetResult()
}

val Context.prefs by preferencesDataStore(name = "prefs")

/** 小偏好（DataStore）。 */
object PrefKeys {
    val lastService = stringPreferencesKey("net.lastService")
    val domains = stringPreferencesKey("net.domains")
    val updateCheckedAt = longPreferencesKey("update.lastCheckedAt")
    val updateEtag = stringPreferencesKey("update.etag")
    val updateBody = stringPreferencesKey("update.body")
    val remindVersion = stringPreferencesKey("update.remindLater.version")
    val remindAt = longPreferencesKey("update.remindLater.at")
    val migratedV1 = stringPreferencesKey("migrated.v1kv")
}

/** encodeURI 的等价物：保留 URL 里的保留字符，其余（中文等）按 UTF-8 百分号编码。 */
fun buildUrl(origin: String, path: String): String {
    val keep = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789;,/?:@&=+$-_.!~*'()#"
    val sb = StringBuilder(origin).append('/')
    for (b in path.toByteArray(Charsets.UTF_8)) {
        val c = (b.toInt() and 0xFF).toChar()
        if (b >= 0 && keep.indexOf(c) >= 0) sb.append(c) else sb.append('%')
            .append("%02X".format(b.toInt() and 0xFF))
    }
    return sb.toString()
}

/** 网络状态（ConnectivityManager）。“有没有网络连接”用系统的，不用“能否上网”检测。 */
class Connectivity(ctx: Context) {
    var connected by mutableStateOf(true); private set
    val onReconnect = ArrayList<() -> Unit>()
    private val cm = ctx.getSystemService(ConnectivityManager::class.java)

    init {
        apply(cm.activeNetwork?.let { cm.getNetworkCapabilities(it) })
        // 只跟“默认网络”：Wi-Fi 刚连上时它还不是默认网络（还在用流量），等系统切过去才回调，这时读到的才准
        cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: AndroidNetwork) {
                val caps = cm.getNetworkCapabilities(network); post { apply(caps) }
            }

            override fun onLost(network: AndroidNetwork) = post { apply(null) }
            override fun onCapabilitiesChanged(network: AndroidNetwork, caps: NetworkCapabilities) =
                post { apply(caps) }
        })
    }

    private fun post(block: () -> Unit) {
        Handler(Looper.getMainLooper()).post(block)
    }

    private fun apply(caps: NetworkCapabilities?) {
        val was = connected
        connected = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
        if (connected && !was) onReconnect.toList().forEach { it() }
    }
}

class Network(private val ctx: Context) {
    @Volatile
    private var service: String? = null
    @Volatile
    private var lastKnown: String? = null
    private val resolveLock = Mutex()
    private var resolving: Deferred<String?>? = null

    /** 当前域名变化次数（封面据此在选出域名后重新取图）。 */
    var originVersion by mutableIntStateOf(0); private set

    val currentOrigin: String? get() = service

    /** 显示封面用：刷新线路期间、刷新失败后仍用最近一次选出过的。 */
    val displayOrigin: String? get() = service ?: lastKnown

    private fun setService(v: String?) {
        if (v != null) lastKnown = v
        if (service != v) {
            service = v
            Handler(Looper.getMainLooper()).post { originVersion++ }
        }
    }

    suspend fun ensureRoutes(): String? = service ?: resolve()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** 并发调用共用同一次选择。 */
    suspend fun resolve(): String? {
        val d = resolveLock.withLock {
            resolving ?: scope.async { doResolve() }.also { resolving = it }
        }
        val v = d.await()
        resolveLock.withLock { if (resolving === d) resolving = null }
        return v
    }

    private suspend fun doResolve(): String? {
        val p = ctx.prefs.data.first()
        val saved = p[PrefKeys.domains]?.let { parseDomains(it) }
        val origins = orderOrigins(
            p[PrefKeys.lastService],
            saved?.domains ?: emptyList(),
            NetConfig.builtinDomains
        )
        val won = pickFirstReachable(origins, probeScope = scope) { origin ->
            val r = get(
                buildUrl(origin, DOMAINS_PATH),
                null,
                FileKind.DOMAINS.limit,
                NetConfig.RACE_TIMEOUT_MS
            )
            if (r is NetResult.Ok) parseDomains(
                String(
                    r.body,
                    Charsets.UTF_8
                )
            ) else null // 内容必须是格式正确的 domains.json
        }
        if (won == null) {
            setService(null); return null
        }
        ctx.prefs.edit {
            it[PrefKeys.domains] = won.second.toJson()
            it[PrefKeys.lastService] = won.first
        }
        setService(won.first)
        return won.first
    }

    /** 手动入口（只有“关于 → 刷新网络线路”用）：忘掉记住的域名，重新选。返回 (选到的域名, 和原来是否同一个)。 */
    suspend fun refreshRoutes(): Pair<String?, Boolean> {
        val before = ctx.prefs.data.first()[PrefKeys.lastService] ?: service
        ?: NetConfig.builtinDomains.first()
        setService(null)
        ctx.prefs.edit { it.remove(PrefKeys.lastService) }
        val r = resolve()
        return r to (r != null && r == before)
    }

    /** 请求一个相对路径。失败如实返回，不自动换线路、不重试；还没有线路时先选一次。 */
    suspend fun request(path: String, etag: String?, maxBytes: Int): NetResult {
        val origin = ensureRoutes() ?: return NetResult.Error("没有可用线路")
        return get(buildUrl(origin, path), etag, maxBytes, NetConfig.IDLE_TIMEOUT_MS)
    }

    /** 只问一个相对路径的状态码（HEAD）。只用当前线路；拿不到返回 null。 */
    suspend fun headStatus(path: String): Int? = withContext(Dispatchers.IO) {
        val origin = service ?: return@withContext null
        try {
            val c = URL(buildUrl(origin, path)).openConnection() as HttpURLConnection
            c.requestMethod = "HEAD"
            c.connectTimeout = NetConfig.HEAD_TIMEOUT_MS
            c.readTimeout = NetConfig.HEAD_TIMEOUT_MS
            try {
                c.responseCode
            } finally {
                c.disconnect()
            }
        } catch (e: Exception) {
            null
        }
    }

    fun url(path: String): String? = service?.let { buildUrl(it, path) }

    private suspend fun get(url: String, etag: String?, maxBytes: Int, timeoutMs: Int): NetResult =
        withContext(Dispatchers.IO) {
            var c: HttpURLConnection? = null
            try {
                c = URL(url).openConnection() as HttpURLConnection
                c.connectTimeout = timeoutMs
                c.readTimeout = timeoutMs
                c.useCaches = false
                c.instanceFollowRedirects = true
                if (etag != null) c.setRequestProperty("If-None-Match", etag)
                when (val code = c.responseCode) {
                    304 -> return@withContext NetResult.NotModified
                    404 -> return@withContext NetResult.NotFound
                    200 -> {}
                    else -> return@withContext NetResult.Error(if (code >= 500) "服务器错误 $code" else "状态 $code")
                }
                if (c.contentLengthLong > maxBytes) return@withContext NetResult.Error("文件过大")
                val out = ByteArrayOutputStream()
                val buf = ByteArray(64 * 1024)
                c.inputStream.use { ins ->
                    while (true) {
                        val n = ins.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        if (out.size() > maxBytes) return@withContext NetResult.Error("文件过大")
                    }
                }
                NetResult.Ok(out.toByteArray(), c.getHeaderField("ETag"))
            } catch (e: SocketTimeoutException) {
                NetResult.Error("网络错误")
            } catch (e: IOException) {
                NetResult.Error("网络错误")
            } catch (e: Exception) {
                NetResult.Error("网络错误")
            } finally {
                c?.disconnect()
            }
        }
}

/**
 * 不等超时再换：从第一个开始试；前一个 1.5 秒还没回应就同时试下一个（前一个不取消）；
 * 前一个明确失败就立刻试下一个。谁先成功用谁，其余取消。全部失败返回 null。
 * 探测跑在 probeScope 里，不是调用方的子协程：HttpURLConnection 的阻塞读写取消不掉，
 * 放在 coroutineScope 里的话要等落选的探测各自超时才能返回，“谁先到用谁”就成了等最慢的那个。
 */
suspend fun <T : Any> pickFirstReachable(
    origins: List<String>,
    staggerMs: Long = NetConfig.RACE_STAGGER_MS,
    probeScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    probe: suspend (String) -> T?
): Pair<String, T>? {
    if (origins.isEmpty()) return null
    val events =
        Channel<Pair<Int, T?>>(Channel.UNLIMITED) // i ≥ 0：第 i 个的结果；i < 0：第 (-1-i) 个的计时到了
    val jobs = ArrayList<Job>()
    var next = 0
    var pending = 0
    val startedAfter = HashSet<Int>()
    fun start() {
        if (next >= origins.size) return
        val i = next++
        pending++
        jobs += probeScope.launch {
            events.send(
                i to try {
                    probe(origins[i])
                } catch (e: Exception) {
                    null
                }
            )
        }
        if (next < origins.size) jobs += probeScope.launch { delay(staggerMs); events.send((-1 - i) to null) }
    }
    try {
        start()
        while (true) {
            val (i, v) = events.receive()
            if (i >= 0) {
                pending--
                if (v != null) return origins[i] to v
                if (startedAfter.add(i)) start()
                if (pending == 0 && next >= origins.size) return null
            } else {
                val after = -1 - i
                if (startedAfter.add(after)) start()
            }
        }
    } finally {
        jobs.forEach { it.cancel() }
    }
}
