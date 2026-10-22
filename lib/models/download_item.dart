// ── DownloadItem ─────────────────────────────────────────────────────────────
//
// Persistent record of a permanently downloaded movie or TV episode.
//
// Stored in Hive box 'downloads' as JSON (matching WatchlistProvider &
// WatchHistory so no code-generated TypeAdapter is needed).

class DownloadItem {
  /// Stable deterministic key: '<mediaType>_<tmdbId>_<season>_<episode>'.
  final String id;

  final int tmdbId;
  final String mediaType; // 'movie' | 'tv'
  final String title;
  final String? posterPath;
  final String? localPosterPath; // locally cached poster for 100% offline UI
  final String? backdropPath;
  final String? imdbId;

  /// Season & episode for TV series (both null for movies).
  final int? season;
  final int? episode;
  final String? episodeTitle;

  final String quality; // e.g. '1080p', '720p', '4K'

  /// Permanent final path inside <app documents>/InFlex/Downloads/<fileName>.
  /// While still downloading/paused, verified bytes accumulate in
  /// '<filePath>.part' and are renamed atomically on completion.
  final String filePath;
  final String fileName;

  final int totalBytes;
  final int downloadedBytes;

  /// 'queued' | 'downloading' | 'paused' | 'completed' | 'failed'
  final String status;
  final String? error;

  /// If true, automatically exports the finished video to the device Gallery
  /// ("Movies/InFlex") as soon as the download completes.
  final bool saveToGalleryOnComplete;

  /// True once this download has been exported to the device Gallery.
  final bool savedToGallery;

  /// Human-readable Gallery path (e.g. 'Movies/InFlex/Jawan_1080p.mkv').
  final String? galleryLocation;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// Torrent recovery metadata so paused/queued/failed downloads resume cleanly
  /// even across app restarts or phone reboots.
  final String? magnetLink;
  final String? infoHash;
  final int? fileIdx;
  final String? fileNameHint;
  final int? sizeBytes;

  const DownloadItem({
    required this.id,
    required this.tmdbId,
    required this.mediaType,
    required this.title,
    this.posterPath,
    this.localPosterPath,
    this.backdropPath,
    this.imdbId,
    this.season,
    this.episode,
    this.episodeTitle,
    required this.quality,
    required this.filePath,
    required this.fileName,
    this.totalBytes = 0,
    this.downloadedBytes = 0,
    this.status = 'queued',
    this.error,
    this.saveToGalleryOnComplete = false,
    this.savedToGallery = false,
    this.galleryLocation,
    required this.createdAt,
    required this.updatedAt,
    this.magnetLink,
    this.infoHash,
    this.fileIdx,
    this.fileNameHint,
    this.sizeBytes,
  });

  bool get isMovie => mediaType != 'tv';
  bool get isSeries => mediaType == 'tv';
  bool get isComplete => status == 'completed';
  bool get isDownloading => status == 'downloading';
  bool get isQueued => status == 'queued';
  bool get isPaused => status == 'paused';
  bool get isFailed => status == 'failed';
  bool get isActive => status == 'queued' || status == 'downloading';

  int get effectiveTotalBytes =>
      totalBytes > 0 ? totalBytes : (sizeBytes ?? 0);

  double get progress {
    final total = effectiveTotalBytes;
    if (isComplete) return 1.0;
    if (total <= 0) return 0.0;
    return (downloadedBytes / total).clamp(0.0, 1.0).toDouble();
  }

  String? get episodeCode {
    if (season == null || episode == null) return null;
    final s = season!.toString().padLeft(2, '0');
    final e = episode!.toString().padLeft(2, '0');
    return 'S${s}E$e';
  }

  /// Display title: 'Show · S01E03' for series episodes, plain title for movies.
  String get label {
    final code = episodeCode;
    if (code != null) {
      return '$title · $code';
    }
    return title;
  }

  /// Subtitle line used inside a grouped series card: 'E03 · Episode Name'.
  String get episodeLabel {
    if (episode == null) return title;
    final epNum = 'E${episode!.toString().padLeft(2, '0')}';
    final epName = episodeTitle?.trim();
    if (epName != null && epName.isNotEmpty) {
      return '$epNum · $epName';
    }
    return 'Episode $episode';
  }

  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  String get sizeSummary {
    final total = effectiveTotalBytes;
    if (isComplete) {
      final finalSize = downloadedBytes > 0 ? downloadedBytes : total;
      return finalSize > 0 ? formatBytes(finalSize) : 'Saved';
    }
    if (total > 0) {
      return '${formatBytes(downloadedBytes)} / ${formatBytes(total)}';
    }
    if (downloadedBytes > 0) {
      return formatBytes(downloadedBytes);
    }
    return 'Waiting...';
  }

  DownloadItem copyWith({
    String? id,
    int? tmdbId,
    String? mediaType,
    String? title,
    String? posterPath,
    String? localPosterPath,
    String? backdropPath,
    String? imdbId,
    int? season,
    int? episode,
    String? episodeTitle,
    String? quality,
    String? filePath,
    String? fileName,
    int? totalBytes,
    int? downloadedBytes,
    String? status,
    String? error,
    bool clearError = false,
    bool? saveToGalleryOnComplete,
    bool? savedToGallery,
    String? galleryLocation,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? magnetLink,
    String? infoHash,
    int? fileIdx,
    String? fileNameHint,
    int? sizeBytes,
  }) =>
      DownloadItem(
        id: id ?? this.id,
        tmdbId: tmdbId ?? this.tmdbId,
        mediaType: mediaType ?? this.mediaType,
        title: title ?? this.title,
        posterPath: posterPath ?? this.posterPath,
        localPosterPath: localPosterPath ?? this.localPosterPath,
        backdropPath: backdropPath ?? this.backdropPath,
        imdbId: imdbId ?? this.imdbId,
        season: season ?? this.season,
        episode: episode ?? this.episode,
        episodeTitle: episodeTitle ?? this.episodeTitle,
        quality: quality ?? this.quality,
        filePath: filePath ?? this.filePath,
        fileName: fileName ?? this.fileName,
        totalBytes: totalBytes ?? this.totalBytes,
        downloadedBytes: downloadedBytes ?? this.downloadedBytes,
        status: status ?? this.status,
        error: clearError ? null : (error ?? this.error),
        saveToGalleryOnComplete:
            saveToGalleryOnComplete ?? this.saveToGalleryOnComplete,
        savedToGallery: savedToGallery ?? this.savedToGallery,
        galleryLocation: galleryLocation ?? this.galleryLocation,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        magnetLink: magnetLink ?? this.magnetLink,
        infoHash: infoHash ?? this.infoHash,
        fileIdx: fileIdx ?? this.fileIdx,
        fileNameHint: fileNameHint ?? this.fileNameHint,
        sizeBytes: sizeBytes ?? this.sizeBytes,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'tmdb_id': tmdbId,
        'media_type': mediaType,
        'title': title,
        'poster_path': posterPath,
        'local_poster_path': localPosterPath,
        'backdrop_path': backdropPath,
        'imdb_id': imdbId,
        'season': season,
        'episode': episode,
        'episode_title': episodeTitle,
        'quality': quality,
        'file_path': filePath,
        'file_name': fileName,
        'total_bytes': totalBytes,
        'downloaded_bytes': downloadedBytes,
        'status': status,
        'error': error,
        'save_to_gallery_on_complete': saveToGalleryOnComplete,
        'saved_to_gallery': savedToGallery,
        'gallery_location': galleryLocation,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'magnet_link': magnetLink,
        'info_hash': infoHash,
        'file_idx': fileIdx,
        'file_name_hint': fileNameHint,
        'size_bytes': sizeBytes,
      };

  static int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  factory DownloadItem.fromJson(Map<String, dynamic> json) => DownloadItem(
        id: (json['id'] ?? '').toString(),
        tmdbId: _asInt(json['tmdb_id'] ?? json['tmdbId']) ?? 0,
        mediaType: (json['media_type'] ?? json['mediaType'] ?? 'movie').toString(),
        title: (json['title'] ?? 'Unknown').toString(),
        posterPath: json['poster_path'] as String?,
        localPosterPath: json['local_poster_path'] as String?,
        backdropPath: json['backdrop_path'] as String?,
        imdbId: json['imdb_id'] as String?,
        season: _asInt(json['season']),
        episode: _asInt(json['episode']),
        episodeTitle: json['episode_title'] as String?,
        quality: (json['quality'] ?? '').toString(),
        filePath: (json['file_path'] ?? '').toString(),
        fileName: (json['file_name'] ?? '').toString(),
        totalBytes: _asInt(json['total_bytes'] ?? json['totalBytes']) ?? 0,
        downloadedBytes:
            _asInt(json['downloaded_bytes'] ?? json['downloadedBytes']) ?? 0,
        status: (json['status'] ?? 'queued').toString(),
        error: json['error'] as String?,
        saveToGalleryOnComplete: json['save_to_gallery_on_complete'] == true,
        savedToGallery: json['saved_to_gallery'] == true,
        galleryLocation: json['gallery_location'] as String?,
        createdAt:
            DateTime.tryParse('${json['created_at'] ?? ''}') ?? DateTime.now(),
        updatedAt:
            DateTime.tryParse('${json['updated_at'] ?? ''}') ?? DateTime.now(),
        magnetLink: json['magnet_link'] as String?,
        infoHash: json['info_hash'] as String?,
        fileIdx: _asInt(json['file_idx']),
        fileNameHint: json['file_name_hint'] as String?,
        sizeBytes: _asInt(json['size_bytes']),
      );
}
