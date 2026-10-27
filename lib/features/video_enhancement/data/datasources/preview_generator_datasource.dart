import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';
import '../../domain/entities/enhancement_settings.dart';
import '../../domain/entities/enhancement_result.dart';
import 'professional_enhancement_command_builder.dart';

class PreviewGeneratorDatasource {
  final ProfessionalEnhancementCommandBuilder _commandBuilder =
      ProfessionalEnhancementCommandBuilder();

  Future<List<PreviewFrame>> generatePreviewFrames({
    required String videoPath,
    required Duration videoDuration,
    required EnhancementSettings settings,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final frames = <PreviewFrame>[];

    final positions = [0.1, 0.5, 0.8];

    for (int i = 0; i < positions.length; i++) {
      final position = positions[i];
      final ms = (videoDuration.inMilliseconds * position).round();
      final timestamp = Duration(milliseconds: ms);

      final originalFrame = await _extractFrame(
        videoPath,
        timestamp,
        i,
        tempDir.path,
        'original',
      );

      if (originalFrame != null) {
        final enhancedFrame = await _enhanceFrame(
          originalFrame,
          settings,
          i,
          tempDir.path,
        );

        frames.add(
          PreviewFrame(
            frameIndex: i,
            timestamp: timestamp,
            originalPath: originalFrame,
            enhancedPath: enhancedFrame,
          ),
        );
      }
    }

    return frames;
  }

  Future<String?> _extractFrame(
    String videoPath,
    Duration timestamp,
    int index,
    String tempDir,
    String suffix,
  ) async {
    final outputPath = '$tempDir/preview_${suffix}_$index.jpg';
    final seconds =
        timestamp.inSeconds + (timestamp.inMilliseconds % 1000) / 1000.0;

    final command =
        '-y -ss $seconds -i "$videoPath" '
        '-vframes 1 -q:v 2 "$outputPath"';

    final session = await FFmpegKit.execute(command);
    final returnCode = await session.getReturnCode();

    if (!ReturnCode.isSuccess(returnCode)) {
      return null;
    }

    final file = File(outputPath);
    if (await file.exists()) {
      return outputPath;
    }
    return null;
  }

  Future<String?> _enhanceFrame(
    String originalPath,
    EnhancementSettings settings,
    int index,
    String tempDir,
  ) async {
    final outputPath = '$tempDir/preview_enhanced_$index.jpg';

    final vf = _commandBuilder.buildDirectVideoFilter(settings);
    final command = '-y -i "$originalPath" -vf "$vf" -q:v 2 "$outputPath"';

    final session = await FFmpegKit.execute(command);
    final returnCode = await session.getReturnCode();

    if (!ReturnCode.isSuccess(returnCode)) {
      return null;
    }

    final file = File(outputPath);
    if (await file.exists()) {
      return outputPath;
    }
    return null;
  }

  Future<PreviewFrame?> generateSinglePreview({
    required String videoPath,
    required Duration timestamp,
    required EnhancementSettings settings,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final index = timestamp.inSeconds;

    final originalFrame = await _extractFrame(
      videoPath,
      timestamp,
      index,
      tempDir.path,
      'orig',
    );
    if (originalFrame == null) return null;

    final enhancedFrame = await _enhanceFrame(
      originalFrame,
      settings,
      index,
      tempDir.path,
    );
    if (enhancedFrame == null) return null;

    return PreviewFrame(
      frameIndex: index,
      timestamp: timestamp,
      originalPath: originalFrame,
      enhancedPath: enhancedFrame,
    );
  }
}
