package dev.playernostalgico.player_nostalgico

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Ponte para o yt-dlp embarcado (youtubedl-android: o mesmo yt-dlp do .exe, com Python e ffmpeg para Android).
 * Os nomes, a fila e as regras ficam no Dart; aqui só roda o yt-dlp e mostra a notificação.
 */
class YtDlpBridge(private val context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private val infoPool = Executors.newFixedThreadPool(2)
    private val downloadPool = Executors.newSingleThreadExecutor()
    private var events: EventChannel.EventSink? = null

    @Volatile private var ready = false

    init {
        MethodChannel(messenger, "nostalgic/ytdlp").setMethodCallHandler(this)
        EventChannel(messenger, "nostalgic/ytdlp/progress").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) { events = sink }
            override fun onCancel(arguments: Any?) { events = null }
        })
    }

    @Synchronized
    private fun ensureInit() {
        if (ready) return
        YoutubeDL.getInstance().init(context)
        FFmpeg.getInstance().init(context)
        ready = true
    }

    private fun <T> background(pool: java.util.concurrent.ExecutorService, result: MethodChannel.Result, work: () -> T) {
        pool.execute {
            try {
                ensureInit()
                val value = work()
                main.post { result.success(value) }
            } catch (e: YoutubeDL.CanceledException) {
                main.post { result.error("canceled", "Cancelado", null) }
            } catch (e: Throwable) {
                main.post { result.error("ytdlp", e.message ?: e.toString(), null) }
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "version" -> background(infoPool, result) { YoutubeDL.getInstance().version(context) ?: "" }
            "update" -> background(infoPool, result) {
                YoutubeDL.getInstance().updateYoutubeDL(context, YoutubeDL.UpdateChannel.STABLE)?.name ?: ""
            }
            // Roda o yt-dlp com os argumentos dados e devolve o que ele escreveu (ex.: -J = JSON com as informações).
            "run" -> {
                val args = call.argument<List<String>>("args") ?: emptyList()
                val id = call.argument<String>("id")
                val download = call.argument<Boolean>("download") ?: false
                background(if (download) downloadPool else infoPool, result) {
                    val request = YoutubeDLRequest(emptyList<String>())
                    request.addCommands(args)
                    val response = YoutubeDL.getInstance().execute(request, id) { progress, eta, line ->
                        if (id != null) {
                            main.post {
                                events?.success(mapOf("id" to id, "progress" to progress.toDouble(), "eta" to eta, "line" to line))
                            }
                        }
                    }
                    mapOf("exitCode" to response.exitCode, "out" to response.out, "err" to response.err)
                }
            }
            "cancel" -> {
                val id = call.argument<String>("id") ?: ""
                result.success(YoutubeDL.getInstance().destroyProcessById(id))
            }
            "notify" -> {
                notify(
                    call.argument<String>("title") ?: "",
                    call.argument<String>("text") ?: "",
                    call.argument<Int>("progress") ?: -1,
                    call.argument<Boolean>("done") ?: false,
                )
                result.success(null)
            }
            "deleteDir" -> {
                File(call.argument<String>("path") ?: "").deleteRecursively()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private val channelId = "dev.playernostalgico.downloads"
    private val notificationId = 4207

    private fun notify(title: String, text: String, progress: Int, done: Boolean) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nm.getNotificationChannel(channelId) == null) {
            nm.createNotificationChannel(NotificationChannel(channelId, "Downloads do YouTube", NotificationManager.IMPORTANCE_LOW))
        }
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
        }
        val pending = launch?.let {
            PendingIntent.getActivity(context, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        val b = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(if (done) android.R.drawable.stat_sys_download_done else android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(text)
            .setOnlyAlertOnce(true)
            .setOngoing(!done)
            .setAutoCancel(done)
            .setContentIntent(pending)
        if (!done) b.setProgress(100, progress.coerceIn(0, 100), progress < 0)
        try {
            nm.notify(notificationId, b.build())
        } catch (_: SecurityException) {
            // sem permissão de notificação: segue sem avisar
        }
    }
}
