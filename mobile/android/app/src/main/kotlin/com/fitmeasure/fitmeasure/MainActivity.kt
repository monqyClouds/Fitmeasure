package com.fitmeasure.fitmeasure

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.media.ToneGenerator
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

        // Timer beeps for lib/services/beeper.dart. ToneGenerator plays on
        // the media stream without taking audio focus or changing the audio
        // mode, so music carries on underneath and a live session's call
        // audio isn't disturbed.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fitmeasure/beep")
            .setMethodCallHandler { call, result ->
                val (tone, ms) = when (call.method) {
                    "tick" -> ToneGenerator.TONE_PROP_BEEP to 120
                    "go" -> ToneGenerator.TONE_PROP_BEEP2 to 450
                    "done" -> ToneGenerator.TONE_CDMA_CONFIRM to 900
                    else -> {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                }
                beep(tone, ms)
                result.success(null)
            }
    }

    private var tones: ToneGenerator? = null

    private fun beep(tone: Int, ms: Int) {
        try {
            val t = tones ?: ToneGenerator(AudioManager.STREAM_MUSIC, 90).also { tones = it }
            t.startTone(tone, ms)
        } catch (e: RuntimeException) {
            // No tone generator (audio busy or unavailable): stay silent.
            tones = null
        }
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
        tones?.release()
        tones = null
        LiveSessionService.onLeave = null
        super.onDestroy()
    }
}
