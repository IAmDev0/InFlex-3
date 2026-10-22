import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:intorrent/intorrent.dart' as intorrent;
import 'package:path_provider/path_provider.dart';

import '../constants/app_constants.dart';
import '../models/download_item.dart';
import '../models/media_model.dart';
import 'app_settings.dart';
import 'gallery_saver.dart';

// ── DownloadService ───────────────────────────────────────────────────────────
//
// Manages permanent movie and series downloads on the device:
//
//   • In-App Permanent Library: stored under <app documents>/InFlex/Downloads/
//     with locally cached posters so movies and episodes play offline with zero
//     internet connection, full audio-track switching, subtitles & resume.
//   • Save to Gallery: optionally exports automatically on completion or on
//     demand at any time into Android's public Movies/InFlex Gallery album via
//     MediaStore (zero permissions required on Android 10+).
//
// Uses its own InTorrent handle ids directly (separate from TorrentEngine), so
// background downloads never interrupt watching a live stream and vice versa.

const Set<String> _videoExtensions = {
  '.mp4',
  '.mkv',
  '.avi',
  '.mov',
  '.webm',
  '.m4v',
  '.ts',
  '.wmv',
  '.flv',
  '.m2ts',
};

class DownloadLiveMetrics {
  final double speedMbs;
  final int peers;
  final int seeds;
  final int? etaSeconds;
  final String phase;
  final bool exportingToGallery;

  const DownloadLiveMetrics({
    this.speedMbs = 0,
    this.peers = 0,
    this.seeds = 0,
    this.etaSeconds,
    this.phase = '',
    this.exportingToGallery = false,
  });

  String? get etaLabel {
    final s = etaSeconds;
    if (s == null || s <= 0) return null;
    if (s >= 3600) {
      final h = s ~/ 3600;
      final m = (s % 3600) ~/ 60;
      return '${h}h ${m}m left';
    }
    if (s >= 60) {
      return '${s ~/ 60}m left';
    }
    return '${s}s left';
  }
}

class DownloadService extends ChangeNotifier {
  static final DownloadService _instance = DownloadService._internal();
  factory DownloadService() => _instance;
  DownloadService._internal();

  static const String boxName = 'downloads';
  static const int _maxChunkBytes = 4 * 1024 * 1024; // 4 MiB verified slices
  static const Duration _metadataTimeout = Duration(seconds: 60);

  final Map<String, DownloadLiveMetrics> _live = {};
  final Set<String> _galleryBusy = {};

  String? _activeDownloadId;
  int? _activeTorrentId;
  String? _stopReason; // 'pause' | 'cancel' | null
  bool _initialized = false;
  int? _freeDiskBytes;

  Box<dynamic>? get _box =>
      Hive.isBoxOpen(boxName) ? Hive.box<dynamic>(boxName) : null;

  int? get freeDiskBytes => _freeDiskBytes;

  DownloadLiveMetrics? liveMetricsFor(String id) => _live[id];

  bool isExportingToGallery(String id) => _galleryBusy.contains(id);

  /// Stable key for one movie or one specific series episode.
  static String buildId(
    int tmdbId,
    String mediaType, {
    int? season,
    int? episode,
  }) {
    if (mediaType == 'tv') {
      return 'tv_${tmdbId}_${season ?? 0}_${episode ?? 0}';
    }
    return 'movie_${tmdbId}_0_0';
  }

  /// All downloads sorted active-first, then newest-first.
  List<DownloadItem> get items {
    final box = _box;
    if (box == null) return const [];
    final parsed = <DownloadItem>[];
    for (final raw in box.values) {
      if (raw is! String) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          parsed.add(DownloadItem.fromJson(decoded));
        }
      } catch (_) {}
    }
    parsed.sort((a, b) {
      final aRank = _statusSortRank(a.status);
      final bRank = _statusSortRank(b.status);
      if (aRank != bRank) return aRank.compareTo(bRank);
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return parsed;
  }

  static int _statusSortRank(String status) {
    switch (status) {
      case 'downloading':
        return 0;
      case 'queued':
        return 1;
      case 'paused':
        return 2;
      case 'failed':
        return 3;
      default:
        return 4;
    }
  }

  int get activeCount => items.where((d) => d.isActive).length;

  int get completedCount => items.where((d) => d.isComplete).length;

  int get totalSavedBytes {
    var sum = 0;
    for (final item in items) {
      if (item.isComplete) {
        sum += item.downloadedBytes > 0
            ? item.downloadedBytes
            : item.effectiveTotalBytes;
      } else {
        sum += item.downloadedBytes;
      }
    }
    return sum;
  }

  DownloadItem? getById(String id) {
    final box = _box;
    if (box == null) return null;
    final raw = box.get(id);
    if (raw is! String) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return DownloadItem.fromJson(decoded);
      }
    } catch (_) {}
    return null;
  }

  DownloadItem? findForMedia(
    int tmdbId,
    String mediaType, {
    int? season,
    int? episode,
  }) =>
      getById(buildId(tmdbId, mediaType, season: season, episode: episode));

  /// All downloads belonging to a TV series, ordered by season then episode.
  List<DownloadItem> episodesForShow(int tmdbId) {
    final eps =
        items.where((d) => d.isSeries && d.tmdbId == tmdbId).toList();
    eps.sort((a, b) {
      final s = (a.season ?? 0).compareTo(b.season ?? 0);
      if (s != 0) return s;
      return (a.episode ?? 0).compareTo(b.episode ?? 0);
    });
    return eps;
  }

  /// Next completed offline episode after [current] in the same TV show.
  DownloadItem? nextCompletedEpisode(DownloadItem current) {
    if (!current.isSeries) return null;
    final eps = episodesForShow(current.tmdbId)
        .where((e) => e.isComplete)
        .toList();
    for (final ep in eps) {
      final curS = current.season ?? 0;
      final curE = current.episode ?? 0;
      final epS = ep.season ?? 0;
      final epE = ep.episode ?? 0;
      if (epS > curS || (epS == curS && epE > curE)) {
        return ep;
      }
    }
    return null;
  }

  /// Initializes download state after Hive boxes open on startup.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    final box = _box;
    if (box == null) return;

    for (final item in items) {
      if (item.status == 'downloading') {
        final partFile = File('${item.filePath}.part');
        var savedBytes = item.downloadedBytes;
        if (await partFile.exists()) {
          savedBytes = await partFile.length();
        }
        await _save(item.copyWith(
          status: 'paused',
          downloadedBytes: savedBytes,
          updatedAt: DateTime.now(),
        ));
      } else if (item.isComplete) {
        final finalFile = File(item.filePath);
        if (!await finalFile.exists()) {
          await box.delete(item.id);
        }
      }
    }

    await refreshDiskSpace();
    notifyListeners();
    _pumpQueue();
  }

  Future<void> refreshDiskSpace() async {
    try {
      final dir = await _downloadsDir();
      _freeDiskBytes = await GallerySaver.freeDiskBytes(dir.path);
      notifyListeners();
    } catch (_) {}
  }

  // ── Directory & naming helpers ─────────────────────────────────────────────

  Future<Directory> _downloadsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/InFlex/Downloads');
    await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _postersDir() async {
    final base = await _downloadsDir();
    final dir = Directory('${base.path}/posters');
    await dir.create(recursive: true);
    return dir;
  }

  String _extFromName(String? fileName, {String fallback = '.mp4'}) {
    if (fileName == null || fileName.isEmpty) return fallback;
    final dot = fileName.lastIndexOf('.');
    if (dot < 0) return fallback;
    final ext = fileName.substring(dot).toLowerCase();
    return _videoExtensions.contains(ext) ? ext : fallback;
  }

  String _buildSafeFileName({
    required String title,
    int? season,
    int? episode,
    required String quality,
    required String ext,
  }) {
    final cleanTitle = title
        .replaceAll(RegExp(r'[^a-zA-Z0-9 ]'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    final parts = <String>[cleanTitle.isEmpty ? 'InFlex_Video' : cleanTitle];
    if (season != null && episode != null) {
      final s = season.toString().padLeft(2, '0');
      final e = episode.toString().padLeft(2, '0');
      parts.add('S${s}E$e');
    }
    final cleanQuality =
        quality.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').trim();
    if (cleanQuality.isNotEmpty) {
      parts.add(cleanQuality);
    }
    return '${parts.join('_')}$ext';
  }

  Future<String?> _cachePosterLocally(int tmdbId, String? posterPath) async {
    if (posterPath == null || posterPath.isEmpty) return null;
    try {
      final posters = await _postersDir();
      final target = File('${posters.path}/$tmdbId.jpg');
      if (await target.exists() && await target.length() > 0) {
        return target.path;
      }
      final response = await http
          .get(Uri.parse(AppConstants.poster(posterPath)))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        await target.writeAsBytes(response.bodyBytes, flush: true);
        return target.path;
      }
    } catch (_) {}
    return null;
  }

  // ── Public actions ─────────────────────────────────────────────────────────

  /// Enqueues a movie or episode for permanent download.
  ///
  /// When [saveToGallery] is true (or `AppSettings.autoSaveToGallery` is on),
  /// the video is also automatically exported to the device's Gallery
  /// (`Movies/InFlex`) as soon as it finishes downloading.
  Future<DownloadItem> enqueue({
    required TorrentStream stream,
    required MediaItem item,
    String? imdbId,
    int? season,
    int? episode,
    String? episodeTitle,
    required String quality,
    bool saveToGallery = false,
  }) async {
    final box = _box;
    if (box == null) {
      throw StateError('Downloads storage is not available');
    }

    final id = buildId(
      item.id,
      item.mediaType,
      season: item.mediaType == 'tv' ? season : null,
      episode: item.mediaType == 'tv' ? episode : null,
    );

    final shouldSaveToGallery = saveToGallery || AppSettings.autoSaveToGallery;
    final existing = getById(id);

    // Already completed on disk -> optionally export straight to Gallery now.
    if (existing != null &&
        existing.isComplete &&
        await File(existing.filePath).exists()) {
      if (shouldSaveToGallery && !existing.savedToGallery) {
        unawaited(this.saveToGallery(existing.id));
      }
      return existing;
    }

    // Already active -> update Gallery flag if newly requested and return.
    if (existing != null && existing.isActive) {
      final updated = existing.copyWith(
        saveToGalleryOnComplete:
            existing.saveToGalleryOnComplete || shouldSaveToGallery,
        updatedAt: DateTime.now(),
      );
      await _save(updated);
      notifyListeners();
      return updated;
    }

    // Remove stale partial data if replacing a failed download from a new source.
    if (existing != null && existing.infoHash != stream.infoHash) {
      final oldPart = File('${existing.filePath}.part');
      if (await oldPart.exists()) {
        try {
          await oldPart.delete();
        } catch (_) {}
      }
    }

    final initialExt = _extFromName(
      stream.fileName ?? stream.title,
      fallback: stream.title.toLowerCase().contains('mkv') ||
              stream.info.codec == 'HEVC'
          ? '.mkv'
          : '.mp4',
    );
    final fileName = _buildSafeFileName(
      title: item.title,
      season: item.mediaType == 'tv' ? season : null,
      episode: item.mediaType == 'tv' ? episode : null,
      quality: quality,
      ext: initialExt,
    );
    final dir = await _downloadsDir();
    final filePath = '${dir.path}/$fileName';
    final partFile = File('$filePath.part');
    final existingBytes =
        await partFile.exists() ? await partFile.length() : 0;

    final now = DateTime.now();
    final record = DownloadItem(
      id: id,
      tmdbId: item.id,
      mediaType: item.mediaType,
      title: item.title,
      posterPath: item.posterPath,
      localPosterPath: existing?.localPosterPath,
      backdropPath: item.backdropPath,
      imdbId: imdbId ?? existing?.imdbId,
      season: item.mediaType == 'tv' ? season : null,
      episode: item.mediaType == 'tv' ? episode : null,
      episodeTitle: episodeTitle ?? existing?.episodeTitle,
      quality: quality,
      filePath: filePath,
      fileName: fileName,
      totalBytes: existing?.totalBytes ?? (stream.sizeBytes ?? 0),
      downloadedBytes: existingBytes,
      status: 'queued',
      saveToGalleryOnComplete: shouldSaveToGallery,
      savedToGallery: false,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      magnetLink:
          stream.magnetLink ?? 'magnet:?xt=urn:btih:${stream.infoHash}',
      infoHash: stream.infoHash,
      fileIdx: stream.isPackFallback ? null : stream.fileIdx,
      fileNameHint: stream.isPackFallback ? null : stream.fileName,
      sizeBytes: stream.sizeBytes,
    );

    await _save(record);
    notifyListeners();

    // Cache poster locally in the background so offline mode always shows art.
    unawaited(_cachePosterAndAttach(id, item.id, item.posterPath));

    _pumpQueue();
    return record;
  }

  Future<void> _cachePosterAndAttach(
    String id,
    int tmdbId,
    String? posterPath,
  ) async {
    final localPath = await _cachePosterLocally(tmdbId, posterPath);
    if (localPath == null) return;
    final current = getById(id);
    if (current == null) return;
    await _save(current.copyWith(localPosterPath: localPath));
    notifyListeners();
  }

  /// Pauses the active or queued download while keeping all verified bytes on disk.
  Future<void> pause(String id) async {
    final item = getById(id);
    if (item == null) return;

    if (_activeDownloadId == id) {
      _stopReason = 'pause';
      final tid = _activeTorrentId;
      if (tid != null) {
        try {
          await intorrent.remove(tid);
        } catch (_) {}
      }
      return;
    }

    if (item.isQueued) {
      await _save(item.copyWith(status: 'paused', updatedAt: DateTime.now()));
      _live.remove(id);
      notifyListeners();
    }
  }

  /// Resumes a paused or failed download from the exact verified byte on disk.
  Future<void> resume(String id) async {
    final item = getById(id);
    if (item == null || item.isComplete || item.isActive) return;

    await _save(item.copyWith(
      status: 'queued',
      clearError: true,
      updatedAt: DateTime.now(),
    ));
    notifyListeners();
    _pumpQueue();
  }

  /// Moves [id] to the front of the queue (pausing whatever else is running).
  Future<void> startNow(String id) async {
    final target = getById(id);
    if (target == null || target.isComplete) return;

    if (_activeDownloadId != null && _activeDownloadId != id) {
      await pause(_activeDownloadId!);
      // Give the active loop a brief tick to settle before starting next.
      await Future.delayed(const Duration(milliseconds: 120));
    }

    final refreshed = getById(id);
    if (refreshed == null) return;
    await _save(refreshed.copyWith(
      status: 'queued',
      clearError: true,
      updatedAt: DateTime.now(),
    ));
    notifyListeners();
    _pumpQueue(preferId: id);
  }

  /// Cancels / deletes a download permanently from app storage.
  Future<void> delete(String id) async {
    final item = getById(id);

    if (_activeDownloadId == id) {
      _stopReason = 'cancel';
      final tid = _activeTorrentId;
      if (tid != null) {
        try {
          await intorrent.remove(tid);
        } catch (_) {}
      }
    }

    _live.remove(id);
    await _box?.delete(id);

    if (item != null) {
      for (final p in [item.filePath, '${item.filePath}.part']) {
        final f = File(p);
        if (await f.exists()) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    }

    await refreshDiskSpace();
    notifyListeners();
    _pumpQueue();
  }

  /// Copies a completed download into the device's Gallery (`Movies/InFlex`).
  Future<GallerySaveResult> saveToGallery(String id) async {
    final item = getById(id);
    if (item == null || !item.isComplete) {
      return const GallerySaveResult(
        ok: false,
        error: 'Download is not complete yet',
      );
    }
    if (_galleryBusy.contains(id)) {
      return const GallerySaveResult(
        ok: false,
        error: 'Already saving this video to Gallery',
      );
    }

    _galleryBusy.add(id);
    _live[id] = const DownloadLiveMetrics(
      phase: 'Saving to Gallery...',
      exportingToGallery: true,
    );
    notifyListeners();

    try {
      final result = await GallerySaver.saveVideo(
        filePath: item.filePath,
        displayName: item.fileName,
      );
      if (result.ok) {
        final latest = getById(id);
        if (latest != null) {
          await _save(latest.copyWith(
            savedToGallery: true,
            galleryLocation: result.location ?? 'Movies/InFlex/${item.fileName}',
            updatedAt: DateTime.now(),
          ));
        }
      }
      await refreshDiskSpace();
      return result;
    } finally {
      _galleryBusy.remove(id);
      _live.remove(id);
      notifyListeners();
    }
  }

  // ── Queue runner ───────────────────────────────────────────────────────────

  void _pumpQueue({String? preferId}) {
    if (_activeDownloadId != null) return;

    DownloadItem? next;
    if (preferId != null) {
      final preferred = getById(preferId);
      if (preferred != null && preferred.status == 'queued') {
        next = preferred;
      }
    }
    if (next == null) {
      final queued = items.where((d) => d.status == 'queued').toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      if (queued.isNotEmpty) {
        next = queued.first;
      }
    }
    if (next == null) return;

    unawaited(_executeDownload(next.id));
  }

  Future<void> _executeDownload(String id) async {
    if (_activeDownloadId != null) return;
    final initial = getById(id);
    if (initial == null || initial.magnetLink == null) return;

    _activeDownloadId = id;
    _activeTorrentId = null;
    _stopReason = null;

    await _save(initial.copyWith(
      status: 'downloading',
      clearError: true,
      updatedAt: DateTime.now(),
    ));
    _live[id] = const DownloadLiveMetrics(phase: 'Connecting to peers...');
    notifyListeners();

    int? torrentId;
    final httpClient = HttpClient()
      ..idleTimeout = const Duration(seconds: 30)
      ..connectionTimeout = const Duration(seconds: 15);
    IOSink? partSink;

    try {
      torrentId = await intorrent.addMagnet(initial.magnetLink!);
      _activeTorrentId = torrentId;

      // ── Step 1: Resolve torrent metadata ───────────────────────────────────
      final metaDeadline = DateTime.now().add(_metadataTimeout);
      var metaReady = false;
      while (_stopReason == null && DateTime.now().isBefore(metaDeadline)) {
        final st = await intorrent.getStatus(torrentId);
        _live[id] = DownloadLiveMetrics(
          peers: st.numPeers,
          seeds: st.numSeeds,
          phase: st.numPeers > 0
              ? 'Fetching metadata (${st.numPeers} peers)...'
              : 'Finding peers via DHT...',
        );
        notifyListeners();

        if (st.state != intorrent.TorrentState.queued &&
            st.state != intorrent.TorrentState.checking &&
            st.state != intorrent.TorrentState.downloadingMetadata) {
          metaReady = true;
          break;
        }
        await Future.delayed(const Duration(milliseconds: 600));
      }

      if (_stopReason != null) {
        await _handleInterrupted(id, initial.downloadedBytes);
        return;
      }
      if (!metaReady) {
        throw StateError(
          'No peers found after 60s. Check your network or choose a source with more seeds.',
        );
      }

      // ── Step 2: Pick exact video file & update true extension / size ───────
      final files = await intorrent.listFiles(torrentId);
      final fileIndex = _pickVideoFile(files, initial);
      intorrent.TorrentFile? picked;
      for (final f in files) {
        if (f.index == fileIndex) {
          picked = f;
          break;
        }
      }
      if (picked == null || picked.size <= 0) {
        throw StateError('Selected torrent contains no valid video file');
      }

      final current = getById(id) ?? initial;
      final realExt = _extFromName(picked.name, fallback: '.mkv');
      final resolvedFileName = _buildSafeFileName(
        title: current.title,
        season: current.season,
        episode: current.episode,
        quality: current.quality,
        ext: realExt,
      );
      final dir = await _downloadsDir();
      final resolvedFilePath = '${dir.path}/$resolvedFileName';

      // Preserve any existing partial file if the predicted extension changed.
      final oldPart = File('${current.filePath}.part');
      final newPart = File('$resolvedFilePath.part');
      if (oldPart.path != newPart.path && await oldPart.exists()) {
        if (!await newPart.exists()) {
          await oldPart.rename(newPart.path);
        }
      }

      var written = await newPart.exists() ? await newPart.length() : 0;
      final totalBytes = picked.size;
      if (written > totalBytes) {
        // Corrupted partial from a different source size -> reset cleanly.
        await newPart.delete();
        written = 0;
      }

      await _save(current.copyWith(
        fileName: resolvedFileName,
        filePath: resolvedFilePath,
        totalBytes: totalBytes,
        downloadedBytes: written,
        updatedAt: DateTime.now(),
      ));
      notifyListeners();

      // ── Step 3: Start sequential unthrottled prefetch + local stream ───────
      final streamUri = await intorrent.streamUrl(torrentId, fileIndex);
      if (written < totalBytes) {
        await intorrent.startPrefetch(
          torrentId,
          fileIndex,
          startByte: written,
          lengthBytes: totalBytes - written,
        );
      }

      partSink = newPart.openWrite(
        mode: written == 0 ? FileMode.write : FileMode.writeOnlyAppend,
      );

      double emaBps = 0;
      int lastSpeedBytes = written;
      DateTime lastSpeedAt = DateTime.now();
      DateTime lastPersistAt = DateTime.now();

      // ── Step 4: Copy verified contiguous pieces straight to permanent disk ─
      while (_stopReason == null && written < totalBytes) {
        final remaining = totalBytes - written;
        final ask = remaining < _maxChunkBytes ? remaining : _maxChunkBytes;
        final ready = await intorrent.availableBytes(
          torrentId,
          fileIndex,
          written,
          ask,
        );

        final status = await intorrent.getStatus(torrentId);

        if (ready <= 0) {
          final now = DateTime.now();
          final dt = now.difference(lastSpeedAt).inMilliseconds / 1000.0;
          if (dt >= 2.0) {
            emaBps *= 0.7;
            lastSpeedAt = now;
          }
          final speedMbs = emaBps / (1024 * 1024);
          _live[id] = DownloadLiveMetrics(
            speedMbs: speedMbs,
            peers: status.numPeers,
            seeds: status.numSeeds,
            etaSeconds: emaBps > 1024 ? ((totalBytes - written) ~/ emaBps) : null,
            phase: status.numPeers == 0 ? 'Waiting for peers...' : 'Downloading',
          );
          notifyListeners();
          await Future.delayed(const Duration(milliseconds: 250));
          continue;
        }

        // Read the exact verified byte slice [written .. written + ready - 1].
        final chunkEnd = written + ready - 1;
        final req = await httpClient.getUrl(streamUri);
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$written-$chunkEnd');
        final res = await req.close();
        if (res.statusCode != HttpStatus.partialContent &&
            res.statusCode != HttpStatus.ok) {
          await res.drain<void>();
          throw HttpException('Local stream returned HTTP ${res.statusCode}');
        }

        var got = 0;
        await for (final data in res) {
          partSink.add(data);
          got += data.length;
        }
        await partSink.flush();
        written += got;

        final now = DateTime.now();
        final dt = now.difference(lastSpeedAt).inMilliseconds / 1000.0;
        if (dt >= 0.4) {
          final delta = written - lastSpeedBytes;
          if (delta >= 0 && dt > 0) {
            final instBps = delta / dt;
            emaBps = emaBps == 0 ? instBps : (emaBps * 0.65 + instBps * 0.35);
          }
          lastSpeedBytes = written;
          lastSpeedAt = now;
        }

        final speedMbs = emaBps / (1024 * 1024);
        _live[id] = DownloadLiveMetrics(
          speedMbs: speedMbs,
          peers: status.numPeers,
          seeds: status.numSeeds,
          etaSeconds: emaBps > 1024 ? ((totalBytes - written) ~/ emaBps) : null,
          phase: 'Downloading',
        );

        if (now.difference(lastPersistAt).inMilliseconds >= 500 ||
            written >= totalBytes) {
          lastPersistAt = now;
          final snap = getById(id);
          if (snap != null) {
            await _save(snap.copyWith(
              downloadedBytes: written,
              totalBytes: totalBytes,
              updatedAt: now,
            ));
          }
        }
        notifyListeners();
      }

      await partSink.flush();
      await partSink.close();
      partSink = null;

      if (_stopReason != null) {
        await _handleInterrupted(id, written);
        return;
      }

      // ── Step 5: Finalize permanent file + optional Gallery export ──────────
      final finalFile = File(resolvedFilePath);
      if (await finalFile.exists()) {
        await finalFile.delete();
      }
      await newPart.rename(resolvedFilePath);

      // Immediately clean up temporary libtorrent pieces to free space!
      try {
        await intorrent.remove(torrentId);
      } catch (_) {}
      torrentId = null;
      _activeTorrentId = null;

      final doneSnapshot = getById(id);
      if (doneSnapshot != null) {
        final completedRecord = doneSnapshot.copyWith(
          status: 'completed',
          downloadedBytes: totalBytes,
          totalBytes: totalBytes,
          clearError: true,
          updatedAt: DateTime.now(),
        );
        await _save(completedRecord);
        _live.remove(id);
        notifyListeners();

        if (completedRecord.saveToGalleryOnComplete ||
            AppSettings.autoSaveToGallery) {
          await saveToGallery(id);
        }
      }
    } catch (e) {
      try {
        await partSink?.flush();
        await partSink?.close();
      } catch (_) {}
      partSink = null;

      if (_stopReason != null) {
        final snap = getById(id);
        final partFile = snap != null ? File('${snap.filePath}.part') : null;
        final saved = (partFile != null && await partFile.exists())
            ? await partFile.length()
            : (snap?.downloadedBytes ?? 0);
        await _handleInterrupted(id, saved);
        return;
      }

      debugPrint('[DownloadService] download failed ($id): $e');
      final snap = getById(id);
      if (snap != null) {
        final partFile = File('${snap.filePath}.part');
        final saved = await partFile.exists()
            ? await partFile.length()
            : snap.downloadedBytes;
        await _save(snap.copyWith(
          status: 'failed',
          downloadedBytes: saved,
          error: '$e'.replaceFirst('Bad state: ', ''),
          updatedAt: DateTime.now(),
        ));
      }
      _live.remove(id);
    } finally {
      try {
        await partSink?.close();
      } catch (_) {}
      httpClient.close(force: true);
      if (torrentId != null) {
        try {
          await intorrent.remove(torrentId);
        } catch (_) {}
      }
      _activeTorrentId = null;
      _activeDownloadId = null;
      _stopReason = null;
      await refreshDiskSpace();
      notifyListeners();
      _pumpQueue();
    }
  }

  Future<void> _handleInterrupted(String id, int savedBytes) async {
    _live.remove(id);
    if (_stopReason == 'pause') {
      final snap = getById(id);
      if (snap != null) {
        await _save(snap.copyWith(
          status: 'paused',
          downloadedBytes: savedBytes,
          updatedAt: DateTime.now(),
        ));
      }
    }
    notifyListeners();
  }

  Future<void> _save(DownloadItem item) async {
    await _box?.put(item.id, jsonEncode(item.toJson()));
  }

  // ── Multi-file season pack picker (mirrors TorrentEngine._pickVideoFile) ──

  int _pickVideoFile(List<intorrent.TorrentFile> files, DownloadItem hint) {
    final videos = files.where(_isVideoFile).toList();
    if (videos.isEmpty) {
      intorrent.TorrentFile? largest;
      for (final f in files) {
        if (largest == null || f.size > largest.size) largest = f;
      }
      return largest?.index ?? 0;
    }

    intorrent.TorrentFile largestVideo = videos.first;
    for (final f in videos) {
      if (f.size > largestVideo.size) largestVideo = f;
    }

    // 1. Exact file name hint
    final wantedName = _baseName(hint.fileNameHint);
    if (wantedName != null) {
      for (final f in videos) {
        if (_baseName(f.name) == wantedName) {
          return f.index;
        }
      }
    }

    // 2. Season / episode match in filename
    final season = hint.season;
    final episode = hint.episode;
    if (season != null && episode != null) {
      final matches = <intorrent.TorrentFile>[];
      for (final f in videos) {
        if (_matchesEpisode(f.name, season, episode)) {
          matches.add(f);
        }
      }
      if (matches.length == 1) {
        return matches.first.index;
      }
      if (matches.length > 1) {
        for (final f in matches) {
          if (f.index == hint.fileIdx) return f.index;
        }
        matches.sort((a, b) => b.size.compareTo(a.size));
        return matches.first.index;
      }
    }

    // 3. Torrentio's explicit file index
    final idx = hint.fileIdx;
    if (idx != null) {
      for (final f in videos) {
        if (f.index != idx) continue;
        final tiny = f.size < largestVideo.size ~/ 10;
        final otherEpisode = season != null &&
            episode != null &&
            _hasOtherEpisode(f.name, season, episode);
        if (!tiny && !otherEpisode) {
          return f.index;
        }
      }
    }

    // 4. Largest video file
    return largestVideo.index;
  }

  static bool _isVideoFile(intorrent.TorrentFile f) {
    final dot = f.name.lastIndexOf('.');
    final ext = dot >= 0 ? f.name.substring(dot).toLowerCase() : '';
    return _videoExtensions.contains(ext);
  }

  static String? _baseName(String? path) {
    if (path == null) return null;
    final cut = path.lastIndexOf(RegExp(r'[\\/]'));
    final name =
        (cut >= 0 ? path.substring(cut + 1) : path).trim().toLowerCase();
    return name.isEmpty ? null : name;
  }

  static bool _matchesEpisode(String name, int season, int episode) {
    final n = name.toLowerCase();
    return RegExp('s0*$season[\\s._-]*e0*$episode(?!\\d)').hasMatch(n) ||
        RegExp('(?:^|[^0-9])0*${season}x0*$episode(?!\\d)').hasMatch(n) ||
        RegExp('season[\\s._-]*0*$season.*episode[\\s._-]*0*$episode(?!\\d)')
            .hasMatch(n) ||
        RegExp('(?:^|[^a-z])ep(?:isode)?[\\s._:-]*0*$episode(?!\\d)')
            .hasMatch(n) ||
        RegExp('(?:^|[^a-z0-9])e0*$episode(?!\\d)').hasMatch(n) ||
        RegExp('^0*$episode[\\s._-]+').hasMatch(n) ||
        RegExp('[\\s._-]0*$episode(?:\\.\\w+)?\$').hasMatch(n);
  }

  static bool _hasOtherEpisode(String name, int season, int episode) {
    final m =
        RegExp(r's(\d{1,2})[\s._-]*e(\d{1,3})').firstMatch(name.toLowerCase());
    if (m == null) return false;
    final s = int.tryParse(m.group(1)!);
    final e = int.tryParse(m.group(2)!);
    return s != season || e != episode;
  }
}
