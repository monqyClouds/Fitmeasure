import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps a live session's camera and microphone running while the app is in
/// the background or the screen is locked.
///
/// On Android this runs a foreground service with a notification
/// (android/.../LiveSessionService.kt), which Android requires before an app
/// in the background may use the camera and microphone. The notification's
/// Leave button calls [start]'s `onLeave`. Elsewhere it does nothing.
abstract final class LiveSessionService {
  static const _channel = MethodChannel('fitmeasure/live_session');

  static Future<void> start({
    required String room,
    required VoidCallback onLeave,
  }) async {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'leave') onLeave();
    });
    try {
      await _channel.invokeMethod<void>('start', {'room': room});
    } on PlatformException catch (e) {
      // The session still works while the app is open.
      debugPrint('live: foreground service not started: $e');
    }
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler(null);
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException catch (e) {
      debugPrint('live: foreground service not stopped: $e');
    }
  }
}
