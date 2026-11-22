import 'dart:collection';

/// Process-local memory of which CDN lines recently refused a request.
///
/// A platform's advertised line order is a hint, not evidence: it is the platform's
/// own preference, and it says nothing about whether an edge is reachable from the
/// network this app is on. Measured examples on real networks include an edge whose
/// TLS handshake is refused while the platform keeps it first for every room, and a
/// second and third edge that answer no bytes at all.
///
/// This class records outcomes so ordering can use them:
///
/// * only failures are stored, so a healthy line carries no state;
/// * a later success clears the failure, so a transient outage does not exile a
///   good edge;
/// * an entry expires after [memory], so a line that recovers while the app is
///   running is retried instead of being shunned for the session;
/// * cancellation is *not* a failure — the viewer left, the edge did not fail.
///
/// It is deliberately not persisted. Reachability belongs to the network the app is
/// on right now, and a stored verdict from another Wi-Fi would be worse than none.
class LiveLineHealth {
  LiveLineHealth({this.memory = const Duration(minutes: 10), this.maxEntries = 32});

  /// How long a failure keeps a line demoted.
  final Duration memory;

  /// Upper bound on tracked lines; platforms advertise a handful per room.
  final int maxEntries;

  final LinkedHashMap<String, DateTime> _failedAt = LinkedHashMap<String, DateTime>();

  /// Whether [line] refused a request recently enough to be demoted.
  bool recentlyFailed(String line, {DateTime? now}) {
    final failedAt = _failedAt[_key(line)];
    if (failedAt == null) return false;
    final at = now ?? DateTime.now();
    return at.difference(failedAt) < memory;
  }

  void recordFailure(String line, {DateTime? at}) {
    final key = _key(line);
    if (key.isEmpty) return;
    _failedAt.remove(key);
    _failedAt[key] = at ?? DateTime.now();
    while (_failedAt.length > maxEntries) {
      _failedAt.remove(_failedAt.keys.first);
    }
  }

  void recordSuccess(String line) => _failedAt.remove(_key(line));

  void clear() => _failedAt.clear();

  /// Orders [lines] by observed health, then by the caller's own preference.
  ///
  /// [rank] supplies the caller's static preference (lower is better) and [key]
  /// extracts the stable identity used for the health lookup. Stable sort keeps the
  /// caller's order inside each health bucket, so a platform's own priority still
  /// decides between two equally healthy lines.
  List<T> order<T>(
    Iterable<T> lines, {
    required String Function(T line) key,
    int Function(T line)? rank,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    final indexed = <({int index, T line, int failed, int rank})>[
      for (final (index, line) in lines.indexed)
        (index: index, line: line, failed: recentlyFailed(key(line), now: at) ? 1 : 0, rank: rank?.call(line) ?? 0),
    ];
    indexed.sort((left, right) {
      final byFailure = left.failed.compareTo(right.failed);
      if (byFailure != 0) return byFailure;
      final byRank = left.rank.compareTo(right.rank);
      return byRank != 0 ? byRank : left.index.compareTo(right.index);
    });
    return <T>[for (final entry in indexed) entry.line];
  }

  static String _key(String line) => line.trim().toLowerCase();
}
