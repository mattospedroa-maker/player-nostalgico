package dev.playernostalgico.player_nostalgico

import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Recebe o texto do menu "Compartilhar" do Android (ex.: link vindo do app do YouTube).
 * Se o app estava fechado, o Dart pergunta com "initial"; se já estava aberto, o texto chega por "shared".
 */
class ShareBridge(messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "nostalgic/share")
    private var pending: String? = null

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "initial") {
                result.success(pending)
                pending = null
            } else {
                result.notImplemented()
            }
        }
    }

    /** Guarda o texto até o Dart pedir (abertura a frio). */
    fun keep(intent: Intent?) {
        textOf(intent)?.let { pending = it }
    }

    /** App já aberto: manda na hora. */
    fun send(intent: Intent?) {
        val text = textOf(intent) ?: return
        channel.invokeMethod("shared", text)
    }

    companion object {
        fun textOf(intent: Intent?): String? {
            if (intent?.action != Intent.ACTION_SEND) return null
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()
            if (text.isNullOrEmpty()) return null
            // marca como usado: girar a tela não abre o mesmo link de novo
            intent.action = null
            return text
        }
    }
}
