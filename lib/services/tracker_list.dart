import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

// ── TrackerList ──────────────────────────────────────────────────────────────
//
// Trackers rot over months (see the note in stream_service.dart), and on a
// thin swarm every extra reachable tracker means more peers. This keeps a
// fresh copy of ngosang/trackerslist "trackers_best" in the Hive 'settings'
// box (re-downloaded at most once a week, 5 s timeout, silent on failure)
// and merges it with the built-in list, which stays the guaranteed fallback.
//
//   TrackerList.refresh();                  // once at startup, don't await
//   TrackerList.merged(builtInTrackers);    // when building a magnet

class TrackerList {
  TrackerList._();

  static const String _url =
      'https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt';
  static const Duration _maxAge = Duration(days: 7);
  static const int _maxTotal = 24;
  static const String _kList = 'trackers_cache';
  static const String _kAt = 'trackers_cache_at';

  static List<String> _fetched = const [];

  /// Built-in trackers first (known good), then fetched ones, de-duplicated,
  /// capped so a magnet never fans out to dozens of announces.
  static List<String> merged(List<String> builtIn) {
    final seen = <String>{};
    final out = <String>[];
    for (final t in [...builtIn, ..._fetched]) {
      final key = t.toLowerCase().replaceAll(RegExp(r'/+$'), '');
      if (seen.add(key)) out.add(t);
      if (out.length >= _maxTotal) break;
    }
    return out;
  }

  static Future<void> refresh() async {
    try {
      final box = Hive.box('settings');
      final cached = box.get(_kList);
      if (cached is List) _fetched = cached.whereType<String>().toList();

      final at = box.get(_kAt);
      final fresh = at is int &&
          DateTime.now()
                  .difference(DateTime.fromMillisecondsSinceEpoch(at)) <
              _maxAge;
      if (fresh && _fetched.isNotEmpty) return;

      final r = await http.get(Uri.parse(_url)).timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) return;

      // libtorrent speaks udp / http / https trackers - not ws:// / wss://.
      final list = r.body
          .split('\n')
          .map((l) => l.trim())
          .where((l) =>
              l.startsWith('udp://') ||
              l.startsWith('http://') ||
              l.startsWith('https://'))
          .toList();
      if (list.length < 5) return; // clearly not the list we expected

      _fetched = list;
      await box.put(_kList, list);
      await box.put(_kAt, DateTime.now().millisecondsSinceEpoch);
      debugPrint('[TrackerList] refreshed: ${list.length} trackers');
    } catch (e) {
      debugPrint('[TrackerList] refresh skipped: $e');
    }
  }
}
