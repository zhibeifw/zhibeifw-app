package com.zhibeifw.app.download

import android.app.DownloadManager as AndroidDownloads
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import com.zhibeifw.app.core.fileKey
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * Android 的下载：系统的 DownloadManager 服务。
 *  · 排队、同时下几个、断网后等网络回来接着下、通知栏显示进度、App 被杀后照样继续，全由系统做；
 *  · 有网就下（系统默认允许流量和漫游），参数用系统默认值；
 *  · 系统没有公开的“暂停”：暂停 = 从系统里删掉，继续时从头下。
 * 系统把文件下到 App 专属的外部目录（不需要存储权限），文件名是集 ID 的文件键；下完由 DownloadManager 复制进资料库再交还系统删掉。
 * 进度：系统下载表有变化就通知（ContentObserver），收到后查一次表；另外收系统的“下载完成”广播，
 * 万一某些系统上收不到表的变化通知，下完的也能及时收尾。
 */
class SystemDownloader(private val ctx: Context) : SystemDownloads {
    private val dm = ctx.getSystemService(AndroidDownloads::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private var handler: ((DownloadEvent) -> Unit)? = null

    /** 文件键 → 集 ID（系统表里只有文件名） */
    private val byKey = ConcurrentHashMap<String, String>()

    /** 集 ID → 系统的下载编号，和反过来的表（查系统下载表时按编号认集） */
    private val sysIds = ConcurrentHashMap<String, Long>()
    private val idsBySys = ConcurrentHashMap<Long, String>()

    /** 数据库里没下完的集已经全部登记进 byKey（第一次对账时）：在这之前认不出的一律不当孤儿删 */
    @Volatile
    private var candidatesLoaded = false

    /** 已经排着一次查表：系统下载表连续变化时只查一次 */
    private val scanQueued = AtomicBoolean(false)

    private fun remember(id: String, sysId: Long) {
        sysIds.put(id, sysId)?.let { if (it != sysId) idsBySys.remove(it) }
        idsBySys[sysId] = id
    }

    private fun forget(id: String): Long? = sysIds.remove(id)?.also { idsBySys.remove(it) }

    /** 已经交出“下完 / 失败”的系统编号：等收尾时别重复交 */
    private val reported = ConcurrentHashMap.newKeySet<Long>()
    private val throttles = ConcurrentHashMap<Long, ProgressThrottle>()

    init {
        runCatching {
            ctx.contentResolver.registerContentObserver(
                Uri.parse("content://downloads/my_downloads"), true,
                object : ContentObserver(main) {
                    override fun onChange(selfChange: Boolean) = scan()
                })
        }
        runCatching {
            ContextCompat.registerReceiver(
                ctx,
                object : BroadcastReceiver() {
                    override fun onReceive(c: Context, i: Intent) = scan()
                },
                IntentFilter(AndroidDownloads.ACTION_DOWNLOAD_COMPLETE),
                ContextCompat.RECEIVER_EXPORTED
            )
        }
    }

    private fun dir() = ctx.getExternalFilesDir(DIR)

    override fun setHandler(h: (DownloadEvent) -> Unit) {
        handler = h; scan()
    }

    // 交给系统、从系统删掉都是跨进程调用（每集几毫秒），一次几十上百集会卡住主线程；
    // 放到查表用的那条线程上按顺序做：先交后删的顺序不会乱，暂停、取消总能删掉刚交出去的那一个
    override fun start(id: String, url: String, title: String, description: String) {
        val name = fileKey(id) + ".part"
        byKey[fileKey(id)] = id
        io.execute {
            runCatching {
                File(dir(), name).delete() // 同名旧文件在的话系统会另起名字
                val req = AndroidDownloads.Request(Uri.parse(url))
                    .setTitle(title)
                    .setDescription(description)
                    .setDestinationInExternalFilesDir(ctx, DIR, name)
                remember(id, dm.enqueue(req))
            }.onFailure { emit(DownloadEvent.Failed(id, false)) }
        }
    }

    override fun stop(id: String) {
        io.execute { forget(id)?.let { runCatching { dm.remove(it) } } }
    }

    override fun release(id: String) = stop(id)

    override suspend fun activeIds(candidates: Collection<String>): Set<String>? {
        // 登记和查表都在同一条线程上按顺序做：排在前面、还没交给系统的那几集先交出去，查表时就在了；
        // 启动时 setHandler 排的那次查表也不会撞上“登记到一半”，把上次没下完的当成孤儿删掉
        val all = suspendCancellableCoroutine { cont ->
            io.execute {
                val r = runCatching {
                    for (c in candidates) byKey[fileKey(c)] = c
                    candidatesLoaded = true
                    rows()
                }.getOrNull()
                cont.resume(r)
            }
        }
        // 查不了系统表：不能当成“系统里什么都没有”，否则在下的都会被记成暂停
        val active = (all ?: return null).filter { it.status != AndroidDownloads.STATUS_FAILED }.map { it.id }.toSet()
        main.post { scan() } // App 没开着时下完、失败的，现在认得出是哪一集了，交出去收尾
        return active
    }

    private class Row(
        val sysId: Long,
        val id: String,
        val status: Int,
        val reason: Int,
        val soFar: Long,
        val total: Long,
        val file: File?
    )

    /** 查系统下载表里我们的下载（文件名认得出、却没有对应下载记录的直接删掉：记录已经没了） */
    /** 查系统下载表；查不了返回 null */
    private fun rows(): List<Row>? {
        val out = ArrayList<Row>()
        val orphans = ArrayList<Long>()
        val ok = runCatching {
            dm.query(AndroidDownloads.Query())?.use { c ->
                val iId = c.getColumnIndexOrThrow(AndroidDownloads.COLUMN_ID)
                val iStatus = c.getColumnIndexOrThrow(AndroidDownloads.COLUMN_STATUS)
                val iReason = c.getColumnIndexOrThrow(AndroidDownloads.COLUMN_REASON)
                val iSoFar =
                    c.getColumnIndexOrThrow(AndroidDownloads.COLUMN_BYTES_DOWNLOADED_SO_FAR)
                val iTotal = c.getColumnIndexOrThrow(AndroidDownloads.COLUMN_TOTAL_SIZE_BYTES)
                val iUri = c.getColumnIndexOrThrow(AndroidDownloads.COLUMN_LOCAL_URI)
                // 交给系统时指定的目标地址：排队、还没开始下的那几集，上面的本地地址是空的，只有这一列有文件名
                val iHint = c.getColumnIndex("hint")
                while (c.moveToNext()) {
                    val sysId = c.getLong(iId)
                    // 下到 App 专属目录时系统给的是 file:// 地址；不是的话不拿它当文件路径，按我们交给系统时的文件名找
                    val uri = c.getString(iUri)?.let(Uri::parse)
                    val named = if (uri?.scheme == "file") uri.path?.let(::File) else null
                    val hinted = if (iHint >= 0) c.getString(iHint)?.let(Uri::parse)?.lastPathSegment else null
                    val name = named?.name ?: hinted
                    // 先按本次交给系统时记下的编号认；App 重启后按文件名认
                    val id = idsBySys[sysId] ?: name?.removeSuffix(".part")?.let { byKey[it] }
                    if (id == null) {
                        if (name != null) orphans.add(sysId); continue
                    }
                    val file = named ?: if (uri != null) File(dir(), fileKey(id) + ".part") else null
                    remember(id, sysId)
                    out.add(
                        Row(
                            sysId,
                            id,
                            c.getInt(iStatus),
                            c.getInt(iReason),
                            c.getLong(iSoFar),
                            maxOf(0, c.getLong(iTotal)),
                            file
                        )
                    )
                }
            }
        }.isSuccess
        if (orphans.isNotEmpty() && candidatesLoaded) runCatching { dm.remove(*orphans.toLongArray()) }
        return if (ok) out else null
    }

    private fun emit(e: DownloadEvent) = main.post { handler?.invoke(e) }

    private fun scan() {
        if (handler == null || !scanQueued.compareAndSet(false, true)) return
        io.execute {
            // 先放开再查：查的过程中又有变化，会再排一次，不会漏
            scanQueued.set(false)
            val all = rows() ?: return@execute
            // 系统表里已经没有的编号不会再出现（编号不复用），记着它们没用
            val live = all.mapTo(HashSet()) { it.sysId }
            reported.retainAll(live)
            throttles.keys.retainAll(live)
            for (r in all) when (r.status) {
                AndroidDownloads.STATUS_SUCCESSFUL ->
                    if (reported.add(r.sysId)) emit(
                        if (r.file != null) DownloadEvent.Finished(
                            r.id,
                            r.file
                        ) else DownloadEvent.Failed(r.id, false)
                    )

                AndroidDownloads.STATUS_FAILED -> if (reported.add(r.sysId)) {
                    emit(
                        DownloadEvent.Failed(
                            r.id,
                            r.reason == AndroidDownloads.ERROR_INSUFFICIENT_SPACE
                        )
                    )
                    forget(r.id); runCatching { dm.remove(r.sysId) }
                }

                else -> {
                    // 排队、下载中、等网络：系统都会自己接着下，界面上都算“下载中”
                    val th = throttles.getOrPut(r.sysId) { ProgressThrottle() }
                    if (th.pass(r.soFar, r.total)) emit(
                        DownloadEvent.Progress(
                            r.id,
                            r.soFar,
                            r.total
                        )
                    )
                }
            }
        }
    }

    companion object {
        const val DIR = "downloads"
    }
}
