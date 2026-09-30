import 'enums.dart';

/// 60 → "60", 62.5 → "62.5", 0.125 → "0.13".
String formatNumber(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  final s = v.toStringAsFixed(2);
  return s.endsWith('0') ? s.substring(0, s.length - 1) : s;
}

String formatKg(double kg) => '${formatNumber(kg)} kg';

String formatKm(double km) => '${formatNumber(km)} km';

/// 75 → "1:15", 3725 → "1:02:05".
String formatDuration(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}

/// Parses "90", "1:30" or "1:02:05" into seconds; null if it isn't one.
int? parseDuration(String text) {
  final parts = text.trim().split(':');
  if (parts.isEmpty || parts.length > 3) return null;
  var total = 0;
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0) return null;
    total = total * 60 + n;
  }
  return total;
}

/// Parses a decimal typed with either "." or ",".
double? parseDecimal(String text) =>
    double.tryParse(text.trim().replaceAll(',', '.'));

/// A compact description of one set, e.g. "60 kg × 10", "1:00" or
/// "5 km · 30:00". Empty when nothing is given.
String describeSet(
  TrackingType tracking, {
  int? reps,
  double? weightKg,
  int? durationSec,
  double? distanceKm,
}) {
  switch (tracking) {
    case TrackingType.reps:
      if (reps == null) return weightKg == null ? '' : formatKg(weightKg);
      return weightKg == null || weightKg == 0
          ? '$reps reps'
          : '${formatKg(weightKg)} × $reps';
    case TrackingType.time:
      return durationSec == null ? '' : formatDuration(durationSec);
    case TrackingType.distance:
      return [
        if (distanceKm != null) formatKm(distanceKm),
        if (durationSec != null) formatDuration(durationSec),
      ].join(' · ');
  }
}

/// Targets for an exercise, e.g. "4 × 10 · 60 kg" or "3 × 1:00".
String describeTargets(
  TrackingType tracking, {
  required int sets,
  int? reps,
  double? weightKg,
  int? durationSec,
  double? distanceKm,
}) {
  final parts = <String>[];
  switch (tracking) {
    case TrackingType.reps:
      parts.add(reps == null ? '$sets sets' : '$sets × $reps');
      if (weightKg != null && weightKg > 0) parts.add(formatKg(weightKg));
    case TrackingType.time:
      parts.add(
        durationSec == null
            ? '$sets sets'
            : '$sets × ${formatDuration(durationSec)}',
      );
    case TrackingType.distance:
      parts.add(sets == 1 ? '1 set' : '$sets sets');
      if (distanceKm != null) parts.add(formatKm(distanceKm));
      if (durationSec != null) parts.add(formatDuration(durationSec));
  }
  return parts.join(' · ');
}

const weekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

const weekdayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
