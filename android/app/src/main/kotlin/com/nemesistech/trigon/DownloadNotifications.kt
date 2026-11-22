package com.nemesistech.trigon

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.Color
import android.os.Build

/**
 * The notifications of downloads that are queued, running or paused, with
 * their Pause / Resume / Cancel buttons.
 *
 * They are drawn here, not by the notification plugin, because a button tap
 * must reach the running download immediately and reliably: the plugin hands
 * button taps to a separate background engine, and that route never reached
 * the downloader. Here a tap is a plain broadcast to [DownloadActionReceiver],
 * which passes it straight to the Dart side of the already-running app.
 */
object DownloadNotifications {
    const val ACTION = "com.example.namesis_prime.DOWNLOAD_NOTIFICATION_ACTION"
    const val OPEN_ACTION = "com.example.namesis_prime.OPEN_DOWNLOADS"
    const val EXTRA_ACTION_ID = "download_action_id"
    const val EXTRA_NOTIFICATION_ID = "download_notification_id"
    const val EXTRA_OPEN_TAB = "download_open_tab"
    const val PROGRESS_CHANNEL = "nemesis_downloads_progress"

    private fun piFlags(): Int =
        PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)

    private fun ensureChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(PROGRESS_CHANNEL) != null) return
        val ch = NotificationChannel(
            PROGRESS_CHANNEL,
            "Download progress",
            NotificationManager.IMPORTANCE_LOW
        )
        ch.description = "Queued, downloading, and paused downloads."
        ch.setSound(null, null)
        ch.enableVibration(false)
        ch.setShowBadge(false)
        nm.createNotificationChannel(ch)
    }

    @Suppress("DEPRECATION")
    fun show(ctx: Context, a: Map<String, Any?>) {
        ensureChannel(ctx)

        val id = (a["id"] as Number).toInt()
        val title = a["title"] as? String ?: ""
        val text = a["text"] as? String ?: ""
        // -1: no bar, -2: indeterminate bar, 0..100: determinate bar.
        val progress = (a["progress"] as? Number)?.toInt() ?: -1
        val ongoing = a["ongoing"] as? Boolean ?: false
        val tab = a["tab"] as? String
        val subText = a["subText"] as? String
        val iconPath = a["largeIcon"] as? String
        val group = a["group"] as? String
        val buttons = a["buttons"] as? List<*> ?: emptyList<Any>()

        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(ctx, PROGRESS_CHANNEL)
        } else {
            Notification.Builder(ctx).setPriority(Notification.PRIORITY_LOW)
        }

        var icon = ctx.resources.getIdentifier("ic_notification", "drawable", ctx.packageName)
        if (icon == 0) icon = android.R.drawable.stat_sys_download

        b.setSmallIcon(icon)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setOngoing(ongoing)
            .setAutoCancel(!ongoing)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setColor(Color.parseColor("#D4AF37"))
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setVisibility(Notification.VISIBILITY_PUBLIC)

        if (!group.isNullOrEmpty()) b.setGroup(group)
        if (!subText.isNullOrEmpty()) b.setSubText(subText)
        when {
            progress == -2 -> b.setProgress(0, 0, true)
            progress >= 0 -> b.setProgress(100, progress.coerceAtMost(100), false)
        }
        if (!iconPath.isNullOrEmpty()) {
            try {
                BitmapFactory.decodeFile(iconPath)?.let { b.setLargeIcon(it) }
            } catch (e: Throwable) {
            }
        }

        for ((i, item) in buttons.withIndex()) {
            val m = item as? Map<*, *> ?: continue
            val actionId = m["id"] as? String ?: continue
            val label = m["label"] as? String ?: continue
            val intent = Intent(ctx, DownloadActionReceiver::class.java)
                .setAction(ACTION)
                .putExtra(EXTRA_ACTION_ID, actionId)
                .putExtra(EXTRA_NOTIFICATION_ID, id)
            val pi = PendingIntent.getBroadcast(ctx, id * 4 + i, intent, piFlags())
            b.addAction(Notification.Action.Builder(0, label, pi).build())
        }

        // Tapping the body opens the Downloads tab. An explicit intent with
        // its own action (not the launcher intent) so a running app always
        // receives it in onNewIntent.
        val open = Intent(ctx, MainActivity::class.java)
            .setAction(OPEN_ACTION)
            .putExtra(EXTRA_OPEN_TAB, tab ?: "")
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        b.setContentIntent(PendingIntent.getActivity(ctx, id * 4 + 3, open, piFlags()))

        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(id, b.build())
    }

    fun cancel(ctx: Context, id: Int) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(id)
    }

    /** Removes every download-progress notification (used when the app is swiped away). */
    fun cancelAllProgress(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            for (sbn in nm.activeNotifications) {
                if (sbn.notification.channelId == PROGRESS_CHANNEL) nm.cancel(sbn.tag, sbn.id)
            }
        } catch (e: Throwable) {
        }
    }
}

/** Receives Pause / Resume / Cancel taps and hands them to the running app. */
class DownloadActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val actionId = intent.getStringExtra(DownloadNotifications.EXTRA_ACTION_ID) ?: return
        if (!MainActivity.deliverDownloadAction(actionId)) {
            // The app is not running, so nothing is downloading any more:
            // the notification is stale. Remove it instead of leaving dead buttons.
            val nid = intent.getIntExtra(DownloadNotifications.EXTRA_NOTIFICATION_ID, 0)
            if (nid != 0) DownloadNotifications.cancel(context, nid)
        }
    }
}
