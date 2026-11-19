package dev.playernostalgico.player_nostalgico

import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Recebe o texto do menu "Compartilhar" do Android (ex.: link vindo do app do YouTube ou do YT Music).
 *
 * O audio_service mantém UM motor do Flutter vivo enquanto a música toca, mesmo se a tela fechar.
 * Por isso o estado fica no companion (do processo, não da tela): se o Dart já está rodando, o link
 * vai na hora por "shared"; se ainda está abrindo, fica guardado até o Dart pedir com "initial".
 */
class ShareBridge(messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "nostalgic/share")

    init {
        current = this
        channel.setMethodCallHandler { call, result ->
            if (call.method == "initial") {
                dartReady = true
                result.success(pending)
                pending = null
            } else {
                result.notImplemented()
            }
        }
    }

    /** Entrega o link: na hora se o Dart já escuta, senão guarda até ele pedir. */
    fun deliver(intent: Intent?) {
        val text = textOf(intent) ?: return
        if (dartReady) channel.invokeMethod("shared", text) else pending = text
    }

    companion object {
        @Volatile private var pending: String? = null
        @Volatile private var dartReady = false
        var current: ShareBridge? = null
            private set

        fun textOf(intent: Intent?): String? {
            if (intent?.action != Intent.ACTION_SEND) return null
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()
            if (text.isNullOrEmpty()) return null
            // marca como usado: girar a tela ou voltar ao app não abre o mesmo link de novo
            intent.action = null
            return text
        }
    }
}
