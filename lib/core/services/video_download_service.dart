import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../utils/logger.dart';

class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class DownloadProgress {
  final double progress;
  final int receivedBytes;
  final int totalBytes;
  final double speedBytesPerSec;
  final String statusText;

  const DownloadProgress({
    required this.progress,
    required this.receivedBytes,
    required this.totalBytes,
    required this.speedBytesPerSec,
    required this.statusText,
  });
}

class _SpeedTracker {
  int _lastBytes = 0;
  DateTime _lastTime = DateTime.now();
  double _smoothed = 0;

  double update(int receivedBytes, {bool force = false}) {
    final now = DateTime.now();
    final elapsed = now.difference(_lastTime).inMilliseconds / 1000.0;
    if (!force && elapsed < 0.5 && receivedBytes > 0) return _smoothed;
    final delta = receivedBytes - _lastBytes;
    if (delta > 0 && elapsed > 0) {
      _smoothed = _smoothed * 0.7 + (delta / elapsed) * 0.3;
    } else if (delta == 0 && elapsed > 2) {
      _smoothed = 0;
    }
    _lastBytes = receivedBytes;
    _lastTime = now;
    return _smoothed;
  }

  void reset() {
    _lastBytes = 0;
    _lastTime = DateTime.now();
    _smoothed = 0;
  }
}

class YoutubeQualityOption {
  final String label;
  final int width;
  final int height;
  final bool isMuxed;
  final String? streamUrl;
  final StreamInfo? streamInfo;

  const YoutubeQualityOption({
    required this.label,
    required this.width,
    required this.height,
    required this.isMuxed,
    this.streamUrl,
    this.streamInfo,
  });
}

class VideoDownloadService {
  static bool isYoutubeUrl(String url) => _parseYoutubeId(url) != null;

  static bool isUrl(String path) => path.startsWith('http://') || path.startsWith('https://');

  static Future<String> downloadVideo(
    String url, {
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      throw Exception('Invalid URL. Must start with http:// or https://');
    }

    final client = HttpClient()
      ..userAgent = 'AiVideoStudio/1.0'
      ..autoUncompress = true;

    try {
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      request.maxRedirects = 5;

      final response = await request.close().timeout(const Duration(minutes: 5));

      if (response.statusCode != 200) {
        throw Exception('Server returned HTTP ${response.statusCode}');
      }

      final contentType = response.headers.contentType?.mimeType ?? '';
      if (!contentType.startsWith('video/') && contentType.isNotEmpty) {
        AppLogger().w('URL content-type is "$contentType", not video/*');
      }

      final filename = _extractFilename(uri, response.headers);
      final tempDir = await getApplicationDocumentsDirectory();
      final outputPath = '${tempDir.path}/$filename';
      final outputFile = File(outputPath);

      if (await outputFile.exists()) {
        await outputFile.delete();
      }

      final totalBytes = response.headers.contentLength;
      var received = 0;

      final sink = outputFile.openWrite();
      try {
        await for (final chunk in response) {
          if (cancelToken?.isCancelled ?? false) {
            throw CancelledDownloadException();
          }
          sink.add(chunk);
          received += chunk.length;
          if (totalBytes > 0) {
            onProgress?.call(received / totalBytes);
          }
        }
        await sink.flush();
      } catch (e) {
        await sink.close();
        await outputFile.delete();
        rethrow;
      } finally {
        await sink.close();
      }

      final fileSize = await outputFile.length();
      if (fileSize < 1024) {
        await outputFile.delete();
        throw Exception('Downloaded file too small ($fileSize bytes)');
      }

      AppLogger().i('Downloaded $url -> $outputPath (${(fileSize / 1048576).toStringAsFixed(1)} MB)');
      return outputPath;
    } finally {
      client.close(force: true);
    }
  }

  static Future<List<YoutubeQualityOption>> getAvailableQualities(String url) async {
    final videoId = _parseYoutubeId(url);
    if (videoId == null) throw Exception('Could not parse YouTube video ID from URL');

    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streams.getManifest(videoId);
      final options = <YoutubeQualityOption>[];

      for (final m in manifest.muxed) {
        final label = '${m.videoResolution.height}p (muxed)';
        options.add(YoutubeQualityOption(
          label: label,
          width: m.videoResolution.width,
          height: m.videoResolution.height,
          isMuxed: true,
          streamUrl: m.url.toString(),
          streamInfo: m,
        ));
      }

      options.sort((a, b) => b.height.compareTo(a.height));
      return options;
    } finally {
      yt.close();
    }
  }

  static Future<String> downloadAndMergeYoutube(
    String url,
    YoutubeQualityOption quality,
    String title, {
    void Function(DownloadProgress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final videoId = _parseYoutubeId(url);
    if (videoId == null) throw Exception('Invalid YouTube URL');

    final tempDir = await getApplicationDocumentsDirectory();
    final safeTitle = title.replaceAll(RegExp(r'[^\w\- ]'), '_').trim().replaceAll(' ', '_');

    if (quality.isMuxed && quality.streamUrl != null) {
      final outputPath = '${tempDir.path}/${safeTitle}_${quality.height}p.mp4';
      AppLogger().i('Downloading muxed YouTube stream (${quality.label})...');
      await _downloadStream(quality.streamUrl!, outputPath, (p, received) {
        onProgress?.call(DownloadProgress(
          progress: p, receivedBytes: received, totalBytes: 0,
          speedBytesPerSec: 0, statusText: 'Downloading...',
        ));
      }, cancelToken);
      if (cancelToken?.isCancelled ?? false) throw CancelledDownloadException();
      onProgress?.call(const DownloadProgress(
        progress: 1.0, receivedBytes: 0, totalBytes: 0,
        speedBytesPerSec: 0, statusText: 'Complete',
      ));
      final fileSize = await File(outputPath).length();
      AppLogger().i('YouTube muxed downloaded: $outputPath (${(fileSize / 1048576).toStringAsFixed(1)} MB)');
      return outputPath;
    }

    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streams.getManifest(videoId);
      final audioStreams = manifest.audioOnly;
      if (audioStreams.isEmpty) throw Exception('No audio stream available');

      final videoStream = manifest.videoOnly.firstWhere(
        (v) => v.videoResolution.height == quality.height,
        orElse: () => manifest.videoOnly.withHighestBitrate(),
      );
      final audioStream = audioStreams.withHighestBitrate();

      final videoPath = '${tempDir.path}/${safeTitle}_video.${videoStream.container.name}';
      final audioPath = '${tempDir.path}/${safeTitle}_audio.${audioStream.container.name}';
      final outputPath = '${tempDir.path}/${safeTitle}_${quality.height}p.mp4';

      final totalBytes = videoStream.size.totalBytes + audioStream.size.totalBytes;
      final videoBytes = videoStream.size.totalBytes;
      final speedTracker = _SpeedTracker();

      AppLogger().i('downloadAndMergeYoutube: starting video download via yt client...');
      await _downloadViaYt(yt, videoStream, videoPath, (p, received) {
        final spd = speedTracker.update(received);
        onProgress?.call(DownloadProgress(
          progress: p * 0.35, receivedBytes: received, totalBytes: totalBytes,
          speedBytesPerSec: spd, statusText: 'Downloading video...',
        ));
      }, cancelToken);
      if (cancelToken?.isCancelled ?? false) throw CancelledDownloadException();
      AppLogger().i('downloadAndMergeYoutube: video download complete');

      AppLogger().i('downloadAndMergeYoutube: starting audio download via yt client...');
      speedTracker.reset();
      await _downloadViaYt(yt, audioStream, audioPath, (p, received) {
        final spd = speedTracker.update(received);
        onProgress?.call(DownloadProgress(
          progress: 0.35 + p * 0.25, receivedBytes: videoBytes + received, totalBytes: totalBytes,
          speedBytesPerSec: spd, statusText: 'Downloading audio...',
        ));
      }, cancelToken);
      if (cancelToken?.isCancelled ?? false) throw CancelledDownloadException();
      AppLogger().i('downloadAndMergeYoutube: audio download complete');

      AppLogger().i('Merging video+audio...');
      onProgress?.call(DownloadProgress(
        progress: 0.6, receivedBytes: totalBytes, totalBytes: totalBytes,
        speedBytesPerSec: 0, statusText: 'Merging video & audio...',
      ));

      var session = await _tryMergeWithCopy(videoPath, audioPath, outputPath);
      if (session == null) {
        AppLogger().w('Copy merge failed, trying forced mp4 demuxer...');
        onProgress?.call(DownloadProgress(
          progress: 0.7, receivedBytes: totalBytes, totalBytes: totalBytes,
          speedBytesPerSec: 0, statusText: 'Merging (retry)...',
        ));
        session = await _tryMergeWithForcedMp4(videoPath, audioPath, outputPath);
      }
      if (session == null) {
        AppLogger().w('Forced mp4 merge failed, trying re-encode fallback...');
        onProgress?.call(DownloadProgress(
          progress: 0.8, receivedBytes: totalBytes, totalBytes: totalBytes,
          speedBytesPerSec: 0, statusText: 'Merging (re-encode)...',
        ));
        session = await _tryMergeWithReencode(videoPath, audioPath, outputPath);
      }

      if (session == null || !ReturnCode.isSuccess(await session.getReturnCode())) {
        final logs = session != null ? (await session.getAllLogsAsString()) ?? '' : 'session failed';
        final failTrace = session != null ? await session.getFailStackTrace() ?? '' : '';
        AppLogger().e('YouTube merge failed: $logs\n$failTrace');
        throw Exception('Failed to merge video+audio streams');
      }

      onProgress?.call(const DownloadProgress(
        progress: 1.0, receivedBytes: 0, totalBytes: 0,
        speedBytesPerSec: 0, statusText: 'Complete',
      ));
      await File(videoPath).delete();
      await File(audioPath).delete();

      final fileSize = await File(outputPath).length();
      AppLogger().i('YouTube merged: $outputPath (${(fileSize / 1048576).toStringAsFixed(1)} MB)');
      return outputPath;
    } finally {
      yt.close();
    }
  }

  static Future<dynamic> _tryMergeWithCopy(String videoPath, String audioPath, String outputPath) async {
    final cmd = '-i "$videoPath" -i "$audioPath" '
        '-c:v copy -c:a aac -b:a 128k '
        '-map 0:v:0 -map 1:a:0 -shortest -movflags +faststart '
        '-y "$outputPath"';
    final session = await FFmpegKit.execute(cmd);
    if (ReturnCode.isSuccess(await session.getReturnCode())) return session;
    final logs = await session.getAllLogsAsString() ?? '';
    final errLines = logs.split('\n').where((l) => l.contains('Error') || l.contains('error') || l.contains('Invalid') || l.contains('moov'));
    if (errLines.isNotEmpty) AppLogger().w('Copy merge failed: ${errLines.take(3).join('; ')}');
    return null;
  }

  static Future<dynamic> _tryMergeWithForcedMp4(String videoPath, String audioPath, String outputPath) async {
    final cmd = '-f mp4 -fflags +genpts -analyzeduration 2147483647 '
        '-i "$videoPath" -i "$audioPath" '
        '-c:v copy -c:a aac -b:a 128k '
        '-map 0:v:0 -map 1:a:0 -shortest -movflags +faststart '
        '-y "$outputPath"';
    final session = await FFmpegKit.execute(cmd);
    if (ReturnCode.isSuccess(await session.getReturnCode())) return session;
    final logs = await session.getAllLogsAsString() ?? '';
    final errLines = logs.split('\n').where((l) => l.contains('Error') || l.contains('error') || l.contains('Invalid') || l.contains('moov'));
    if (errLines.isNotEmpty) AppLogger().w('Forced mp4 merge failed: ${errLines.take(3).join('; ')}');
    return null;
  }

  static Future<dynamic> _tryMergeWithReencode(String videoPath, String audioPath, String outputPath) async {
    final cmd = '-i "$videoPath" -i "$audioPath" '
        '-c:v libx264 -preset fast -crf 18 '
        '-c:a aac -b:a 128k '
        '-map 0:v:0 -map 1:a:0 -shortest -movflags +faststart '
        '-y "$outputPath"';
    final session = await FFmpegKit.execute(cmd);
    if (ReturnCode.isSuccess(await session.getReturnCode())) return session;
    final logs = await session.getAllLogsAsString() ?? '';
    final errLines = logs.split('\n').where((l) => l.contains('Error') || l.contains('error') || l.contains('Invalid') || l.contains('moov') || l.contains('moov'));
    if (errLines.isNotEmpty) AppLogger().w('Re-encode merge failed: ${errLines.take(3).join('; ')}');
    final failTrace = await session.getFailStackTrace() ?? '';
    if (failTrace.isNotEmpty) AppLogger().w('Re-encode fail trace: $failTrace');
    return null;
  }

  static Future<void> _downloadStream(String url, String path, void Function(double, int) onProgress, CancelToken? cancelToken) async {
    final uri = Uri.parse(url);
    final client = HttpClient()
      ..userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
      ..autoUncompress = true;
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      final response = await request.close();

      if (response.statusCode != 200) {
        final body = await response.transform(utf8.decoder).join();
        AppLogger().e('YouTube stream HTTP ${response.statusCode}: ${body.length > 200 ? body.substring(0, 200) : body}');
        throw Exception('YouTube stream returned HTTP ${response.statusCode}');
      }

      final ct = response.headers.contentType?.mimeType ?? 'unknown';
      AppLogger().i('Stream content-type: $ct');
      if (!ct.startsWith('video/') && ct != 'unknown' && !ct.startsWith('application/octet-stream') && !ct.startsWith('binary/')) {
        AppLogger().w('Unexpected content-type "$ct" for stream URL');
      }

      final total = response.headers.contentLength;
      var received = 0;

      final file = File(path);
      if (await file.exists()) await file.delete();
      final sink = file.openWrite();

      try {
        await for (final chunk in response) {
          if (cancelToken?.isCancelled ?? false) throw CancelledDownloadException();
          sink.add(chunk);
          received += chunk.length;
          final progress = total > 0
              ? received / total.toDouble()
              : received / (received + 10485760.0);
          onProgress(progress.clamp(0.0, 1.0), received);
        }
        await sink.flush();
      } catch (e) {
        await sink.close();
        await file.delete();
        rethrow;
      } finally {
        await sink.close();
      }

      final fileSize = await File(path).length();
      if (fileSize < 4096) {
        AppLogger().w('Downloaded file too small ($fileSize bytes) — might be invalid');
      }

      await _validateMediaFile(path);
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _validateMediaFile(String path) async {
    final file = File(path);
    if (!await file.exists()) return;
    final bytes = await file.openRead(0, 16).first;
    if (bytes.isEmpty) {
      await file.delete();
      throw Exception('Downloaded file is empty');
    }
    final header = bytes;
    bool listStartsWith(List<int> data, List<int> prefix) {
      if (data.length < prefix.length) return false;
      for (var i = 0; i < prefix.length; i++) {
        if (data[i] != prefix[i]) return false;
      }
      return true;
    }

    final isValid = listStartsWith(header, [0x66, 0x74, 0x79, 0x70]) || // ftyp (MP4)
        listStartsWith(header, [0x1A, 0x45, 0xDF, 0xA3]) || // WebM/Matroska
        listStartsWith(header, [0x00, 0x00, 0x00]) || // MP4 with 4-byte box size prefix
        listStartsWith(header, [0x52, 0x49, 0x46, 0x46]) || // AVI
        listStartsWith(header, [0x30, 0x26, 0xB2, 0x75]) || // ASF/WMV
        listStartsWith(header, [0x47]); // MPEG TS
    if (!isValid) {
      final hexStr = header.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      AppLogger().w('Unknown file signature: $hexStr (path: $path)');
    }
  }

  static Future<void> _downloadViaYt(
    YoutubeExplode yt,
    StreamInfo streamInfo,
    String path,
    void Function(double progress, int receivedBytes) onProgress,
    CancelToken? cancelToken,
  ) async {
    final totalBytes = streamInfo.size.totalBytes;
    var received = 0;
    var loggedStart = false;

    final file = File(path);
    if (await file.exists()) await file.delete();
    final sink = file.openWrite();

    try {
      final stream = yt.videos.streams.get(streamInfo).timeout(
        const Duration(seconds: 30),
        onTimeout: (sink) => sink.addError(
          TimeoutException('Download timed out: no data received for 30 seconds'),
          StackTrace.current,
        ),
      );
      await for (final chunk in stream) {
        if (cancelToken?.isCancelled ?? false) throw CancelledDownloadException();
        sink.add(chunk);
        received += chunk.length;
        if (!loggedStart) {
          loggedStart = true;
          AppLogger().i('_downloadViaYt: received first chunk (${chunk.length} bytes), totalBytes=$totalBytes');
        }
        final progress = totalBytes > 0
            ? received / totalBytes
            : received / (received + 10485760.0);
        onProgress(progress.clamp(0.0, 1.0), received);
      }
      await sink.flush();
      AppLogger().i('_downloadViaYt: download complete, $received bytes received');
    } catch (e) {
      await sink.close();
      await file.delete();
      AppLogger().e('_downloadViaYt: download failed: $e');
      rethrow;
    } finally {
      await sink.close();
    }

    final fileSize = await File(path).length();
    if (fileSize < 4096) {
      AppLogger().w('Downloaded file too small ($fileSize bytes) via yt client');
    }
    await _validateMediaFile(path);
  }

  static String? _parseYoutubeId(String url) {
    final patterns = [
      RegExp(r'youtube\.com/watch\?.*(?:[?&])?v=([a-zA-Z0-9_-]{11})'),
      RegExp(r'youtu\.be/([a-zA-Z0-9_-]{11})'),
      RegExp(r'youtube\.com/embed/([a-zA-Z0-9_-]{11})'),
      RegExp(r'youtube\.com/shorts/([a-zA-Z0-9_-]{11})'),
      RegExp(r'youtube\.com/live/([a-zA-Z0-9_-]{11})'),
      RegExp(r'youtube\.com/v/([a-zA-Z0-9_-]{11})'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(url);
      if (m != null) return m.group(1);
    }
    return null;
  }

  static String _extractFilename(Uri uri, HttpHeaders headers) {
    final disposition = headers.value('content-disposition');
    if (disposition != null) {
      final eq = disposition.indexOf('=');
      if (eq > 0 && eq < disposition.length - 1) {
        final raw = disposition.substring(eq + 1).trim().replaceAll('"', '').replaceAll("'", '');
        if (raw.isNotEmpty) return raw;
      }
    }

    final path = uri.path;
    if (path.isNotEmpty && path.contains('.')) {
      final last = path.split('/').last;
      if (last.isNotEmpty && const ['mp4', 'mov', 'mkv', 'avi', 'webm', '3gp'].any((e) => last.endsWith(e))) {
        return last;
      }
    }

    final ct = headers.contentType;
    final ext = ct != null ? _extensionForMime(ct.mimeType) : 'mp4';
    final baseName = uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? 'video';
    final clean = baseName.replaceAll(RegExp(r'[^\w\-.]'), '_');
    return '${clean}_${DateTime.now().millisecondsSinceEpoch}.$ext';
  }

  static String _extensionForMime(String mime) {
    switch (mime) {
      case 'video/mp4': return 'mp4';
      case 'video/quicktime': return 'mov';
      case 'video/x-msvideo': return 'avi';
      case 'video/webm': return 'webm';
      case 'video/x-matroska': return 'mkv';
      case 'video/3gpp': return '3gp';
      default: return 'mp4';
    }
  }
}

class CancelledDownloadException implements Exception {
  @override
  String toString() => 'Download cancelled by user';
}