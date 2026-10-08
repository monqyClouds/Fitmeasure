import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../data/repos/settings_repo.dart';

/// Timer beeps: a tick for each of the last seconds, a double beep when the
/// next stretch starts, and a chime when it's all done. On Android they
/// mix with music and with a live session's audio (see MainActivity.kt);
/// elsewhere, and with "Timer sounds" off, the timers only vibrate.
class Beeper {
  Beeper(this._enabled);
  final bool Function() _enabled;

  static const _channel = MethodChannel('fitmeasure/beep');

  void tick() => _play('tick');
  void go() => _play('go');
  void done() => _play('done');

  void _play(String sound) {
    if (!_enabled() || kIsWeb || !Platform.isAndroid) return;
    _channel.invokeMethod<void>(sound).catchError((Object _) {});
  }
}

/// Whether the timers beep (Settings, on by default).
final timerSoundsProvider = StreamProvider<bool>(
  (ref) => ref
      .watch(settingsRepoProvider)
      .watchBool(SettingsRepo.timerSounds, fallback: true),
);

final beeperProvider = Provider((ref) {
  final on = ref.watch(timerSoundsProvider).value ?? true;
  return Beeper(() => on);
});
