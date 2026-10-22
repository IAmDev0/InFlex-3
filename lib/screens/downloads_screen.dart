import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants/app_constants.dart';
import '../models/download_item.dart';
import '../models/media_model.dart';
import '../services/download_service.dart';
import '../services/watch_history.dart';
import 'detail_screen.dart';
import 'download_player_screen.dart';

// ── DownloadsScreen ───────────────────────────────────────────────────────────
//
// Permanent offline library for downloaded Movies and Web Series:
//   • Works both embedded as a primary tab on HomeScreen (`embedded: true`)
//     and pushed standalone (`embedded: false`).
//   • Displays locally cached posters so full artwork appears even offline.
//   • Groups TV episodes neatly under each show while keeping 1-tap Play,
//     Pause/Resume, Save to Gallery ("Movies/InFlex") and Delete accessible.

const Color _gold = Color(0xFFFFCC00);
const Color _bg = Color(0xFF050508);
const Color _card = Color(0xFF0E0E16);

enum _DownloadFilter { all, movies, series, active, gallery }

class DownloadsScreen extends StatefulWidget {
  final bool embedded;

  const DownloadsScreen({
    super.key,
    this.embedded = false,
  });

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  _DownloadFilter _filter = _DownloadFilter.all;
  final Set<int> _collapsedShowIds = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<DownloadService>().refreshDiskSpace();
      }
    });
  }

  List<DownloadItem> _applyFilter(List<DownloadItem> all) {
    switch (_filter) {
      case _DownloadFilter.all:
        return all;
      case _DownloadFilter.movies:
        return all.where((d) => d.isMovie).toList();
      case _DownloadFilter.series:
        return all.where((d) => d.isSeries).toList();
      case _DownloadFilter.active:
        return all
            .where((d) => d.isActive || d.isPaused || d.isFailed)
            .toList();
      case _DownloadFilter.gallery:
        return all.where((d) => d.savedToGallery).toList();
    }
  }

  Future<void> _openPlayer(DownloadItem item) async {
    final file = File(item.filePath);
    if (!await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('File not found on storage — removing stale entry'),
          backgroundColor: Colors.redAccent,
        ),
      );
      await context.read<DownloadService>().delete(item.id);
      return;
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DownloadPlayerScreen(item: item)),
    );
    if (mounted) setState(() {});
  }

  Future<void> _exportToGallery(DownloadItem item) async {
    final service = context.read<DownloadService>();
    final res = await service.saveToGallery(item.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          res.ok
              ? 'Saved to Gallery (${res.location ?? 'Movies/InFlex'})'
              : (res.error ?? 'Failed to save to Gallery'),
        ),
        backgroundColor: res.ok ? const Color(0xFF16A34A) : Colors.redAccent,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _confirmDelete(DownloadItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF14141C),
        title: const Text(
          'Delete from app downloads?',
          style: TextStyle(
              color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800),
        ),
        content: Text(
          item.savedToGallery
              ? '"${item.label}" will be deleted from InFlex storage. Any copy already exported to your phone Gallery (${item.galleryLocation ?? 'Movies/InFlex'}) stays untouched.'
              : '"${item.label}" will be permanently deleted from your device.',
          style: const TextStyle(color: Colors.white60, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete',
              style:
                  TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await context.read<DownloadService>().delete(item.id);
    }
  }

  void _openDetails(DownloadItem item) {
    final media = MediaItem(
      id: item.tmdbId,
      title: item.title,
      posterPath: item.posterPath,
      backdropPath: item.backdropPath,
      mediaType: item.mediaType,
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DetailScreen(
          item: media,
          initialSeason: item.season,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<DownloadService>();
    final allItems = service.items;
    final filtered = _applyFilter(allItems);

    // Build top-level display entries: standalone Movies + grouped TV Shows.
    final entries = <_LibraryEntry>[];
    final seenShows = <int>{};
    for (final item in filtered) {
      if (item.isSeries) {
        if (seenShows.add(item.tmdbId)) {
          final showEps = filtered
              .where((d) => d.isSeries && d.tmdbId == item.tmdbId)
              .toList()
            ..sort((a, b) {
              final s = (a.season ?? 0).compareTo(b.season ?? 0);
              if (s != 0) return s;
              return (a.episode ?? 0).compareTo(b.episode ?? 0);
            });
          entries.add(_LibraryEntry.series(showEps));
        }
      } else {
        entries.add(_LibraryEntry.movie(item));
      }
    }

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.embedded)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 6, 16, 4),
            child: Text(
              'Downloads',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.4,
              ),
            ),
          ),
        _StorageSummaryBanner(
          savedCount: service.completedCount,
          activeCount: service.activeCount,
          usedBytes: service.totalSavedBytes,
          freeBytes: service.freeDiskBytes,
        ),
        if (allItems.isNotEmpty) _buildFilterBar(allItems),
        Expanded(
          child: allItems.isEmpty
              ? const _EmptyDownloadsState()
              : entries.isEmpty
                  ? _NoFilteredItemsState(
                      onClear: () =>
                          setState(() => _filter = _DownloadFilter.all),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                      itemCount: entries.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (_, index) {
                        final entry = entries[index];
                        if (entry.movie != null) {
                          final item = entry.movie!;
                          return _MovieDownloadCard(
                            item: item,
                            metrics: service.liveMetricsFor(item.id),
                            onPlay: () => _openPlayer(item),
                            onSaveGallery: () => _exportToGallery(item),
                            onPause: () => service.pause(item.id),
                            onResume: () => service.resume(item.id),
                            onStartNow: () => service.startNow(item.id),
                            onDelete: () => _confirmDelete(item),
                            onTapHeader: () => _openDetails(item),
                          );
                        }
                        final eps = entry.episodes!;
                        final showId = eps.first.tmdbId;
                        final expanded = !_collapsedShowIds.contains(showId);
                        return _SeriesDownloadCard(
                          episodes: eps,
                          expanded: expanded,
                          service: service,
                          onToggleExpand: () {
                            setState(() {
                              if (expanded) {
                                _collapsedShowIds.add(showId);
                              } else {
                                _collapsedShowIds.remove(showId);
                              }
                            });
                          },
                          onTapHeader: () => _openDetails(eps.first),
                          onPlayEpisode: _openPlayer,
                          onSaveEpisodeGallery: _exportToGallery,
                          onDeleteEpisode: _confirmDelete,
                        );
                      },
                    ),
        ),
      ],
    );

    if (widget.embedded) {
      return body;
    }

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Downloads',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
      ),
      body: body,
    );
  }

  Widget _buildFilterBar(List<DownloadItem> all) {
    final options = <(_DownloadFilter, String)>[
      (_DownloadFilter.all, 'All (${all.length})'),
      (
        _DownloadFilter.movies,
        'Movies (${all.where((d) => d.isMovie).length})'
      ),
      (
        _DownloadFilter.series,
        'Series (${all.where((d) => d.isSeries).length})'
      ),
      if (all.any((d) => !d.isComplete))
        (
          _DownloadFilter.active,
          'Active (${all.where((d) => !d.isComplete).length})'
        ),
      if (all.any((d) => d.savedToGallery))
        (
          _DownloadFilter.gallery,
          'In Gallery (${all.where((d) => d.savedToGallery).length})'
        ),
    ];

    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        itemCount: options.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final selected = _filter == options[i].$1;
          return GestureDetector(
            onTap: () => setState(() => _filter = options[i].$1),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? _gold : Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                options[i].$2,
                style: TextStyle(
                  color: selected ? Colors.black : Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _LibraryEntry {
  final DownloadItem? movie;
  final List<DownloadItem>? episodes;

  const _LibraryEntry.movie(this.movie) : episodes = null;
  const _LibraryEntry.series(this.episodes) : movie = null;
}

class _StorageSummaryBanner extends StatelessWidget {
  final int savedCount;
  final int activeCount;
  final int usedBytes;
  final int? freeBytes;

  const _StorageSummaryBanner({
    required this.savedCount,
    required this.activeCount,
    required this.usedBytes,
    this.freeBytes,
  });

  @override
  Widget build(BuildContext context) {
    final usedLabel = DownloadItem.formatBytes(usedBytes);
    final freeLabel =
        freeBytes != null ? '${DownloadItem.formatBytes(freeBytes!)} free' : null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: _gold.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.offline_pin_rounded,
                color: _gold,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    activeCount > 0
                        ? '$savedCount saved · $activeCount active'
                        : '$savedCount permanent downloads on device',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    freeLabel != null
                        ? '$usedLabel used · $freeLabel'
                        : '$usedLabel stored offline',
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Standalone Movie Download Card ───────────────────────────────────────────

class _MovieDownloadCard extends StatelessWidget {
  final DownloadItem item;
  final DownloadLiveMetrics? metrics;
  final VoidCallback onPlay;
  final VoidCallback onSaveGallery;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onStartNow;
  final VoidCallback onDelete;
  final VoidCallback onTapHeader;

  const _MovieDownloadCard({
    required this.item,
    required this.metrics,
    required this.onPlay,
    required this.onSaveGallery,
    required this.onPause,
    required this.onResume,
    required this.onStartNow,
    required this.onDelete,
    required this.onTapHeader,
  });

  @override
  Widget build(BuildContext context) {
    final watchEntry = WatchHistory.get(item.tmdbId, item.mediaType);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: item.isDownloading
              ? _gold.withValues(alpha: 0.28)
              : Colors.white.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: item.isComplete ? onPlay : onTapHeader,
                child: _OfflinePoster(
                  localPosterPath: item.localPosterPath,
                  posterPath: item.posterPath,
                  width: 64,
                  height: 94,
                  showPlayOverlay: item.isComplete,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onTap: onTapHeader,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                height: 1.2,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _StatusBadge(item: item, metrics: metrics),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _MiniTag(item.quality, color: _gold),
                        _MiniTag('MOVIE', color: Colors.white54),
                        if (item.savedToGallery)
                          const _MiniTag('IN GALLERY ✓',
                              color: Color(0xFF22C55E))
                        else if (item.saveToGalleryOnComplete &&
                            !item.isComplete)
                          const _MiniTag('AUTO-GALLERY',
                              color: Color(0xFF38BDF8)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _TelemetryText(item: item, metrics: metrics),
                  ],
                ),
              ),
            ],
          ),
          if (!item.isComplete) ...[
            const SizedBox(height: 10),
            _ProgressBarRow(item: item),
          ] else if (watchEntry != null && watchEntry.progress > 0.02) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                minHeight: 4,
                value: watchEntry.progress,
                backgroundColor: Colors.white12,
                valueColor: const AlwaysStoppedAnimation<Color>(_gold),
              ),
            ),
          ],
          const SizedBox(height: 10),
          _ActionRow(
            item: item,
            exportingGallery: metrics?.exportingToGallery == true,
            onPlay: onPlay,
            onSaveGallery: onSaveGallery,
            onPause: onPause,
            onResume: onResume,
            onStartNow: onStartNow,
            onDelete: onDelete,
          ),
        ],
      ),
    );
  }
}

// ── Grouped TV Series Card ───────────────────────────────────────────────────

class _SeriesDownloadCard extends StatelessWidget {
  final List<DownloadItem> episodes;
  final bool expanded;
  final DownloadService service;
  final VoidCallback onToggleExpand;
  final VoidCallback onTapHeader;
  final ValueChanged<DownloadItem> onPlayEpisode;
  final ValueChanged<DownloadItem> onSaveEpisodeGallery;
  final ValueChanged<DownloadItem> onDeleteEpisode;

  const _SeriesDownloadCard({
    required this.episodes,
    required this.expanded,
    required this.service,
    required this.onToggleExpand,
    required this.onTapHeader,
    required this.onPlayEpisode,
    required this.onSaveEpisodeGallery,
    required this.onDeleteEpisode,
  });

  @override
  Widget build(BuildContext context) {
    final head = episodes.first;
    final completedEps = episodes.where((e) => e.isComplete).length;
    var totalBytes = 0;
    for (final ep in episodes) {
      totalBytes += ep.isComplete
          ? (ep.downloadedBytes > 0 ? ep.downloadedBytes : ep.effectiveTotalBytes)
          : ep.downloadedBytes;
    }

    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: episodes.any((e) => e.isDownloading)
              ? _gold.withValues(alpha: 0.28)
              : Colors.white.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onToggleExpand,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: onTapHeader,
                    child: _OfflinePoster(
                      localPosterPath: head.localPosterPath,
                      posterPath: head.posterPath,
                      width: 56,
                      height: 82,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          head.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            const _MiniTag('SERIES', color: Color(0xFF38BDF8)),
                            _MiniTag(
                              '$completedEps/${episodes.length} ready',
                              color: completedEps == episodes.length
                                  ? const Color(0xFF22C55E)
                                  : _gold,
                            ),
                            _MiniTag(
                              DownloadItem.formatBytes(totalBytes),
                              color: Colors.white54,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: Colors.white54,
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            const Divider(color: Colors.white10, height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                children: [
                  for (var i = 0; i < episodes.length; i++) ...[
                    if (i > 0) const SizedBox(height: 10),
                    _EpisodeDownloadSubCard(
                      item: episodes[i],
                      metrics: service.liveMetricsFor(episodes[i].id),
                      onPlay: () => onPlayEpisode(episodes[i]),
                      onSaveGallery: () => onSaveEpisodeGallery(episodes[i]),
                      onPause: () => service.pause(episodes[i].id),
                      onResume: () => service.resume(episodes[i].id),
                      onStartNow: () => service.startNow(episodes[i].id),
                      onDelete: () => onDeleteEpisode(episodes[i]),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EpisodeDownloadSubCard extends StatelessWidget {
  final DownloadItem item;
  final DownloadLiveMetrics? metrics;
  final VoidCallback onPlay;
  final VoidCallback onSaveGallery;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onStartNow;
  final VoidCallback onDelete;

  const _EpisodeDownloadSubCard({
    required this.item,
    required this.metrics,
    required this.onPlay,
    required this.onSaveGallery,
    required this.onPause,
    required this.onResume,
    required this.onStartNow,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  item.episodeCode ?? 'EP',
                  style: const TextStyle(
                    color: _gold,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  item.episodeTitle != null &&
                          item.episodeTitle!.trim().isNotEmpty
                      ? item.episodeTitle!
                      : 'Episode ${item.episode ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _StatusBadge(item: item, metrics: metrics),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _MiniTag(item.quality, color: Colors.white60),
              if (item.savedToGallery) ...[
                const SizedBox(width: 6),
                const _MiniTag('IN GALLERY ✓', color: Color(0xFF22C55E)),
              ],
              const SizedBox(width: 8),
              Expanded(child: _TelemetryText(item: item, metrics: metrics)),
            ],
          ),
          if (!item.isComplete) ...[
            const SizedBox(height: 8),
            _ProgressBarRow(item: item),
          ],
          const SizedBox(height: 8),
          _ActionRow(
            item: item,
            exportingGallery: metrics?.exportingToGallery == true,
            onPlay: onPlay,
            onSaveGallery: onSaveGallery,
            onPause: onPause,
            onResume: onResume,
            onStartNow: onStartNow,
            onDelete: onDelete,
          ),
        ],
      ),
    );
  }
}

// ── Shared sub-widgets ───────────────────────────────────────────────────────

class _OfflinePoster extends StatelessWidget {
  final String? localPosterPath;
  final String? posterPath;
  final double width;
  final double height;
  final bool showPlayOverlay;

  const _OfflinePoster({
    required this.localPosterPath,
    required this.posterPath,
    required this.width,
    required this.height,
    this.showPlayOverlay = false,
  });

  @override
  Widget build(BuildContext context) {
    Widget art;
    if (localPosterPath != null && File(localPosterPath!).existsSync()) {
      art = Image.file(
        File(localPosterPath!),
        width: width,
        height: height,
        fit: BoxFit.cover,
      );
    } else if (posterPath != null && posterPath!.isNotEmpty) {
      art = CachedNetworkImage(
        imageUrl: AppConstants.poster(posterPath),
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => _placeholder(),
      );
    } else {
      art = _placeholder();
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Stack(
        alignment: Alignment.center,
        children: [
          art,
          if (showPlayOverlay)
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
                shape: BoxShape.circle,
                border: Border.all(color: _gold.withValues(alpha: 0.7)),
              ),
              child: const Icon(
                Icons.play_arrow_rounded,
                color: _gold,
                size: 18,
              ),
            ),
        ],
      ),
    );
  }

  Widget _placeholder() => Container(
        width: width,
        height: height,
        color: const Color(0xFF14141D),
        child: const Icon(Icons.movie_rounded, color: Colors.white24, size: 24),
      );
}

class _StatusBadge extends StatelessWidget {
  final DownloadItem item;
  final DownloadLiveMetrics? metrics;

  const _StatusBadge({required this.item, required this.metrics});

  @override
  Widget build(BuildContext context) {
    if (metrics?.exportingToGallery == true) {
      return _pill('Saving...', const Color(0xFF38BDF8));
    }
    switch (item.status) {
      case 'completed':
        return _pill('Saved', const Color(0xFF22C55E));
      case 'downloading':
        return _pill(
          '${(item.progress * 100).toStringAsFixed(0)}%',
          _gold,
        );
      case 'paused':
        return _pill('Paused', Colors.orangeAccent);
      case 'queued':
        return _pill('Queued', Colors.white54);
      case 'failed':
        return _pill('Failed', Colors.redAccent);
      default:
        return _pill(item.status, Colors.white54);
    }
  }

  Widget _pill(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
}

class _TelemetryText extends StatelessWidget {
  final DownloadItem item;
  final DownloadLiveMetrics? metrics;

  const _TelemetryText({required this.item, required this.metrics});

  @override
  Widget build(BuildContext context) {
    if (item.isFailed && item.error != null) {
      return Text(
        item.error!,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.redAccent, fontSize: 11),
      );
    }

    final parts = <String>[item.sizeSummary];
    final m = metrics;
    if (item.isDownloading && m != null) {
      if (m.speedMbs > 0.05) {
        parts.add('${m.speedMbs.toStringAsFixed(2)} MB/s');
      } else if (m.phase.isNotEmpty) {
        parts.add(m.phase);
      }
      if (m.peers > 0) {
        parts.add('${m.peers} peers');
      }
      final eta = m.etaLabel;
      if (eta != null) {
        parts.add(eta);
      }
    } else if (item.savedToGallery && item.galleryLocation != null) {
      parts.add(item.galleryLocation!);
    }

    return Text(
      parts.join('  ·  '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: Colors.white38, fontSize: 11),
    );
  }
}

class _ProgressBarRow extends StatelessWidget {
  final DownloadItem item;

  const _ProgressBarRow({required this.item});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 6,
        child: LinearProgressIndicator(
          value: item.effectiveTotalBytes > 0 ? item.progress : null,
          backgroundColor: Colors.white.withValues(alpha: 0.08),
          valueColor: AlwaysStoppedAnimation<Color>(
            item.isPaused
                ? Colors.orangeAccent
                : item.isFailed
                    ? Colors.redAccent
                    : _gold,
          ),
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final DownloadItem item;
  final bool exportingGallery;
  final VoidCallback onPlay;
  final VoidCallback onSaveGallery;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onStartNow;
  final VoidCallback onDelete;

  const _ActionRow({
    required this.item,
    required this.exportingGallery,
    required this.onPlay,
    required this.onSaveGallery,
    required this.onPause,
    required this.onResume,
    required this.onStartNow,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (item.isComplete) ...[
          Expanded(
            flex: 3,
            child: _ActionButton(
              icon: Icons.play_arrow_rounded,
              label: 'Play',
              color: _gold,
              filled: true,
              onTap: onPlay,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: _ActionButton(
              icon: exportingGallery
                  ? Icons.hourglass_top_rounded
                  : item.savedToGallery
                      ? Icons.check_circle_outline_rounded
                      : Icons.save_alt_rounded,
              label: exportingGallery
                  ? 'Saving...'
                  : item.savedToGallery
                      ? 'In Gallery'
                      : 'Save to Gallery',
              color: item.savedToGallery
                  ? const Color(0xFF22C55E)
                  : Colors.white70,
              onTap: exportingGallery ? null : onSaveGallery,
            ),
          ),
        ] else if (item.isDownloading) ...[
          Expanded(
            child: _ActionButton(
              icon: Icons.pause_rounded,
              label: 'Pause',
              color: _gold,
              onTap: onPause,
            ),
          ),
        ] else if (item.isPaused) ...[
          Expanded(
            child: _ActionButton(
              icon: Icons.play_arrow_rounded,
              label: 'Resume',
              color: _gold,
              filled: true,
              onTap: onResume,
            ),
          ),
        ] else if (item.isQueued) ...[
          Expanded(
            child: _ActionButton(
              icon: Icons.bolt_rounded,
              label: 'Start Now',
              color: _gold,
              onTap: onStartNow,
            ),
          ),
        ] else if (item.isFailed) ...[
          Expanded(
            child: _ActionButton(
              icon: Icons.replay_rounded,
              label: item.downloadedBytes > 0 ? 'Resume Retry' : 'Retry',
              color: _gold,
              filled: true,
              onTap: onResume,
            ),
          ),
        ],
        const SizedBox(width: 8),
        _IconActionButton(
          icon: Icons.delete_outline_rounded,
          tooltip: 'Delete',
          onTap: onDelete,
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool filled;
  final VoidCallback? onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    this.filled = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 10),
        decoration: BoxDecoration(
          color: filled ? color : color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: filled ? color : color.withValues(alpha: 0.30),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: filled ? Colors.black : color,
              size: 16,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: filled ? Colors.black : color,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IconActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _IconActionButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          ),
          child: Icon(icon, color: Colors.white54, size: 17),
        ),
      ),
    );
  }
}

class _MiniTag extends StatelessWidget {
  final String label;
  final Color color;

  const _MiniTag(this.label, {required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _EmptyDownloadsState extends StatelessWidget {
  const _EmptyDownloadsState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.download_for_offline_outlined,
              color: Colors.white12,
              size: 68,
            ),
            SizedBox(height: 16),
            Text(
              'No permanent downloads yet',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Open any movie or series episode and tap Download to save it permanently inside InFlex or directly to your phone Gallery.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white38,
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoFilteredItemsState extends StatelessWidget {
  final VoidCallback onClear;

  const _NoFilteredItemsState({required this.onClear});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.filter_alt_off_rounded,
              color: Colors.white24, size: 42),
          const SizedBox(height: 12),
          const Text(
            'Nothing matches this filter',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
          TextButton(
            onPressed: onClear,
            child: const Text('Show all', style: TextStyle(color: _gold)),
          ),
        ],
      ),
    );
  }
}
