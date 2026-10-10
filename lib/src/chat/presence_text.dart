import 'models.dart';

/// Human status line for a 1-1 peer. Unknown (no snapshot yet, or never
/// seen offline) renders as empty — the UI shows nothing rather than a
/// fake "offline".
String formatPresence(PeerPresence? p, DateTime now) {
  if (p == null) return '';
  if (p.online) return 'в сети';
  final seen = p.lastSeen;
  if (seen == null) return '';
  final diff = now.difference(seen);
  if (diff.isNegative || diff.inSeconds < 60) return 'был(а) недавно';
  if (diff.inMinutes < 60) {
    return 'был(а) ${_plural(diff.inMinutes, 'минуту', 'минуты', 'минут')} назад';
  }
  final dayStart = DateTime(now.year, now.month, now.day);
  if (!seen.isBefore(dayStart)) {
    return 'был(а) ${_plural(diff.inHours, 'час', 'часа', 'часов')} назад';
  }
  final yesterday = dayStart.subtract(const Duration(days: 1));
  if (!seen.isBefore(yesterday)) {
    return 'был(а) вчера в ${_hhmm(seen)}';
  }
  if (diff.inDays < 7) {
    return 'был(а) ${_plural(diff.inDays, 'день', 'дня', 'дней')} назад';
  }
  final m = _months[seen.month - 1];
  final y = seen.year == now.year ? '' : ' ${seen.year}';
  return 'был(а) ${seen.day} $m$y';
}

String _plural(int n, String one, String few, String many) {
  final m10 = n % 10;
  final m100 = n % 100;
  final form = (m10 == 1 && m100 != 11)
      ? one
      : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14))
          ? few
          : many;
  return '$n $form';
}

String _hhmm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

const _months = [
  'янв',
  'фев',
  'мар',
  'апр',
  'мая',
  'июн',
  'июл',
  'авг',
  'сен',
  'окт',
  'ноя',
  'дек'
];
