package ao.baza.baza

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Mantém a partilha do som da viagem a funcionar com o ecrã bloqueado ou com
 * outra aplicação aberta, durante um alerta de perigo.
 *
 * O Android só deixa uma aplicação usar o microfone em segundo plano se ela
 * tiver um serviço em primeiro plano do tipo "microfone", com uma notificação
 * sempre visível. Este serviço não grava: a gravação é feita pelo Flutter
 * (lib/services/alert_audio.dart); o serviço só mantém o processo activo.
 */
class AlertAudioService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Som da viagem", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Visível enquanto partilha o som da viagem num alerta de perigo"
                },
            )
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle("Bazá · alerta de perigo")
            .setContentText("A partilhar o som da viagem. Toque para abrir.")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        // O processador não adormece com o ecrã desligado enquanto se grava e envia.
        if (wakeLock == null) {
            wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "baza:som-da-viagem")
                .apply { acquire(MAX_MS) }
        }
        // Se o sistema matar o serviço, não o recria sozinho: sem o Flutter não há gravação.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "baza_som_da_viagem"
        private const val NOTIFICATION_ID = 7301

        /** Limite de segurança: o som de um alerta dura no máximo cerca de uma hora. */
        private const val MAX_MS = 70L * 60L * 1000L
    }
}
