import 'dart:async';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import 'package:path_provider/path_provider.dart';
import '../../../../core/utils/logger.dart';
import '../../domain/entities/enhancement_settings.dart';
import '../../domain/repositories/enhancement_repository.dart';
import 'professional_enhancement_command_builder.dart';

class FfmpegEnhancementDatasource {
  final ProfessionalEnhancementCommandBuilder _commandBuilder =
      ProfessionalEnhancementCommandBuilder();

  FFmpegSession? _activeSession;

  /// Cancels the running encode immediately.
  void cancel() {
    _activeSession?.cancel();
  }

  Stream<EnhancementProgress> enhanceVideo({
    required String inputPath,
    required EnhancementSettings settings,
    required int totalDurationMs,
  }) async* {
    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final outputPath = '${tempDir.path}/enhanced_$timestamp.mp4';

    final command = _buildCommand(inputPath, outputPath, settings);

    AppLogger().i('Enhancement command: $command');

    final totalDurationSec = totalDurationMs / 1000.0;
    final stages = _getEnhancementStages(settings);

    int currentStage = 0;
    double lastProgress = 0;

    FFmpegKitConfig.enableStatisticsCallback((Statistics statistics) {
      final timeMs = statistics.getTime();
      if (timeMs > 0 && totalDurationSec > 0) {
        lastProgress = (timeMs / 1000.0) / totalDurationSec;
      }
    });

    await FFmpegKit.executeAsync(command, (session) async {
      final returnCode = await session.getReturnCode();
      final logs = await session.getAllLogsAsString();

      if (ReturnCode.isSuccess(returnCode)) {
        AppLogger().i('Enhancement completed');
      } else {
        AppLogger().e('Enhancement failed: $logs');
      }
    });

    for (int i = 0; i < stages.length; i++) {
      currentStage = i + 1;
      final stageStart = i / stages.length;

      yield EnhancementProgress(
        currentStage: currentStage,
        totalStages: stages.length,
        stageName: stages[i],
        progress: 0.0,
        estimatedRemaining: Duration(
          seconds:
              ((totalDurationSec - (stageStart * totalDurationSec)) ~/
                  currentStage +
              1),
        ),
        totalFrames: (totalDurationSec * 30).round(),
        framesProcessed: (lastProgress * totalDurationSec * 30).round(),
      );

      await Future.delayed(Duration(milliseconds: 200));

      for (int p = 1; p <= 10; p++) {
        await Future.delayed(Duration(milliseconds: 100));
        final progress = p / 10.0;
        yield EnhancementProgress(
          currentStage: currentStage,
          totalStages: stages.length,
          stageName: stages[i],
          progress: progress,
          estimatedRemaining: Duration(
            seconds:
                ((totalDurationSec *
                        (1 - stageStart - progress / stages.length)) ~/
                    1 +
                1),
          ),
          totalFrames: (totalDurationSec * 30).round(),
          framesProcessed:
              ((stageStart + progress / stages.length) * totalDurationSec * 30)
                  .round(),
        );
      }
    }

    final outputFile = File(outputPath);
    if (await outputFile.exists()) {
      yield EnhancementProgress(
        currentStage: stages.length,
        totalStages: stages.length,
        stageName: 'Complete',
        progress: 1.0,
        totalFrames: (totalDurationSec * 30).round(),
        framesProcessed: (totalDurationSec * 30).round(),
      );
    }
  }

  List<String> _getEnhancementStages(EnhancementSettings settings) {
    final stages = <String>[];

    if (settings.denoiseEnabled) stages.add('Removing Noise');
    if (settings.colorGradeEnabled) stages.add('Color Correction');
    if (settings.sharpenEnabled) stages.add('Sharpening');
    if (settings.upscaleEnabled) stages.add('Upscaling');
    stages.add('Applying Effects');
    if (settings.audioEnhanceEnabled) stages.add('Enhancing Audio');
    stages.add('Encoding');

    return stages;
  }

  String _buildCommand(
    String inputPath,
    String outputPath,
    EnhancementSettings settings,
  ) {
    return _commandBuilder.buildDirectCommand(
      inputPath: inputPath,
      outputPath: outputPath,
      settings: settings,
    );
  }

  Future<String> enhanceVideoDirect({
    required String inputPath,
    required EnhancementSettings settings,
    void Function(double progress)? onProgress,
    int totalDurationMs = 0,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final outputPath = '${tempDir.path}/enhanced_$timestamp.mp4';

    final command = _buildCommand(inputPath, outputPath, settings);

    AppLogger().i('Enhancement command: $command');

    // Real progress via per-run statistics callback.
    if (totalDurationMs > 0 && onProgress != null) {
      FFmpegKitConfig.enableStatisticsCallback((Statistics statistics) {
        final timeMs = statistics.getTime();
        if (timeMs > 0) {
          onProgress((timeMs / totalDurationMs).clamp(0.0, 1.0));
        }
      });
    }

    final completer = Completer<void>();
    final session = await FFmpegKit.executeAsync(
      command,
      (_) {
        if (!completer.isCompleted) completer.complete();
      },
      (log) {},
    );
    _activeSession = session;
    await completer.future;
    _activeSession = null;
    FFmpegKitConfig.enableStatisticsCallback(null);

    final returnCode = await session.getReturnCode();

    if (!ReturnCode.isSuccess(returnCode)) {
      final logs = await session.getAllLogsAsString();
      AppLogger().e('Enhancement failed: $logs');
      throw Exception('Video enhancement failed. Check logs for details.');
    }

    final outputFile = File(outputPath);
    if (!await outputFile.exists()) {
      throw Exception('Output file was not created');
    }

    return outputPath;
  }
}
