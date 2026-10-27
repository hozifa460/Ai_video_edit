import 'dart:async';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import '../../../../core/errors/failures.dart';
import '../../../../core/services/face_detection_service.dart';
import '../../../../core/utils/logger.dart';
import '../../../../core/utils/result.dart';
import '../../domain/entities/clip_suggestion.dart';
import '../../domain/entities/export_settings.dart';
import '../../domain/entities/reframe_settings.dart';
import '../../domain/entities/scene_info.dart';
import '../../domain/entities/shorts_project.dart';
import '../../domain/entities/video_segment.dart';
import '../../domain/repositories/shorts_repository.dart';
import '../datasources/ffmpeg_analysis_datasource.dart';
import '../datasources/ffmpeg_export_datasource.dart';

class ShortsRepositoryImpl implements ShortsRepository {
  final FfmpegAnalysisDatasource _analysis;
  final FfmpegExportDatasource _export;

  ShortsRepositoryImpl()
      : _analysis = FfmpegAnalysisDatasource(),
        _export = FfmpegExportDatasource();

  @override
  Future<Result<ShortsProject>> analyzeVideo({
    required String videoPath,
    required ExportSettings settings,
    void Function(double progress, String stage)? onProgress,
  }) async {
    try {
      onProgress?.call(0, 'Probing video duration...');
      final totalDuration = await _analysis.probeDuration(videoPath);
      AppLogger().i('Video duration: ${totalDuration}s, mode: ${settings.cuttingMode}');

      if (totalDuration <= 0) {
        return AppError(VideoProcessingFailure(message: 'Could not read video duration. The file may be missing or corrupted.'));
      }

      List<SceneInfo> scenes;
      List<ClipSuggestion> suggestions;

      switch (settings.cuttingMode) {
        case CuttingMode.interval:
          onProgress?.call(0.2, 'Splitting into intervals...');
          scenes = _generateIntervalScenes(totalDuration, settings.maxDurationSeconds);
          suggestions = _generateIntervalSuggestions(totalDuration, settings);
          AppLogger().i('Interval mode: ${scenes.length} intervals, ${suggestions.length} suggestions');

        case CuttingMode.smartAudio:
          onProgress?.call(0.1, 'Detecting silence...');
          final silenceSegments = await _detectSilence(videoPath, totalDuration, onProgress);
          onProgress?.call(0.6, 'Building speech clips...');
          scenes = _generateIntervalScenes(totalDuration, settings.maxDurationSeconds);
          suggestions = _generateSmartAudioSuggestions(totalDuration, silenceSegments, settings);
          AppLogger().i('SmartAudio mode: ${silenceSegments.length} silence gaps, ${suggestions.length} suggestions');

        case CuttingMode.scene:
          onProgress?.call(0.1, 'Analyzing scenes...');
          scenes = await _analysis.detectScenes(
            videoPath: videoPath,
            totalDuration: totalDuration,
            threshold: 0.3,
            onProgress: (p) {
              onProgress?.call(0.1 + p * 0.8, 'Analyzing scenes...');
            },
          );
          onProgress?.call(0.9, 'Ranking clips...');
          suggestions = _generateSuggestions(scenes, settings, totalDuration);

        case CuttingMode.manual:
          onProgress?.call(0.2, 'Preparing manual clips...');
          scenes = _generateManualScenes(totalDuration, settings);
          suggestions = _generateManualSuggestions(totalDuration, settings);
          AppLogger().i('Manual mode: ${scenes.length} scenes, ${suggestions.length} suggestions');

        case CuttingMode.ai:
          onProgress?.call(0.1, 'Analyzing scenes...');
          scenes = await _analysis.detectScenes(
            videoPath: videoPath,
            totalDuration: totalDuration,
            threshold: 0.3,
            onProgress: (p) {
              onProgress?.call(0.1 + p * 0.4, 'Analyzing scenes...');
            },
          );
          onProgress?.call(0.5, 'Analyzing audio activity...');
          final silenceSegments = await _detectSilence(videoPath, totalDuration, (p, _) {
            onProgress?.call(0.5 + p * 0.35, 'Analyzing audio activity...');
          });
          onProgress?.call(0.85, 'Scoring with AI...');
          suggestions = _generateAiSuggestions(scenes, silenceSegments, settings, totalDuration);
          AppLogger().i('AI mode: ${scenes.length} scenes, ${silenceSegments.length} silence gaps, ${suggestions.length} suggestions');
      }

      onProgress?.call(1.0, 'Complete');

      return Success(ShortsProject(
        videoPath: videoPath,
        totalDuration: totalDuration,
        exportSettings: settings,
        scenes: scenes,
        suggestions: suggestions,
      ));
    } catch (e, stack) {
      AppLogger().e('Analysis failed', e, stack);
      return AppError(VideoProcessingFailure(message: e.toString()));
    }
  }

  Future<List<SceneInfo>> _detectSilence(
    String videoPath,
    double totalDuration,
    void Function(double progress, String stage)? onProgress,
  ) async {
    final silenceSegments = <SceneInfo>[];
    final command = '-i "$videoPath" -af silencedetect=noise=-26dB:d=0.8 -f null -';
    AppLogger().i('Silence detection: $command');

    FFmpegKitConfig.enableStatisticsCallback((Statistics s) {
      if (totalDuration > 0) {
        onProgress?.call((0.1 + (s.getTime() / (totalDuration * 1000)).clamp(0.0, 0.5) * 0.5), 'Detecting silence...');
      }
    });

    final session = await FFmpegKit.execute(command);
    FFmpegKitConfig.enableStatisticsCallback(null);
    final logs = await session.getAllLogsAsString() ?? '';

    double? silenceStart;
    for (final line in logs.split('\n')) {
      if (line.contains('silence_start:')) {
        final m = RegExp(r'silence_start:\s*([\d.]+)').firstMatch(line);
        if (m != null) silenceStart = double.tryParse(m.group(1)!);
      } else if (line.contains('silence_end:')) {
        final m = RegExp(r'silence_end:\s*([\d.]+)').firstMatch(line);
        if (m != null && silenceStart != null) {
          final end = double.tryParse(m.group(1)!) ?? 0;
          if (end - silenceStart > 0.3) {
            silenceSegments.add(SceneInfo(index: silenceSegments.length, startSeconds: silenceStart, endSeconds: end, thumbnailPath: ''));
          }
          silenceStart = null;
        }
      }
    }

    AppLogger().i('Found ${silenceSegments.length} silence segments');
    return silenceSegments;
  }

  List<SceneInfo> _generateIntervalScenes(double totalDuration, double segmentDur) {
    final scenes = <SceneInfo>[];
    for (var start = 0.0; start < totalDuration; start += segmentDur) {
      final end = (start + segmentDur) > totalDuration ? totalDuration : start + segmentDur;
      if (end - start >= 5) {
        scenes.add(SceneInfo(index: scenes.length, startSeconds: start, endSeconds: end, thumbnailPath: ''));
      }
    }
    return scenes;
  }

  List<ClipSuggestion> _generateIntervalSuggestions(double totalDuration, ExportSettings settings) {
    final suggestions = <ClipSuggestion>[];
    final step = totalDuration / settings.clipCount;
    for (var i = 0; i < settings.clipCount; i++) {
      final start = i * step;
      final end = (i + 1) * step > totalDuration ? totalDuration : (i + 1) * step;
      if (end - start >= 5) {
        suggestions.add(ClipSuggestion(
          segment: VideoSegment(startSeconds: start, endSeconds: end),
          score: 1.0,
          label: 'Part ${i + 1}',
        ));
      }
    }
    return suggestions;
  }

  List<ClipSuggestion> _generateSmartAudioSuggestions(
    double totalDuration,
    List<SceneInfo> silenceSegments,
    ExportSettings settings,
  ) {
    // Merge silences < 8s (breathing, thinking, brief pauses → same conversation).
    // Split only when silence gap >= 8s (topic change, new conversation).
    const topicBoundarySec = 8.0;
    const minSegmentSec = 5.0;

    final segments = <({double start, double end})>[];
    var segStart = 0.0;
    var prevEnd = 0.0;

    for (final s in silenceSegments) {
      final gap = s.startSeconds - prevEnd;
      if (gap >= topicBoundarySec) {
        if (prevEnd - segStart >= minSegmentSec) {
          segments.add((start: segStart, end: prevEnd));
        }
        segStart = s.endSeconds;
      }
      prevEnd = s.endSeconds;
    }
    if (totalDuration - segStart >= minSegmentSec) {
      segments.add((start: segStart, end: totalDuration));
    }

    // Sort by duration descending (longest conversation = most content = best)
    segments.sort((a, b) => (b.end - b.start).compareTo(a.end - a.start));

    final suggestions = <ClipSuggestion>[];
    for (var i = 0; i < segments.length && suggestions.length < settings.clipCount; i++) {
      final seg = segments[i];
      final dur = seg.end - seg.start;
      final score = (dur / 120).clamp(0.3, 1.0);
      suggestions.add(ClipSuggestion(
        segment: VideoSegment(startSeconds: seg.start, endSeconds: seg.end),
        score: score,
        label: dur >= 180 ? 'Full Conversation ${i + 1}' : 'Conversation ${i + 1}',
      ));
    }

    // Fallback: interval clips only if NO conversation segments found
    if (suggestions.isEmpty) {
      final clipDur = (totalDuration / settings.clipCount).clamp(5.0, totalDuration);
      for (var i = 0; i < settings.clipCount; i++) {
        final start = i * clipDur;
        final end = (start + clipDur) > totalDuration ? totalDuration : start + clipDur;
        if (end - start >= 5) {
          suggestions.add(ClipSuggestion(
            segment: VideoSegment(startSeconds: start, endSeconds: end),
            score: 0.5,
            label: 'Part ${i + 1}',
          ));
        }
      }
    }

    AppLogger().i('SmartAudio: ${segments.length} conversation segments, ${suggestions.length} suggestions');
    return suggestions;
  }

  List<SceneInfo> _generateManualScenes(double totalDuration, ExportSettings settings) {
    final clipDur = (totalDuration / settings.clipCount).clamp(5.0, settings.maxDurationSeconds.toDouble());
    final scenes = <SceneInfo>[];
    for (var i = 0; i < settings.clipCount; i++) {
      final start = i * clipDur;
      final end = (start + clipDur) > totalDuration ? totalDuration : start + clipDur;
      if (end - start >= 5) {
        scenes.add(SceneInfo(index: scenes.length, startSeconds: start, endSeconds: end, thumbnailPath: ''));
      }
    }
    return scenes;
  }

  List<ClipSuggestion> _generateManualSuggestions(double totalDuration, ExportSettings settings) {
    final suggestions = <ClipSuggestion>[];
    final clipDur = (totalDuration / settings.clipCount).clamp(5.0, settings.maxDurationSeconds.toDouble());
    for (var i = 0; i < settings.clipCount; i++) {
      final start = i * clipDur;
      final end = (start + clipDur) > totalDuration ? totalDuration : start + clipDur;
      if (end - start >= 5) {
        suggestions.add(ClipSuggestion(
          segment: VideoSegment(startSeconds: start, endSeconds: end),
          score: 1.0,
          label: 'Edit clip ${i + 1}',
        ));
      }
    }
    return suggestions;
  }

  List<ClipSuggestion> _generateAiSuggestions(
    List<SceneInfo> scenes,
    List<SceneInfo> silenceSegments,
    ExportSettings settings,
    double totalDuration,
  ) {
    final suggestions = <ClipSuggestion>[];
    final maxDur = settings.maxDurationSeconds;

    for (final scene in scenes) {
      if (scene.durationSeconds < 5) continue;

      final silenceInScene = silenceSegments
          .where((s) => s.startSeconds < scene.endSeconds && s.endSeconds > scene.startSeconds)
          .fold<double>(0, (sum, s) {
        final overlapStart = s.startSeconds > scene.startSeconds ? s.startSeconds : scene.startSeconds;
        final overlapEnd = s.endSeconds < scene.endSeconds ? s.endSeconds : scene.endSeconds;
        return sum + (overlapEnd - overlapStart);
      });

      final audioRatio = scene.durationSeconds > 0
          ? 1.0 - (silenceInScene / scene.durationSeconds).clamp(0.0, 1.0)
          : 0.5;

      final durationScore = (scene.durationSeconds / 60).clamp(0.2, 1.0);
      final position = scene.index / scenes.length;
      final positionScore = 0.5 + (position < 0.5 ? position * 2 : (1 - position) * 2) * 0.5;
      final score = durationScore * 0.3 + positionScore * 0.3 + audioRatio * 0.4;

      if (scene.durationSeconds <= maxDur) {
        suggestions.add(ClipSuggestion(
          segment: VideoSegment(startSeconds: scene.startSeconds, endSeconds: scene.endSeconds),
          score: score,
          label: 'AI pick ${scene.index + 1}',
        ));
      } else {
        var start = scene.startSeconds;
        while (start < scene.endSeconds) {
          final end = (start + maxDur) > scene.endSeconds ? scene.endSeconds : start + maxDur;
          if (end - start >= 5) {
            suggestions.add(ClipSuggestion(
              segment: VideoSegment(startSeconds: start, endSeconds: end),
              score: score,
              label: 'AI pick ${scene.index + 1}',
            ));
          }
          start = end;
        }
      }
    }

    suggestions.sort((a, b) => b.score.compareTo(a.score));
    return suggestions.take(settings.clipCount).toList();
  }

  List<ClipSuggestion> _generateSuggestions(
    List<SceneInfo> scenes,
    ExportSettings settings,
    double totalDuration,
  ) {
    final suggestions = <ClipSuggestion>[];
    final maxDur = settings.maxDurationSeconds;

    for (final scene in scenes) {
      if (scene.durationSeconds < 5) continue;

      if (scene.durationSeconds <= maxDur) {
        final score = _scoreScene(scene, scenes.length);
        suggestions.add(ClipSuggestion(
          segment: VideoSegment(startSeconds: scene.startSeconds, endSeconds: scene.endSeconds),
          score: score,
          label: 'Scene ${scene.index + 1}',
        ));
      } else {
        var start = scene.startSeconds;
        while (start < scene.endSeconds) {
          final end = (start + maxDur) > scene.endSeconds
              ? scene.endSeconds
              : start + maxDur;
          if (end - start >= 5) {
            final score = _scoreScene(scene, scenes.length);
            suggestions.add(ClipSuggestion(
              segment: VideoSegment(startSeconds: start, endSeconds: end),
              score: score,
              label: 'Scene ${scene.index + 1}',
            ));
          }
          start = end;
        }
      }
    }

    suggestions.sort((a, b) => b.score.compareTo(a.score));
    return suggestions.take(settings.clipCount).toList();
  }

  double _scoreScene(SceneInfo scene, int totalScenes) {
    final durationScore = (scene.durationSeconds / 60).clamp(0.2, 1.0);
    final position = scene.index / totalScenes;
    final positionScore = 0.5 + (position < 0.5 ? position * 2 : (1 - position) * 2) * 0.5;
    return durationScore * 0.4 + positionScore * 0.6;
  }

  @override
  Future<Result<List<String>>> exportClips({
    required ShortsProject project,
    required List<ClipSuggestion> selectedClips,
    void Function(double overall, String stage)? onProgress,
  }) async {
    try {
      final outputDir = await _export.outputDir;
      final outputPaths = <String>[];

      for (var i = 0; i < selectedClips.length; i++) {
        final clip = selectedClips[i];
        final clipPath = '$outputDir/clip_${i + 1}.mp4';

        onProgress?.call(i / selectedClips.length, 'Clip ${i + 1}/${selectedClips.length}');

        final clipReframeMode = clip.reframeMode ?? project.exportSettings.reframeMode;

        double? faceCenterX;
        List<double>? facePath;
        if (clipReframeMode == ReframeMode.faceAware) {
          facePath = await FaceDetectionService.detectFacePath(
            project.videoPath, clip.startSeconds, clip.endSeconds,
          );
          if (facePath == null || facePath.length < 2) {
            faceCenterX = await FaceDetectionService.detectFaceCenterX(
              project.videoPath, clip.startSeconds, clip.endSeconds,
            );
          }
          AppLogger().i('Export: faceAware clip ${i + 1}, path=${facePath?.length ?? 0}pts, fallback=$faceCenterX');
        }

        await _export.exportClip(
          inputPath: project.videoPath,
          start: clip.startSeconds,
          end: clip.endSeconds,
          reframe: ReframeSettings(mode: clipReframeMode),
          exportSettings: project.exportSettings,
          outputPath: clipPath,
          faceCenterX: faceCenterX,
          facePath: facePath,
          onProgress: (p) {
            final overall = (i + p) / selectedClips.length;
            onProgress?.call(overall, 'Clip ${i + 1}/${selectedClips.length}');
          },
        );

        outputPaths.add(clipPath);
        unawaited(_export.scanOutput(clipPath));
      }

      onProgress?.call(1.0, 'Complete');
      return Success(outputPaths);
    } catch (e, stack) {
      AppLogger().e('Export failed', e, stack);
      return AppError(VideoProcessingFailure(message: e.toString()));
    }
  }
}
