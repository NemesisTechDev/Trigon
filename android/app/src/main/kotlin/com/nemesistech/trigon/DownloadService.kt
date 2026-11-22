package com.nemesistech.trigon

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps the app process (and so the Dart downloader and the built-in torrent
 * engine) alive while downloads run: without a foreground service Android
 * freezes or kills the process soon after the screen turns off or the app
 * leaves the screen. Holds a partial wake lock and a Wi-Fi lock so the CPU
 * and the radio keep working too.
 *
 * The visible per-download notifications (with Pause / Cancel) are drawn from
 * Dart; this service only owns one small summary notification, which Android
 * requires for any foreground service.
 */
class DownloadService : Service() {

    companion object {
        private const val CHANNEL_ID = "nemesis_download_keepalive"
        private const val NOTIFICATION_ID = 7711
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_HOLD = "hold"
        private const val ACTION_STOP = "com.example.namesis_prime.STOP_DOWNLOAD_SERVICE"

        /** Returns false when Android refused to start it (app not allowed to right now). */
        fun start(context: Context, title: String, text: String, hold: Boolean = true): Boolean {
            return try {
                val i = Intent(context, DownloadService::class.java)
                    .putExtra(EXTRA_TITLE, title)
                    .putExtra(EXTRA_TEXT, text)
                    .putExtra(EXTRA_HOLD, hold)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(i)
                } else {
                    context.startService(i)
                }
                true
            } catch (e: Throwable) {
                false
            }
        }

        fun stop(context: Context) {
            try {
                context.startService(
                    Intent(context, DownloadService::class.java).setAction(ACTION_STOP)
                )
            } catch (e: Throwable) {
                try {
                    context.stopService(Intent(context, DownloadService::class.java))
                } catch (e2: Throwable) {
                }
            }
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            releaseLocks()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(Service.STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelf()
            return START_NOT_STICKY
        }

        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Downloading"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
        val notification = buildNotification(title, text)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        // While every download is paused the service only keeps the app (and
        // so the Resume button) alive; it must not keep the phone awake.
        if (intent?.getBooleanExtra(EXTRA_HOLD, true) != false) acquireLocks() else releaseLocks()
        // If Android ever kills the process, the downloads are gone with it
        // (paused on disk); restarting an empty service would help nobody.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }

    /**
     * The person swiped the app away from the recent apps list. That ends the
     * Flutter engine with the downloader inside it, so the downloads stop;
     * remove their notifications (their buttons would do nothing) and the
     * service instead of leaving them behind.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        DownloadNotifications.cancelAllProgress(this)
        // The app was swiped away: if its Activity was already gone, the
        // Flutter engine (and the downloader in it) would otherwise keep
        // running with no notification. End it so the next launch starts
        // from the splash.
        MainActivity.releaseEngineIfOrphaned()
        releaseLocks()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(Service.STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    private fun buildNotification(title: String, text: String): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            nm.getNotificationChannel(CHANNEL_ID) == null
        ) {
            val ch = NotificationChannel(
                CHANNEL_ID,
                "Download service",
                NotificationManager.IMPORTANCE_LOW
            )
            ch.description = "Keeps downloads running while the screen is off."
            ch.setShowBadge(false)
            nm.createNotificationChannel(ch)
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        var icon = resources.getIdentifier("ic_notification", "drawable", packageName)
        if (icon == 0) icon = android.R.drawable.stat_sys_download

        builder.setSmallIcon(icon)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)

        packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
            builder.setContentIntent(PendingIntent.getActivity(this, 0, launch, flags))
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    private fun acquireLocks() {
        try {
            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "nemesis:download")
                    .apply { setReferenceCounted(false) }
            }
            // Timed so a bug can never keep the phone awake forever; the app
            // renews it with every update call.
            wakeLock?.acquire(60L * 60 * 1000)
        } catch (e: Throwable) {
        }
        try {
            if (wifiLock == null) {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    @Suppress("DEPRECATION")
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifiLock = wm.createWifiLock(mode, "nemesis:download")
                    .apply { setReferenceCounted(false) }
            }
            if (wifiLock?.isHeld == false) wifiLock?.acquire()
        } catch (e: Throwable) {
        }
    }

    private fun releaseLocks() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (e: Throwable) {
        }
        try {
            if (wifiLock?.isHeld == true) wifiLock?.release()
        } catch (e: Throwable) {
        }
    }
}
