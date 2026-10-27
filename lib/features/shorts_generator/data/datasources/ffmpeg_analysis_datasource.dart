import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import '../../../../core/utils/logger.dart';
import '../../domain/entities/scene_info.dart';

class FfmpegAnalysisDatasource {
  Future<double> probeDuration(String videoPath) async {
    try {
      final info = await FFprobeKit.getMediaInformation(videoPath);
      final mediaInfo = info.getMediaInformation();
      if (mediaInfo == null) {
        AppLogger().w('probeDuration: mediaInfo is null for $videoPath');
        return 0;
      }
      final durationStr = mediaInfo.getDuration();
      if (durationStr != null && durationStr.isNotEmpty) {
        final d = double.tryParse(durationStr);
        if (d != null && d > 0) return d;
      }
      AppLogger().w('probeDuration: invalid duration "$durationStr" for $videoPath');
      return 0;
    } catch (e, s) {
      AppLogger().e('probeDuration failed', e, s);
      return 0;
    }
  }

  Future<List<SceneInfo>> detectScenes({
    required String videoPath,
    required double totalDuration,
    required double threshold,
    void Function(double progress)? onProgress,
  }) async {
    AppLogger().i('Scene detection start: threshold=$threshold');

    final command = '-i "$videoPath" -vf "select=\'gt(scene,$threshold)\',showinfo" -an -f null -';
    AppLogger().i('Scene detection command: $command');

    final outputDurationMs = (totalDuration * 1000).round();

    FFmpegKitConfig.enableStatisticsCallback((Statistics statistics) {
      if (outputDurationMs > 0) {
        final progress = (statistics.getTime() / outputDurationMs).clamp(0.0, 1.0);
        onProgress?.call(progress);
      }
    });

    final session = await FFmpegKit.execute(command);
    FFmpegKitConfig.enableStatisticsCallback(null);

    final returnCode = await session.getReturnCode();
    if (!ReturnCode.isSuccess(returnCode)) {
      AppLogger().e('Scene detection failed');
      return [SceneInfo(index: 0, startSeconds: 0, endSeconds: totalDuration, thumbnailPath: '')];
    }

    final logs = await session.getAllLogsAsString() ?? '';
    final ptsTimes = <double>[];

    for (final line in logs.split('\n')) {
      final match = RegExp(r'pts_time:([\d.]+)').firstMatch(line);
      if (match != null) {
        final t = double.tryParse(match.group(1)!);
        if (t != null && t > 0) {
          ptsTimes.add(t);
        }
      }
    }

    ptsTimes.sort();
    AppLogger().i('Found ${ptsTimes.length} scene changes');

    if (ptsTimes.isEmpty) {
      return [SceneInfo(index: 0, startSeconds: 0, endSeconds: totalDuration, thumbnailPath: '')];
    }

    final scenes = <SceneInfo>[];
    var prev = 0.0;
    for (var i = 0; i < ptsTimes.length; i++) {
      final start = prev;
      final end = ptsTimes[i];
      if (end - start > 0.5) {
        scenes.add(SceneInfo(index: scenes.length, startSeconds: start, endSeconds: end, thumbnailPath: ''));
      }
      prev = end;
    }

    if (totalDuration - prev > 0.5) {
      scenes.add(SceneInfo(index: scenes.length, startSeconds: prev, endSeconds: totalDuration, thumbnailPath: ''));
    }

    if (scenes.isEmpty) {
      scenes.add(SceneInfo(index: 0, startSeconds: 0, endSeconds: totalDuration, thumbnailPath: ''));
    }

    return scenes;
  }
}
