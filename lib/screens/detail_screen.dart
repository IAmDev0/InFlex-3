import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants/app_constants.dart';
import '../models/download_item.dart';
import '../models/media_model.dart';
import '../providers/watchlist_provider.dart';
import '../services/download_service.dart';
import '../services/tmdb_service.dart';
import '../widgets/stream_bottom_sheet.dart';
import 'download_player_screen.dart';
import 'downloads_screen.dart';

class DetailScreen extends StatefulWidget {
  final MediaItem item;

  /// Continue Watching: open straight to this season and, once its
  /// episodes load, straight to this episode's source picker (with resume -
  /// stream_bottom_sheet.dart looks the position up itself from the item +
  /// season + episode). Both null for a normal visit / movies.
  final int? initialSeason;
  final int? autoPlayEpisode;

  const DetailScreen({
    super.key,
    required this.item,
    this.initialSeason,
    this.autoPlayEpisode,
  });

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  MediaDetails? _details;
  late int _selectedSeason = widget.initialSeason ?? 1;
  List<Episode> _episodes = [];
  bool _episodesLoading = false;
  bool _autoPlayed = false;

  @override
  void initState() {
    super.initState();
    _loadDetails();
  }

  Future<void> _loadDetails() async {
    try {
      final d =
          await TmdbService.getDetails(widget.item.id, widget.item.mediaType);
      if (!mounted) return;
      setState(() {
        _details = d;
      });
      if (widget.item.mediaType == 'tv') {
        _loadEpisodes(widget.initialSeason ?? 1);
      }
    } catch (_) {
      // details failed to load, show what we have
    }
  }

  Future<void> _loadEpisodes(int season) async {
    setState(() {
      _selectedSeason = season;
      _episodesLoading = true;
    });
    try {
      final eps = await TmdbService.getEpisodes(widget.item.id, season);
      if (!mounted) return;
      setState(() {
        _episodes = eps;
        _episodesLoading = false;
      });
      final target = widget.autoPlayEpisode;
      if (!_autoPlayed && target != null && season == widget.initialSeason) {
        Episode? match;
        for (final e in eps) {
          if (e.episodeNumber == target) {
            match = e;
            break;
          }
        }
        if (match != null) {
          _autoPlayed = true;
          final epTitle = match.name;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _openStreams(
                season: season,
                episode: target,
                episodeTitle: epTitle,
              );
            }
          });
        }
      }
    } catch (_) {
      if (mounted) setState(() => _episodesLoading = false);
    }
  }

  void _openStreams({
    int? season,
    int? episode,
    String? episodeTitle,
    bool downloadMode = false,
  }) {
    final imdbId = _details?.imdbId;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StreamBottomSheet(
        item: widget.item,
        imdbId: imdbId,
        season: season,
        episode: episode,
        episodeTitle: episodeTitle,
        downloadMode: downloadMode,
      ),
    );
  }

  void _playDownloaded(DownloadItem dlItem) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DownloadPlayerScreen(item: dlItem)),
    );
  }

  Future<void> _exportMovieToGallery(DownloadItem dlItem) async {
    final res = await context.read<DownloadService>().saveToGallery(dlItem.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          res.ok
              ? 'Saved to Gallery (${res.location ?? 'Movies/InFlex'})'
              : (res.error ?? 'Failed to save to Gallery'),
        ),
        backgroundColor: res.ok ? const Color(0xFF16A34A) : Colors.redAccent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final d = _details;
    final wl = context.watch<WatchlistProvider>();
    final downloads = context.watch<DownloadService>();
    final movieDownload = item.mediaType == 'movie'
        ? downloads.findForMedia(item.id, 'movie')
        : null;
    final seasonSavedCount = item.mediaType == 'tv'
        ? downloads
            .episodesForShow(item.id)
            .where((e) => e.season == _selectedSeason && e.isComplete)
            .length
        : 0;

    return Scaffold(
      backgroundColor: const Color(0xFF050508),
      body: CustomScrollView(
        slivers: [
          // ── BACKDROP APPBAR ───────────────────────────────────
          SliverAppBar(
            expandedHeight: 260,
            pinned: true,
            backgroundColor: const Color(0xFF050508),
            leading: IconButton(
              icon: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(Icons.arrow_back, size: 20),
              ),
              onPressed: () => Navigator.pop(context),
            ),
            actions: [
              IconButton(
                tooltip: 'Downloads',
                icon: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Icon(
                    Icons.download_for_offline_outlined,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const DownloadsScreen()),
                ),
              ),
              IconButton(
                icon: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(
                    wl.isInWatchlist(item.id)
                        ? Icons.bookmark
                        : Icons.bookmark_border,
                    color: wl.isInWatchlist(item.id)
                        ? const Color(0xFFFFCC00)
                        : Colors.white,
                    size: 20,
                  ),
                ),
                onPressed: () => wl.toggle(item),
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  if (item.backdropPath != null)
                    CachedNetworkImage(
                      imageUrl: AppConstants.backdrop(item.backdropPath),
                      fit: BoxFit.cover,
                    )
                  else
                    Container(color: const Color(0xFF0E0E16)),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0xFF050508)],
                        stops: [0.4, 1.0],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── CONTENT ───────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CachedNetworkImage(
                          imageUrl: AppConstants.poster(item.posterPath),
                          width: 110,
                          height: 165,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => Container(
                            width: 110,
                            height: 165,
                            color: const Color(0xFF111118),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                                height: 1.15,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                _MetaBadge('⭐ ${item.ratingStr}',
                                    color: const Color(0xFFFFCC00)),
                                if (item.year > 0) _MetaBadge('${item.year}'),
                                if (d?.runtime != null)
                                  _MetaBadge('${d!.runtime}m'),
                                if (d?.numberOfSeasons != null)
                                  _MetaBadge('${d!.numberOfSeasons} Seasons'),
                              ],
                            ),
                            const SizedBox(height: 10),
                            if (d != null)
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: d.genres
                                    .take(3)
                                    .map((g) => _GenreChip(g.name))
                                    .toList(),
                              ),
                            const SizedBox(height: 14),
                            // Primary Stream Now button
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFFFCC00),
                                  foregroundColor: Colors.black,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  elevation: 8,
                                  shadowColor: const Color(0xFFFFCC00)
                                      .withValues(alpha: 0.4),
                                ),
                                icon: Icon(
                                  movieDownload?.isComplete == true
                                      ? Icons.offline_bolt_rounded
                                      : Icons.play_arrow_rounded,
                                  size: 22,
                                ),
                                label: Text(
                                  movieDownload?.isComplete == true
                                      ? 'Play Offline (${movieDownload!.quality})'
                                      : 'Stream Now',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 15,
                                  ),
                                ),
                                onPressed: () {
                                  if (movieDownload?.isComplete == true) {
                                    _playDownloaded(movieDownload!);
                                  } else {
                                    _openStreams(
                                      season: item.mediaType == 'tv'
                                          ? _selectedSeason
                                          : null,
                                      episode:
                                          item.mediaType == 'tv' ? 1 : null,
                                    );
                                  }
                                },
                              ),
                            ),
                            if (item.mediaType == 'movie') ...[
                              const SizedBox(height: 8),
                              _MovieDownloadControls(
                                movieDownload: movieDownload,
                                metrics: movieDownload != null
                                    ? downloads.liveMetricsFor(movieDownload.id)
                                    : null,
                                onStartDownload: () =>
                                    _openStreams(downloadMode: true),
                                onOpenStreams: () => _openStreams(),
                                onSaveToGallery: movieDownload != null
                                    ? () => _exportMovieToGallery(movieDownload)
                                    : null,
                                onOpenDownloads: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const DownloadsScreen(),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),

                  // Overview
                  if (item.overview != null && item.overview!.isNotEmpty) ...[
                    const Text('Overview',
                        style: TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1)),
                    const SizedBox(height: 6),
                    Text(
                      item.overview!,
                      style: const TextStyle(
                          color: Colors.white60, fontSize: 13, height: 1.6),
                    ),
                    const SizedBox(height: 24),
                  ],

                  // ── TV: Seasons + Episodes ─────────────────────
                  if (item.mediaType == 'tv' &&
                      d != null &&
                      d.seasons.isNotEmpty) ...[
                    Row(
                      children: [
                        const Text('EPISODES',
                            style: TextStyle(
                                color: Colors.white38,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.2)),
                        if (seasonSavedCount > 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFF22C55E)
                                  .withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '$seasonSavedCount downloaded',
                              style: const TextStyle(
                                color: Color(0xFF22C55E),
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 10),

                    // Season selector
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: d.seasons.map((s) {
                          final active = _selectedSeason == s.seasonNumber;
                          return GestureDetector(
                            onTap: () => _loadEpisodes(s.seasonNumber),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              margin: const EdgeInsets.only(right: 8),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 6),
                              decoration: BoxDecoration(
                                color: active
                                    ? const Color(0xFFFFCC00)
                                        .withValues(alpha: 0.15)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: active
                                      ? const Color(0xFFFFCC00)
                                      : Colors.white.withValues(alpha: 0.12),
                                ),
                              ),
                              child: Text(
                                'S${s.seasonNumber}',
                                style: TextStyle(
                                  color: active
                                      ? const Color(0xFFFFCC00)
                                      : Colors.white54,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Episodes list
                    if (_episodesLoading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Center(
                            child: CircularProgressIndicator(
                                color: Color(0xFFFFCC00), strokeWidth: 2)),
                      )
                    else
                      ...(_episodes.map((ep) {
                        final epDownload = downloads.findForMedia(
                          item.id,
                          'tv',
                          season: _selectedSeason,
                          episode: ep.episodeNumber,
                        );
                        return _EpisodeTile(
                          ep: ep,
                          download: epDownload,
                          onPlay: () {
                            if (epDownload != null && epDownload.isComplete) {
                              _playDownloaded(epDownload);
                            } else {
                              _openStreams(
                                season: _selectedSeason,
                                episode: ep.episodeNumber,
                                episodeTitle: ep.name,
                              );
                            }
                          },
                          onLongPressPlay: () => _openStreams(
                            season: _selectedSeason,
                            episode: ep.episodeNumber,
                            episodeTitle: ep.name,
                          ),
                          onDownloadTap: () {
                            if (epDownload == null) {
                              _openStreams(
                                season: _selectedSeason,
                                episode: ep.episodeNumber,
                                episodeTitle: ep.name,
                                downloadMode: true,
                              );
                            } else {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const DownloadsScreen(),
                                ),
                              );
                            }
                          },
                        );
                      })),
                    const SizedBox(height: 20),
                  ],

                  // ── CAST ──────────────────────────────────────
                  if (d != null && d.cast.isNotEmpty) ...[
                    const Text('CAST',
                        style: TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2)),
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: d.cast.map((c) => _CastCard(c)).toList(),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MovieDownloadControls extends StatelessWidget {
  final DownloadItem? movieDownload;
  final DownloadLiveMetrics? metrics;
  final VoidCallback onStartDownload;
  final VoidCallback onOpenStreams;
  final VoidCallback? onSaveToGallery;
  final VoidCallback onOpenDownloads;

  const _MovieDownloadControls({
    required this.movieDownload,
    required this.metrics,
    required this.onStartDownload,
    required this.onOpenStreams,
    required this.onSaveToGallery,
    required this.onOpenDownloads,
  });

  @override
  Widget build(BuildContext context) {
    final dl = movieDownload;
    if (dl == null) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            side: BorderSide(
                color: const Color(0xFFFFCC00).withValues(alpha: 0.45)),
            backgroundColor: Colors.white.withValues(alpha: 0.04),
            padding: const EdgeInsets.symmetric(vertical: 11),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          icon: const Icon(Icons.download_rounded,
              color: Color(0xFFFFCC00), size: 20),
          label: const Text(
            'Download Permanently',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5),
          ),
          onPressed: onStartDownload,
        ),
      );
    }

    if (dl.isComplete) {
      return Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: dl.savedToGallery
                    ? const Color(0xFF22C55E)
                    : Colors.white,
                side: BorderSide(
                  color: dl.savedToGallery
                      ? const Color(0xFF22C55E).withValues(alpha: 0.5)
                      : Colors.white24,
                ),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              icon: Icon(
                dl.savedToGallery
                    ? Icons.check_circle_outline_rounded
                    : Icons.save_alt_rounded,
                size: 17,
              ),
              label: Text(
                dl.savedToGallery ? 'In Gallery' : 'Save to Gallery',
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
              ),
              onPressed: onSaveToGallery,
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Online sources',
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.06),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            icon: const Icon(Icons.hub_rounded, color: Colors.white70, size: 18),
            onPressed: onOpenStreams,
          ),
        ],
      );
    }

    final pct = (dl.progress * 100).toStringAsFixed(0);
    final speedStr = (metrics != null && metrics!.speedMbs > 0.05)
        ? ' · ${metrics!.speedMbs.toStringAsFixed(1)} MB/s'
        : '';

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onOpenDownloads,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF0E0E16),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: const Color(0xFFFFCC00).withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.downloading_rounded,
                    color: Color(0xFFFFCC00), size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    dl.isPaused
                        ? 'Paused · $pct%'
                        : dl.isFailed
                            ? 'Download failed · Tap to retry'
                            : 'Downloading $pct%$speedStr',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: Colors.white38, size: 18),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                minHeight: 4,
                value: dl.effectiveTotalBytes > 0 ? dl.progress : null,
                backgroundColor: Colors.white12,
                valueColor:
                    const AlwaysStoppedAnimation<Color>(Color(0xFFFFCC00)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetaBadge extends StatelessWidget {
  final String text;
  final Color? color;
  const _MetaBadge(this.text, {this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: (color ?? Colors.white).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color ?? Colors.white60,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _GenreChip extends StatelessWidget {
  final String name;
  const _GenreChip(this.name);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFFFCC00).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border:
            Border.all(color: const Color(0xFFFFCC00).withValues(alpha: 0.3)),
      ),
      child: Text(
        name,
        style: const TextStyle(
          color: Color(0xFFFFCC00),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  final Episode ep;
  final DownloadItem? download;
  final VoidCallback onPlay;
  final VoidCallback onLongPressPlay;
  final VoidCallback onDownloadTap;

  const _EpisodeTile({
    required this.ep,
    required this.download,
    required this.onPlay,
    required this.onLongPressPlay,
    required this.onDownloadTap,
  });

  @override
  Widget build(BuildContext context) {
    final dl = download;
    final isComplete = dl?.isComplete == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0E0E16),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isComplete
              ? const Color(0xFF22C55E).withValues(alpha: 0.22)
              : Colors.white.withValues(alpha: 0.05),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFFFFCC00).withValues(alpha: 0.1),
              shape: BoxShape.circle,
              border: Border.all(
                  color: const Color(0xFFFFCC00).withValues(alpha: 0.3)),
            ),
            child: Center(
              child: Text(
                '${ep.episodeNumber}',
                style: const TextStyle(
                  color: Color(0xFFFFCC00),
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(ep.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 13)),
                if (ep.overview != null && ep.overview!.isNotEmpty)
                  Text(ep.overview!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 11)),
              ],
            ),
          ),
          const SizedBox(width: 4),
          // Per-episode Download / Progress / Saved status button
          IconButton(
            tooltip: dl == null
                ? 'Download episode'
                : isComplete
                    ? 'Downloaded (${dl.quality})'
                    : 'Manage download',
            onPressed: onDownloadTap,
            icon: _buildDownloadIndicator(dl),
          ),
          // Play button (plays local offline copy when downloaded; long-press opens sources)
          GestureDetector(
            onLongPress: onLongPressPlay,
            child: IconButton(
              onPressed: onPlay,
              icon: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: isComplete
                      ? const Color(0xFF22C55E).withValues(alpha: 0.16)
                      : const Color(0xFFFFCC00).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.play_arrow_rounded,
                  color: isComplete
                      ? const Color(0xFF22C55E)
                      : const Color(0xFFFFCC00),
                  size: 18,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadIndicator(DownloadItem? dl) {
    if (dl == null) {
      return Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(
          Icons.download_rounded,
          color: Colors.white70,
          size: 17,
        ),
      );
    }
    if (dl.isComplete) {
      return Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: const Color(0xFF22C55E).withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(
          Icons.download_done_rounded,
          color: Color(0xFF22C55E),
          size: 17,
        ),
      );
    }
    if (dl.isFailed) {
      return Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: Colors.redAccent.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(
          Icons.error_outline_rounded,
          color: Colors.redAccent,
          size: 17,
        ),
      );
    }
    return SizedBox(
      width: 24,
      height: 24,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: dl.effectiveTotalBytes > 0 ? dl.progress : null,
            strokeWidth: 2.3,
            color: dl.isPaused ? Colors.orangeAccent : const Color(0xFFFFCC00),
            backgroundColor: Colors.white12,
          ),
          Icon(
            dl.isPaused ? Icons.pause_rounded : Icons.arrow_downward_rounded,
            size: 11,
            color: Colors.white70,
          ),
        ],
      ),
    );
  }
}

class _CastCard extends StatelessWidget {
  final CastMember cast;
  const _CastCard(this.cast);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 12),
      width: 64,
      child: Column(
        children: [
          ClipOval(
            child: cast.profilePath != null
                ? CachedNetworkImage(
                    imageUrl:
                        'https://image.tmdb.org/t/p/w185${cast.profilePath}',
                    width: 52,
                    height: 52,
                    fit: BoxFit.cover,
                  )
                : Container(
                    width: 52,
                    height: 52,
                    color: const Color(0xFF111118),
                    child: const Icon(Icons.person, color: Colors.white24),
                  ),
          ),
          const SizedBox(height: 5),
          Text(
            cast.name,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54, fontSize: 10),
          ),
        ],
      ),
    );
  }
}
