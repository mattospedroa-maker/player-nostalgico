package dev.playernostalgico.player_nostalgico

import android.content.Intent
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        YtDlpBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        ShareBridge(flutterEngine.dartExecutor.binaryMessenger).deliver(intent)
    }

    // link compartilhado com o app já aberto (singleTask: reaproveita esta mesma janela)
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        ShareBridge.current?.deliver(intent)
    }
}
