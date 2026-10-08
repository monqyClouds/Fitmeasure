package com.fitmeasure.fitmeasure

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Keeps a live session's camera and microphone running while the app is in
 * the background or the screen is locked.
 *
 * Android stops background apps from using the camera and microphone unless
 * they run a foreground service of those types, which must show a
 * notification. The notification says you're in a session, reopens the app
 * when tapped, and has a Leave button.
 */
class LiveSessionService : Service() {
    companion object {
        const val EXTRA_ROOM = "room"
        const val ACTION_LEAVE = "com.fitmeasure.fitmeasure.LEAVE_LIVE_SESSION"
        private const val CHANNEL_ID = "live_session"
        private const val NOTIFICATION_ID = 7001

        /** Called on the main thread when the notification's Leave is tapped. */
        var onLeave: (() -> Unit)? = null
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_LEAVE) {
            onLeave?.invoke()
            stopSelf()
            return START_NOT_STICKY
        }

        val notification = buildNotification(intent?.getStringExtra(EXTRA_ROOM) ?: "")
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // E.g. a permission was revoked. The session carries on while the
            // app is open; it just won't survive going to the background.
            Log.w("LiveSessionService", "couldn't start in the foreground", e)
            stopSelf()
        }
        // If Android kills the process, the session is gone; don't restart.
        return START_NOT_STICKY
    }

    private fun buildNotification(room: String): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Live sessions", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while you're in a live session"
                },
            )
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val leave = PendingIntent.getService(
            this,
            1,
            Intent(this, LiveSessionService::class.java).setAction(ACTION_LEAVE),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        builder
            .setSmallIcon(R.drawable.ic_live_notification)
            .setContentTitle("Live session")
            .setContentText(if (room.isEmpty()) "Camera and microphone on" else "In \"$room\" · camera and microphone on")
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_CALL)
            .setContentIntent(open)
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, R.drawable.ic_live_notification),
                    "Leave",
                    leave,
                ).build(),
            )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }
}
