package dev.playernostalgico.player_nostalgico

import android.annotation.SuppressLint
import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager

/**
 * Serviço em primeiro plano só enquanto a fila do YouTube baixa. Com ele o Android (e a economia de bateria da
 * Xiaomi) não fecha o app quando ele vai para segundo plano. Segura a CPU e o Wi-Fi acordados com prazo curto,
 * renovado a cada atualização da notificação: se o app morrer de outro jeito, eles se soltam sozinhos.
 * Não usa biblioteca nova; a notificação é a mesma que o YtDlpBridge já monta.
 */
class DownloadKeepAliveService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_CANCEL) {
            // botão "Cancelar tudo" da notificação: quem para a fila é o Dart (ele avisa o fim e o serviço sai)
            val cb = onCancel
            if (running && cb != null) {
                cb()
            } else {
                // notificação velha (fila já parada) ou app sem o Dart: só tira tudo
                if (!running) stopSelf()
                stop(this, keepNotification = false)
                (getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager).cancel(NOTIFICATION_ID)
            }
            return START_NOT_STICKY
        }
        val n = pending
        if (n == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIFICATION_ID, n)
            }
        } catch (e: Exception) {
            // Android 12+ recusa começar em segundo plano: segue sem proteção (como antes) em vez de travar
            running = false
            stopSelf()
            return START_NOT_STICKY
        }
        renewLocks(this)
        // se o sistema matar o serviço, não recria sozinho: a fila (no Dart) continua quando o app abrir de novo
        return START_NOT_STICKY
    }

    // Android 15+: serviço de sincronização tem limite de 6 h por dia; ao bater, sai sem travar o app
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    override fun onDestroy() {
        // fim com resumo: a notificação fica (vira comum, dá para arrastar); cancelado sem nada: some
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(if (keepNotification) STOP_FOREGROUND_DETACH else STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION") stopForeground(!keepNotification)
        }
        running = false
        releaseLocks()
        super.onDestroy()
    }

    companion object {
        const val NOTIFICATION_ID = 4207
        const val ACTION_CANCEL = "dev.playernostalgico.downloads.CANCEL"

        /** Chamado no botão "Cancelar tudo" (o YtDlpBridge passa para o Dart). */
        @Volatile var onCancel: (() -> Unit)? = null
        // prazo das travas; renovado a cada ~1 s de progresso, então só vence se o download ficar parado
        private const val LOCK_TIMEOUT_MS = 10 * 60 * 1000L

        @Volatile private var running = false
        @Volatile private var pending: Notification? = null
        @Volatile private var keepNotification = true
        private var cpu: PowerManager.WakeLock? = null
        private var wifi: WifiManager.WifiLock? = null

        /** Mostra a notificação de "baixando" protegida. Começa o serviço na primeira vez. */
        fun update(context: Context, notification: Notification): Boolean {
            pending = notification
            keepNotification = true
            if (running) {
                renewLocks(context)
                return false // quem chamou atualiza a notificação pelo NotificationManager
            }
            running = true
            return try {
                val i = Intent(context, DownloadKeepAliveService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(i) else context.startService(i)
                true
            } catch (e: Exception) {
                running = false
                false
            }
        }

        /** Fila acabou (ou foi cancelada): solta tudo e deixa o Android fechar o app quando quiser. */
        fun stop(context: Context, keepNotification: Boolean = true) {
            this.keepNotification = keepNotification
            pending = null
            if (!running) return
            running = false
            releaseLocks()
            context.stopService(Intent(context, DownloadKeepAliveService::class.java))
        }

        @Synchronized
        @SuppressLint("WakelockTimeout")
        private fun renewLocks(context: Context) {
            val app = context.applicationContext
            val c = cpu ?: (app.getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "nostalgic:downloads")
                .apply { setReferenceCounted(false) }
                .also { cpu = it }
            c.acquire(LOCK_TIMEOUT_MS)
            val w = wifi ?: (app.getSystemService(Context.WIFI_SERVICE) as? WifiManager)
                ?.createWifiLock(wifiMode(), "nostalgic:downloads")
                ?.apply { setReferenceCounted(false) }
                ?.also { wifi = it }
            if (w != null && !w.isHeld) w.acquire()
            // vigia: sem nenhuma atualização no prazo (Dart travou), encerra o serviço e solta o Wi-Fi
            watchdog.removeCallbacksAndMessages(null)
            watchdog.postDelayed({ stop(app) }, LOCK_TIMEOUT_MS)
        }

        private val watchdog = Handler(Looper.getMainLooper())

        @Suppress("DEPRECATION")
        private fun wifiMode() = WifiManager.WIFI_MODE_FULL_HIGH_PERF

        @Synchronized
        private fun releaseLocks() {
            watchdog.removeCallbacksAndMessages(null)
            cpu?.let { if (it.isHeld) it.release() }
            wifi?.let { if (it.isHeld) it.release() }
        }
    }
}
