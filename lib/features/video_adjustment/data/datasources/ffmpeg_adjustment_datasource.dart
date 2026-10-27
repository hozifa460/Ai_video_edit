import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../core/utils/logger.dart';

class FfmpegAdjustmentDatasource {
  bool _cancelled = false;
  FFmpegSession? _activeSession;

  /// Runs a command and resolves when it finishes. Stores the live session so
  /// [cancel] can stop the native process immediately instead of only
  /// noticing cancellation after encoding already completed.
  Future<FFmpegSession> _run(String command) async {
    _cancelled = false;
    final completer = Completer<void>();
    final session = await FFmpegKit.executeAsync(
      command,
      (s) {
        if (!completer.isCompleted) completer.complete();
      },
      (log) {},
    );
    _activeSession = session;
    await completer.future;
    _activeSession = null;
    return session;
  }

  Future<double?> getVideoDuration(String videoPath) async {
    try {
      final cmd = '-i "$videoPath" 2>&1';
      final session = await FFmpegKit.execute(cmd);
      final output = await session.getAllLogsAsString() ?? '';
      final durMatch = RegExp(r'Duration:\s*(\d+):(\d+):(\d+)\.(\d+)').firstMatch(output);
      if (durMatch != null) {
        final h = int.parse(durMatch.group(1)!);
        final m = int.parse(durMatch.group(2)!);
        final s = int.parse(durMatch.group(3)!);
        final ms = int.parse(durMatch.group(4)!);
        return h * 3600.0 + m * 60.0 + s + ms / 100.0;
      }
      return null;
    } catch (e) {
      AppLogger().e('getVideoDuration error', e);
      return null;
    }
  }

  Future<void> applyAdjustments({
    required String inputPath,
    required String outputPath,
    required String filterString,
    required void Function(double) onProgress,
    bool isPreview = false,
  }) async {
    _cancelled = false;

    FFmpegKitConfig.enableStatisticsCallback((Statistics statistics) {
      final time = statistics.getTime();
      if (time > 0 && !_cancelled) {
        onProgress(time.toDouble());
      }
    });

    final args = StringBuffer()
      ..write('-i "$inputPath"')
      ..write(' $filterString');

    if (isPreview) {
      args.write(' -ss 5 -t 2 -vf "scale=iw/2:ih/2"');
    }

    args.write(' -c:a aac -b:a 192k -pix_fmt yuv420p -y "$outputPath"');

    AppLogger().i('Adjustment FFmpeg: ${args.toString()}');

    final session = await _run(args.toString());

    if (_cancelled) {
      throw Exception('Processing cancelled');
    }

    final rc = await session.getReturnCode();
    if (!ReturnCode.isSuccess(rc)) {
      final logs = await session.getAllLogsAsString() ?? 'Unknown error';
      throw Exception('FFmpeg failed: $logs');
    }

    onProgress(1.0);
  }

  Future<String> extractPreviewFrame(String videoPath, String? vf) async {
    final dir = await getApplicationCacheDirectory();
    final outputPath = '${dir.path}/adj_preview_${DateTime.now().millisecondsSinceEpoch}.jpg';

    final args = StringBuffer()
      ..write('-i "$videoPath"')
      ..write(' -ss 5 -vframes 1 -q:v 3');

    if (vf != null && vf.isNotEmpty) {
      args.write(' -vf "$vf"');
    }

    args.write(' -y "$outputPath"');

    AppLogger().i('Preview extract: ${args.toString()}');

    final session = await FFmpegKit.execute(args.toString());
    final rc = await session.getReturnCode();

    if (ReturnCode.isSuccess(rc) && File(outputPath).existsSync()) {
      return outputPath;
    }
    throw Exception('Failed to extract preview frame');
  }

  Future<void> exportVideo({
    required String inputPath,
    required String outputPath,
    required String filterString,
    required String quality,
    required void Function(double) onProgress,
  }) async {
    _cancelled = false;

    FFmpegKitConfig.enableStatisticsCallback((Statistics statistics) {
      final time = statistics.getTime();
      if (time > 0 && !_cancelled) {
        onProgress(time.toDouble());
      }
    });

    String qualityFlags;
    switch (quality) {
      case 'original':
        qualityFlags = filterString.isNotEmpty
            ? '-c:v libx264 -crf 18 -preset medium -c:a aac -b:a 192k'
            : '-c:v copy -c:a copy';
        break;
      case 'high':
        qualityFlags = '-c:v libx264 -crf 18 -preset medium -c:a aac -b:a 256k';
        break;
      case 'medium':
        qualityFlags = '-c:v libx264 -crf 23 -preset medium -c:a aac -b:a 192k';
        break;
      case 'compressed':
        qualityFlags = '-c:v libx264 -crf 28 -preset fast -c:a aac -b:a 128k';
        break;
      default:
        qualityFlags = '-c:v libx264 -crf 23 -preset medium -c:a aac -b:a 192k';
    }

    final args = StringBuffer()
      ..write('-i "$inputPath"')
      ..write(' $filterString')
      ..write(' $qualityFlags')
      ..write(' -pix_fmt yuv420p -y "$outputPath"');

    AppLogger().i('Export FFmpeg: ${args.toString()}');

    final session = await _run(args.toString());

    if (_cancelled) {
      throw Exception('Export cancelled');
    }

    final rc = await session.getReturnCode();
    if (!ReturnCode.isSuccess(rc)) {
      final logs = await session.getAllLogsAsString() ?? 'Unknown error';
      throw Exception('Export FFmpeg failed: $logs');
    }

    onProgress(1.0);
  }

  void cancel() {
    _cancelled = true;
    // Stop the running encode immediately; the pending await resolves via
    // the session's complete callback and the caller throws 'cancelled'.
    _activeSession?.cancel();
  }
}
