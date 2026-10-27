import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:path_provider/path_provider.dart';
import '../../../../core/errors/failures.dart';
import '../../../../core/enums/export_quality.dart';
import '../../../../core/utils/logger.dart';
import '../../../../core/utils/result.dart';
import '../../../silence_detector/domain/entities/detection_params.dart';
import '../../../silence_detector/domain/entities/silence_removal_plan.dart';
import '../../domain/entities/export_params.dart';
import '../../domain/repositories/video_processor_repository.dart';
import '../services/ffmpeg_cutting_service.dart';

class VideoProcessorRepositoryImpl implements VideoProcessorRepository {
  final FfmpegCuttingService _cuttingService;

  VideoProcessorRepositoryImpl() : _cuttingService = FfmpegCuttingService();

  @override
  Future<Result<String>> processVideo({
    required String videoPath,
    required String audioPath,
    required SilenceRemovalPlan plan,
    required ExportQuality quality,
    SmartZoomConfig? smartZoom,
    required ProcessingProgressCallback onProgress,
  }) async {
    try {
      onProgress(0.1, 'Analyzing silence segments...');

      if (!plan.isUsable) {
        return AppError(
          const VideoProcessingFailure(
            message: 'Removal plan has no usable timeline',
          ),
        );
      }

      final tempDir = await getTemporaryDirectory();
      // Unique per run — the fixed name let a preview and an export (or two
      // editors) overwrite each other's output mid-write.
      final outputPath =
          '${tempDir.path}/processed_output_${DateTime.now().millisecondsSinceEpoch}.mp4';

      onProgress(0.01, 'Cutting silent segments...');

      final result = await _cuttingService.cutWithConcat(
        videoPath: videoPath,
        audioPath: audioPath,
        plan: plan,
        quality: quality,
        outputPath: outputPath,
        smartZoom: smartZoom,
        onProgress: onProgress,
      );

      if (result == null) {
        // Surface FFmpeg's own log: the generic "no output" message hid the
        // actual encoder/concat error and made Preview/Export failures
        // impossible to diagnose on a phone.
        final log = _cuttingService.lastErrorLog?.trim();
        final detail = (log == null || log.isEmpty)
            ? null
            : (log.length > 800 ? log.substring(log.length - 800) : log);
        return AppError(
          VideoProcessingFailure(
            message: detail == null
                ? 'FFmpeg processing returned no output'
                : 'FFmpeg processing failed: $detail',
          ),
        );
      }

      onProgress(0.9, 'Finalizing...');

      final outFile = File(outputPath);
      if (!await outFile.exists()) {
        return AppError(
          const VideoProcessingFailure(message: 'Output file not created'),
        );
      }

      onProgress(1.0, 'Complete');

      return Success(outputPath);
    } catch (e, stack) {
      AppLogger().e('Video processing failed', e, stack);
      return AppError(VideoProcessingFailure(message: e.toString()));
    }
  }

  @override
  Future<Result<ExportParams>> exportVideo({
    required String sourcePath,
    required String outputPath,
    required String format,
    required ExportQuality quality,
    ProcessingProgressCallback? onProgress,
  }) async {
    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        return AppError(const ExportFailure(message: 'Source file not found'));
      }

      var finalPath = outputPath;
      if (!finalPath.endsWith('.$format')) {
        finalPath = '$finalPath.$format';
      }

      int? videoDurationMs;
      try {
        final info = await FFprobeKit.getMediaInformation(sourcePath);
        final mediaInfo = info.getMediaInformation();
        if (mediaInfo != null) {
          final durationStr = mediaInfo.getDuration();
          if (durationStr != null) {
            videoDurationMs =
                ((double.tryParse(durationStr) ?? 0) * 1000).round();
          }
        }
      } catch (_) {}

      // For original quality MP4 exports, avoid re-encoding and just copy.
      if (format.toLowerCase() == 'mp4' &&
          quality == ExportQuality.original &&
          sourcePath.toLowerCase().endsWith('.mp4')) {
        try {
          await File(sourcePath).copy(finalPath);
        } catch (e) {
          // Fall back to app documents dir if public path is not writable.
          final fallbackDir =
              (await getExternalStorageDirectory()) ??
              await getApplicationDocumentsDirectory();
          finalPath = '${fallbackDir.path}/${finalPath.split(Platform.pathSeparator).last}';
          await File(sourcePath).copy(finalPath);
        }
      } else {
        final tempDir = await getTemporaryDirectory();
        final stagingPath =
            '${tempDir.path}/export_staging_${DateTime.now().millisecondsSinceEpoch}.$format';

        final result = await _cuttingService.exportFile(
          sourcePath: sourcePath,
          outputPath: stagingPath,
          quality: quality,
          videoDurationMs: videoDurationMs,
          onProgress: onProgress,
        );

        if (result == null) {
          return AppError(
            const ExportFailure(message: 'Export processing failed'),
          );
        }

        try {
          await File(stagingPath).copy(finalPath);
        } catch (e) {
          final fallbackDir =
              (await getExternalStorageDirectory()) ??
              await getApplicationDocumentsDirectory();
          finalPath =
              '${fallbackDir.path}/${finalPath.split(Platform.pathSeparator).last}';
          await File(stagingPath).copy(finalPath);
        } finally {
          try {
            final stagingFile = File(stagingPath);
            if (await stagingFile.exists()) await stagingFile.delete();
          } catch (_) {}
        }
      }

      return Success(
        ExportParams(
          outputPath: finalPath,
          fileName: finalPath.split(Platform.pathSeparator).last,
          format: format,
          quality: quality,
        ),
      );
    } catch (e, stack) {
      AppLogger().e('Export failed', e, stack);
      return AppError(ExportFailure(message: e.toString()));
    }
  }
}
