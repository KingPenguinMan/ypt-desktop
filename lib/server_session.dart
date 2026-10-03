/// Authoritative timer state from reload/info or study/start.
/// Missing fields mean unknown, never implicitly stopped.
class ServerSession {
  final bool running;
  final int? startedAtMs;
  final String? subject;
  const ServerSession(this.running, {this.startedAtMs, this.subject});

  static ServerSession? fromJson(Map<String, dynamic> json) {
    for (final raw in [json['p'], json['dl'], json]) {
      if (raw is! Map || !raw.containsKey('is')) continue;
      final flag = raw['is'];
      if (flag != true && flag != false && flag != 0 && flag != 1) continue;
      return ServerSession(
        flag == true || flag == 1,
        startedAtMs: parseTimestamp(raw['st']),
        subject: raw['sb'] is String ? raw['sb'] as String : null,
      );
    }
    return null;
  }

  static int? parseTimestamp(Object? raw) {
    if (raw is num) {
      final value = raw.toInt();
      return value > 100000000000 ? value : null;
    }
    if (raw is! String) return null;
    final epoch = int.tryParse(raw);
    if (epoch != null) return parseTimestamp(epoch);
    // Do not interpret a timezone-less server timestamp in the PC timezone.
    if (!RegExp(r'(Z|[+-]\d{2}:?\d{2})$').hasMatch(raw)) return null;
    return DateTime.tryParse(raw)?.millisecondsSinceEpoch;
  }
}
