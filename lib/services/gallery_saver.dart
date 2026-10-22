import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

// ── GallerySaver ──────────────────────────────────────────────────────────────
//
// Exports a permanently downloaded movie or episode into the device's public
// Gallery ("Movies/InFlex") via MainActivity's "inflex/gallery" channel:
//
//   • Android 10+ (API 29–36): MediaStore.Video.Media with IS_PENDING — zero
//     permissions needed, immediately visible in Google Photos / Samsung
//     Gallery / MIUI Gallery / VLC / MX Player, and kept permanently on the
//     device even if InFlex is uninstalled.
//   • Android 7–9 (API 24–28): requests WRITE_EXTERNAL_STORAGE once, copies to
//     Movies/InFlex and triggers MediaScannerConnection.scanFile().
//   • Other platforms: copies into the user Downloads directory.

class GallerySaveResult {
  final bool ok;
  final String? location;
  final String? error;

  const GallerySaveResult({
    required this.ok,
    this.location,
    this.error,
  });
}

class GallerySaver {
  GallerySaver._();

  static const MethodChannel _channel = MethodChannel('inflex/gallery');

  static String mimeTypeFor(String fileName) {
    final dot = fileName.lastIndexOf('.');
    final ext = dot >= 0 ? fileName.substring(dot + 1).toLowerCase() : '';
    switch (ext) {
      case 'mp4':
      case 'm4v':
        return 'video/mp4';
      case 'mkv':
        return 'video/x-matroska';
      case 'webm':
        return 'video/webm';
      case 'avi':
        return 'video/x-msvideo';
      case 'mov':
        return 'video/quicktime';
      case 'ts':
      case 'm2ts':
        return 'video/mp2t';
      case 'flv':
        return 'video/x-flv';
      case 'wmv':
        return 'video/x-ms-wmv';
      default:
        return 'video/mp4';
    }
  }

  /// Copies [filePath] into the device Gallery (`Movies/InFlex/[displayName]`).
  static Future<GallerySaveResult> saveVideo({
    required String filePath,
    required String displayName,
  }) async {
    final source = File(filePath);
    if (!await source.exists()) {
      return const GallerySaveResult(
        ok: false,
        error: 'Downloaded video file does not exist on device',
      );
    }

    if (Platform.isAndroid) {
      try {
        final raw = await _channel.invokeMapMethod<String, dynamic>(
          'saveVideoToGallery',
          <String, dynamic>{
            'filePath': filePath,
            'displayName': displayName,
            'mimeType': mimeTypeFor(displayName),
          },
        );
        if (raw == null) {
          return const GallerySaveResult(
            ok: false,
            error: 'No response from Android MediaStore',
          );
        }
        final ok = raw['ok'] == true;
        return GallerySaveResult(
          ok: ok,
          location: raw['location'] as String?,
          error: raw['error'] as String?,
        );
      } catch (e) {
        debugPrint('[GallerySaver] native save failed: $e');
        return GallerySaveResult(ok: false, error: '$e');
      }
    }

    // Fallback for desktop / non-Android builds.
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads == null) {
        return const GallerySaveResult(
          ok: false,
          error: 'Could not locate device Downloads folder',
        );
      }
      final targetDir = Directory('${downloads.path}/InFlex');
      await targetDir.create(recursive: true);
      final targetFile = File('${targetDir.path}/$displayName');
      await source.copy(targetFile.path);
      return GallerySaveResult(ok: true, location: targetFile.path);
    } catch (e) {
      return GallerySaveResult(ok: false, error: '$e');
    }
  }

  /// Queries free storage bytes on the volume backing [path] (Android).
  static Future<int?> freeDiskBytes(String path) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<int>(
        'getFreeDiskBytes',
        <String, dynamic>{'path': path},
      );
    } catch (_) {
      return null;
    }
  }
}
