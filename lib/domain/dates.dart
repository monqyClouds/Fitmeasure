import 'package:intl/intl.dart';

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

final _short = DateFormat('d MMM');
final _full = DateFormat('d MMM yyyy');

String formatShortDate(DateTime d) => _short.format(d);

String formatDate(DateTime d) =>
    d.year == DateTime.now().year ? _short.format(d) : _full.format(d);

String formatDateRange(DateTime start, DateTime? end) => end == null
    ? 'From ${formatDate(start)}'
    : '${formatDate(start)} – ${formatDate(end)}';

String greeting([DateTime? now]) {
  final h = (now ?? DateTime.now()).hour;
  if (h < 12) return 'Good morning';
  if (h < 17) return 'Good afternoon';
  return 'Good evening';
}
