import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../models/media_model.dart';
import 'perf_settings.dart';
import 'tracker_list.dart';

// ── LiveSeeds ────────────────────────────────────────────────────────────────
//
// Optional "real seeds" (Settings > Performance, OFF by default): instead of
// trusting the seed count Torrentio prints, ask UDP trackers directly how many
// seeders / leechers they know for each info-hash (BEP 15 "scrape"). A scrape
// does not join the swarm; one packet covers up to 70 hashes, so a whole
// source list refreshes in 1-2 s.
//
//   • The count shown/used is the MAX across trackers (never the sum - the
//     same seed is usually registered with several trackers).
//   • Swarms that live only on DHT can legitimately report 0 here.
//   • Trackers see your IP and the hashes you scrape (same as announcing).
//   • Only UDP trackers are scraped; http(s) trackers are skipped.

class LiveCount {
  final int seeds;
  final int peers; // leechers
  final DateTime at;
  const LiveCount(this.seeds, this.peers, this.at);
}

class LiveSeeds {
  LiveSeeds._();

  static final Map<String, LiveCount> _counts = {};

  /// Bumped whenever counts change - listen to rebuild the UI.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static const int _maxTrackers = 6;
  static const int _batch = 70;
  static const Duration _ttl = Duration(minutes: 5);
  static const Duration _timeout = Duration(milliseconds: 2500);

  // Reliable UDP trackers; TrackerList's fresh list is appended after them.
  static const List<String> _builtIn = [
    'udp://tracker.opentrackr.org:1337/announce',
    'udp://open.stealth.si:80/announce',
    'udp://tracker.torrent.eu.org:451/announce',
    'udp://exodus.desync.com:6969/announce',
    'udp://explodie.org:6969/announce',
    'udp://tracker.theoks.net:6969/announce',
  ];

  static LiveCount? of(TorrentStream s) =>
      PerfSettings.realSeeds ? _counts[s.infoHash.toLowerCase()] : null;

  static bool hasLive(TorrentStream s) => of(s) != null;

  /// Live seeders when available (and enabled), else Torrentio's number.
  static int? seedsFor(TorrentStream s) => of(s)?.seeds ?? s.seeds;

  /// Scrape [infoHashes] (40-char hex). No-op when the setting is off.
  static Future<void> scrape(Iterable<String> infoHashes) async {
    if (!PerfSettings.realSeeds) return;
    final now = DateTime.now();
    final hashes = infoHashes
        .map((h) => h.toLowerCase())
        .where((h) => RegExp(r'^[0-9a-f]{40}$').hasMatch(h))
        .where((h) {
          final c = _counts[h];
          return c == null || now.difference(c.at) > _ttl;
        })
        .toSet()
        .toList();
    if (hashes.isEmpty) return;

    final trackers = TrackerList.merged(_builtIn)
        .where((t) => t.startsWith('udp://'))
        .take(_maxTrackers)
        .toList();

    await Future.wait(trackers.map((t) async {
      for (var i = 0; i < hashes.length; i += _batch) {
        final chunk = hashes.sublist(
            i, i + _batch > hashes.length ? hashes.length : i + _batch);
        final res = await _scrapeUdp(t, chunk);
        if (res.isNotEmpty) _merge(res);
      }
    }));
  }

  static void _merge(Map<String, LiveCount> res) {
    var changed = false;
    res.forEach((h, c) {
      final old = _counts[h];
      // MAX across trackers within one scrape round; fresh round replaces
      // stale data.
      if (old == null ||
          c.at.difference(old.at) > const Duration(seconds: 30) ||
          c.seeds > old.seeds) {
        _counts[h] = LiveCount(
          c.seeds,
          old != null && c.at.difference(old.at) <= const Duration(seconds: 30)
              ? (c.peers > old.peers ? c.peers : old.peers)
              : c.peers,
          c.at,
        );
        changed = true;
      }
    });
    if (changed) revision.value++;
  }

  // ── BEP 15 (UDP tracker) ───────────────────────────────────────────────────

  static Future<Map<String, LiveCount>> _scrapeUdp(
      String trackerUrl, List<String> hashes) async {
    RawDatagramSocket? socket;
    try {
      final uri = Uri.parse(trackerUrl);
      final addrs = await InternetAddress.lookup(uri.host,
          type: InternetAddressType.IPv4);
      if (addrs.isEmpty) return {};
      final addr = addrs.first;
      final port = uri.port;

      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      // Tiny packet queue (a single-subscription stream can't be awaited
      // twice, and a broadcast one can drop an early reply).
      final queue = <Uint8List>[];
      Completer<void>? waiter;
      final sub = socket.listen((e) {
        if (e == RawSocketEvent.read) {
          final d = socket!.receive();
          if (d != null) {
            queue.add(d.data);
            if (waiter != null && !waiter!.isCompleted) waiter!.complete();
          }
        }
      });

      Future<Uint8List?> next() async {
        if (queue.isEmpty) {
          waiter = Completer<void>();
          try {
            await waiter!.future.timeout(_timeout);
          } catch (_) {
            return null;
          }
        }
        return queue.isEmpty ? null : queue.removeAt(0);
      }

      // 1. connect
      final tid1 = DateTime.now().microsecondsSinceEpoch & 0x7fffffff;
      final conn = ByteData(16)
        ..setUint32(0, 0x417)
        ..setUint32(4, 0x27101980)
        ..setUint32(8, 0) // action: connect
        ..setUint32(12, tid1);
      socket.send(conn.buffer.asUint8List(), addr, port);
      final r1 = await next();
      if (r1 == null || r1.length < 16) {
        await sub.cancel();
        return {};
      }
      final b1 = ByteData.sublistView(r1);
      if (b1.getUint32(0) != 0 || b1.getUint32(4) != tid1) {
        await sub.cancel();
        return {};
      }
      final connectionId = r1.sublist(8, 16);

      // 2. scrape
      final tid2 = (tid1 + 1) & 0x7fffffff;
      final req = BytesBuilder();
      req.add(connectionId);
      final hdr = ByteData(8)
        ..setUint32(0, 2) // action: scrape
        ..setUint32(4, tid2);
      req.add(hdr.buffer.asUint8List());
      for (final h in hashes) {
        req.add(_hexToBytes(h));
      }
      socket.send(req.toBytes(), addr, port);
      final r2 = await next();
      await sub.cancel();
      if (r2 == null || r2.length < 8 + 12) return {};
      final b2 = ByteData.sublistView(r2);
      if (b2.getUint32(0) != 2 || b2.getUint32(4) != tid2) return {};

      final out = <String, LiveCount>{};
      final now = DateTime.now();
      final n = ((r2.length - 8) ~/ 12).clamp(0, hashes.length).toInt();
      for (var i = 0; i < n; i++) {
        final o = 8 + i * 12;
        out[hashes[i]] =
            LiveCount(b2.getUint32(o), b2.getUint32(o + 8), now);
      }
      return out;
    } catch (e) {
      debugPrint('[LiveSeeds] scrape $trackerUrl failed: $e');
      return {};
    } finally {
      socket?.close();
    }
  }

  static Uint8List _hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
