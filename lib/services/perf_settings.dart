import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

// ── PerfSettings ─────────────────────────────────────────────────────────────
//
// Performance-related settings (Settings > Performance), stored in the Hive
// box 'settings' next to AppSettings, plus a tiny device probe.
//
// Memory: Android can't cap an app's total RAM, so what a "memory profile"
// controls is what the app itself sizes - the mpv playback buffer (read-ahead)
// and its back-buffer. Everything else (Flutter, video decoding) is fixed.
//
// Real seeds: off by default; see live_seeds.dart.

enum MemoryProfile { auto, low, balanced, high, custom }

class PerfSettings {
  PerfSettings._();

  static const String _kProfile = 'perf_memory_profile';
  static const String _kCustomMb = 'perf_custom_buffer_mb';
  static const String _kRealSeeds = 'perf_real_seeds';

  static Box<dynamic>? get _box =>
      Hive.isBoxOpen('settings') ? Hive.box<dynamic>('settings') : null;

  // ── Device probe ───────────────────────────────────────────────────────────

  static int? _totalRamBytes;

  /// Total RAM in bytes (from /proc/meminfo; ~3 GB guess if unreadable).
  static int get totalRamBytes {
    if (_totalRamBytes != null) return _totalRamBytes!;
    var bytes = 3 * 1024 * 1024 * 1024;
    try {
      for (final line in File('/proc/meminfo').readAsLinesSync()) {
        if (line.startsWith('MemTotal:')) {
          final kb = int.parse(RegExp(r'\d+').firstMatch(line)!.group(0)!);
          bytes = kb * 1024;
          break;
        }
      }
    } catch (e) {
      debugPrint('[PerfSettings] could not read /proc/meminfo: $e');
    }
    return _totalRamBytes = bytes;
  }

  static double get totalRamGb => totalRamBytes / (1024 * 1024 * 1024);
  static int get cpuCores => Platform.numberOfProcessors;

  // ── Memory profile ─────────────────────────────────────────────────────────

  static MemoryProfile get profile {
    final name = _box?.get(_kProfile) as String?;
    return MemoryProfile.values.firstWhere(
      (p) => p.name == name,
      orElse: () => MemoryProfile.auto,
    );
  }

  static Future<void> setProfile(MemoryProfile p) async =>
      _box?.put(_kProfile, p.name);

  /// Highest buffer Custom may use: ~1/16 of device RAM, 16-256 MB.
  static int get maxCustomMb =>
      (totalRamBytes ~/ (1024 * 1024) ~/ 16).clamp(16, 256).toInt();

  static int get customBufferMb {
    final v = _box?.get(_kCustomMb);
    final mb = v is int ? v : 64;
    return mb.clamp(16, maxCustomMb).toInt();
  }

  static Future<void> setCustomBufferMb(int mb) async =>
      _box?.put(_kCustomMb, mb.clamp(16, maxCustomMb).toInt());

  /// Playback read-ahead buffer for [p] in MB.
  static int bufferMbFor(MemoryProfile p) {
    switch (p) {
      case MemoryProfile.low:
        return 24;
      case MemoryProfile.balanced:
        return 64; // what the app always used
      case MemoryProfile.high:
        return 128;
      case MemoryProfile.custom:
        return customBufferMb;
      case MemoryProfile.auto:
        final gb = totalRamGb;
        if (gb <= 2.5) return 24;
        if (gb <= 5) return 48;
        if (gb <= 8) return 96;
        return 160;
    }
  }

  /// Back-buffer (already-played data kept for seeking back), MB.
  static int backBufferMbFor(int bufferMb) =>
      (bufferMb ~/ 4).clamp(6, 24).toInt();

  static int get bufferMb => bufferMbFor(profile);
  static int get playerBufferBytes => bufferMb * 1024 * 1024;
  static int get backBufferBytes =>
      backBufferMbFor(bufferMb) * 1024 * 1024;

  // ── Real seeds ─────────────────────────────────────────────────────────────

  static bool get realSeeds => (_box?.get(_kRealSeeds) as bool?) ?? false;

  static Future<void> setRealSeeds(bool v) async => _box?.put(_kRealSeeds, v);
}
