package com.fitmeasure.fitmeasure

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Starts and stops LiveSessionService for lib/features/live/live_session_service.dart.
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fitmeasure/live_session")
        channel.setMethodCallHandler { call, result ->
            val service = Intent(this, LiveSessionService::class.java)
            when (call.method) {
                "start" -> {
                    askForNotifications()
                    service.putExtra(LiveSessionService.EXTRA_ROOM, call.argument<String>("room"))
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(service)
                    } else {
                        startService(service)
                    }
                    result.success(null)
                }
                "stop" -> {
                    stopService(service)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        LiveSessionService.onLeave = { channel.invokeMethod("leave", null) }
    }

    /**
     * From Android 13 notifications need permission. Without it the session
     * still keeps running in the background; only the notification is hidden.
     */
    private fun askForNotifications() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    override fun onDestroy() {
        LiveSessionService.onLeave = null
        super.onDestroy()
    }
}
