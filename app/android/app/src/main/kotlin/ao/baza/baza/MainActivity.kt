package ao.baza.baza

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Liga e desliga o serviço que mantém a partilha do som da viagem em segundo plano.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ao.baza.baza/som_da_viagem")
            .setMethodCallHandler { call, result ->
                val service = Intent(this, AlertAudioService::class.java)
                when (call.method) {
                    "start" -> try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(service) else startService(service)
                        result.success(true)
                    } catch (e: Exception) {
                        // Sem o serviço a gravação continua, mas só com o app no ecrã.
                        result.success(false)
                    }
                    "stop" -> {
                        stopService(service)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
