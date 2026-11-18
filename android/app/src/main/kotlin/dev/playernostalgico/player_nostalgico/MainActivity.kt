package dev.playernostalgico.player_nostalgico

import android.content.Intent
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : AudioServiceActivity() {
    private var share: ShareBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        YtDlpBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        share = ShareBridge(flutterEngine.dartExecutor.binaryMessenger).also { it.keep(intent) }
    }

    // link compartilhado com o app já aberto
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        share?.send(intent)
    }
}
