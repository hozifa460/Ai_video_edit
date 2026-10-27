import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';

import '../../../../core/services/face_detection_service.dart';
import '../../../../core/utils/logger.dart';
import '../../domain/entities/reframe_config.dart';

/// Builds and executes the FFmpeg Auto Reframe pipeline.
///
/// The crop geometry is **universal**: it works for landscape→portrait,
/// portrait→landscape, square and custom ratios, and the crop window follows
/// the speaker in both axes through piecewise-linear `x`/`y` expressions.
class FfmpegAutoReframeService {
  /// FFmpeg log of the last failed session, surfaced to the UI.
  String? lastErrorLog;

  static const String primaryVideoCodec =
      '-c:v libx264 -preset veryfast -crf 21 -pix_fmt yuv420p';
  static const String fallbackVideoCodec =
      '-c:v mpeg4 -q:v 4 -pix_fmt yuv420p';
  static const String audioCodec = '-c:a aac -b:a 192k';

  // ---------------------------------------------------------------------------
  // Crop geometry (pure, unit-testable)
  // ---------------------------------------------------------------------------

  /// Crop width in pixels, valid for any input/output aspect combination.
  static String cropWidthExpr(String targetAspect) =>
      '4*trunc(if(gt(iw/ih\\,$targetAspect)\\,ih*$targetAspect\\,iw)/4)';

  /// Crop height in pixels, matching [cropWidthExpr].
  static String cropHeightExpr(String targetAspect) =>
      '2*trunc(if(gt(iw/ih\\,$targetAspect)\\,ih\\,iw/$targetAspect)/2)';

  /// Piecewise-linear normalized face coordinate (`0.0 .. 1.0`) over `t`.
  ///
  /// At most [FaceDetectionService.maxKeyframes] segments are emitted, which
  /// keeps FFmpeg's expression parser well below its nesting limit.
  static String normExpression(
    List<FaceTrackPoint> keyframes, {
    required bool axisX,
  }) {
    double valueOf(FaceTrackPoint p) => axisX ? p.normX : p.normY;

    if (keyframes.isEmpty) return axisX ? '0.5000' : '0.4200';
    if (keyframes.length == 1) {
      return valueOf(keyframes.first).toStringAsFixed(4);
    }

    final buffer = StringBuffer();
    var openConditions = 0;
    for (var i = 0; i < keyframes.length - 1; i++) {
      final a = keyframes[i];
      final b = keyframes[i + 1];
      final span = (b.timeSec - a.timeSec).abs() < 0.001
          ? 0.001
          : b.timeSec - a.timeSec;
      final linear =
          '${valueOf(a).toStringAsFixed(4)}+'
          '(${valueOf(b).toStringAsFixed(4)}-${valueOf(a).toStringAsFixed(4)})'
          '*(t-${a.timeSec.toStringAsFixed(3)})/${span.toStringAsFixed(3)}';
      if (i < keyframes.length - 2) {
        buffer.write(
          'if(lte(t\\,${b.timeSec.toStringAsFixed(3)})\\,$linear\\,',
        );
        openConditions++;
      } else {
        buffer.write(linear);
      }
    }
    buffer.write(')' * openConditions);
    return buffer.toString();
  }

  /// Full `crop + scale + setsar + format` chain for one output size.
  ///
  /// Inside `crop=w:h:x:y`, `out_w`/`out_h` are the evaluated crop width and
  /// height, so the centering expression stays short: the face center minus
  /// half the crop window, clamped into the frame.
  static String buildCropFilter({
    required int outW,
    required int outH,
    List<FaceTrackPoint> keyframes = const [],
    bool faceTracking = true,
  }) {
    final targetAspect = (outW / outH).toStringAsFixed(6);
    final cropW = cropWidthExpr(targetAspect);
    final cropH = cropHeightExpr(targetAspect);

    final normX = normExpression(keyframes, axisX: true);
    final normY = normExpression(keyframes, axisX: false);

    final x = faceTracking
        ? 'max(0\\,min(iw-out_w\\,iw*($normX)-out_w/2))'
        : '(iw-out_w)/2';
    final y = faceTracking
        ? 'max(0\\,min(ih-out_h\\,ih*($normY)-out_h/2))'
        : '(ih-out_h)/2';

    return "crop=$cropW:$cropH:x='$x':y='$y'"
        ',scale=$outW:$outH:flags=bilinear,setsar=1,format=yuv420p';
  }

  /// Blurred background + full-frame foreground, centered in the target ratio.
  static String buildBlurGraph({required int outW, required int outH}) {
    final targetAspect = (outW / outH).toStringAsFixed(6);
    final cropW = cropWidthExpr(targetAspect);
    final cropH = cropHeightExpr(targetAspect);
    return '[0:v]split=2[bg][fg];'
        '[bg]crop=$cropW:$cropH:(iw-out_w)/2:(ih-out_h)/2,'
        'scale=$outW:$outH:flags=bilinear,gblur=sigma=30,setsar=1[b];'
        '[fg]scale=$outW:$outH:force_original_aspect_ratio=decrease:'
        'flags=bilinear,setsar=1[f];'
        '[b][f]overlay=(W-w)/2:(H-h)/2,format=yuv420p[outv]';
  }

  /// The video filter argument for a config, including the `-vf`/`-filter_complex`
  /// wrapper and any required mapping.
  static String buildFilterArgument({
    required ReframeConfig config,
    FaceTrackResult? track,
  }) {
    final (outW, outH) = config.outputSize;
    if (config.style == AutoReframeStyle.blurBackgroundFrame) {
      return '-filter_complex "${buildBlurGraph(outW: outW, outH: outH)}" '
          '-map "[outv]" -map 0:a?';
    }
    final keyframes =
        config.style == AutoReframeStyle.smartFaceCrop && track != null
        ? track.keyframes
        : const <FaceTrackPoint>[];
    final filter = buildCropFilter(
      outW: outW,
      outH: outH,
      keyframes: keyframes,
      faceTracking: config.style == AutoReframeStyle.smartFaceCrop,
    );
    return '-vf "$filter"';
  }

  // ---------------------------------------------------------------------------
  // Execution
  // ---------------------------------------------------------------------------

  /// Renders [videoPath] into [outputPath] according to [config].
  ///
  /// Tries libx264 first and transparently retries with mpeg4 when the encoder
  /// or the source pixel format makes the primary attempt fail.
  Future<String?> reframe({
    required String videoPath,
    required String outputPath,
    required ReframeConfig config,
    FaceTrackResult? track,
    int? durationMs,
    void Function(double progress, String status)? onProgress,
  }) async {
    lastErrorLog = null;
    final filterArgument = buildFilterArgument(config: config, track: track);

    var command =
        '-i "$videoPath" $filterArgument '
        '$primaryVideoCodec $audioCodec -movflags +faststart -y "$outputPath"';
    AppLogger().i('AutoReframe: $command');

    var session = await _execute(
      command,
      durationMs: durationMs,
      onProgress: onProgress,
    );
    if (!ReturnCode.isSuccess(await session.getReturnCode())) {
      lastErrorLog = await session.getAllLogsAsString();
      AppLogger().e('AutoReframe libx264 failed: $lastErrorLog');

      command =
          '-i "$videoPath" $filterArgument '
          '$fallbackVideoCodec $audioCodec -movflags +faststart -y "$outputPath"';
      AppLogger().i('AutoReframe retry: $command');
      session = await _execute(
        command,
        durationMs: durationMs,
        onProgress: onProgress,
      );
      if (!ReturnCode.isSuccess(await session.getReturnCode())) {
        lastErrorLog = await session.getAllLogsAsString();
        AppLogger().e('AutoReframe mpeg4 failed: $lastErrorLog');
        return null;
      }
    }

    final outFile = File(outputPath);
    if (!await outFile.exists()) {
      lastErrorLog ??= 'AutoReframe: output file was not created';
      AppLogger().e(lastErrorLog!);
      return null;
    }
    onProgress?.call(1.0, 'Reframe complete');
    return outputPath;
  }

  Future<dynamic> _execute(
    String command, {
    int? durationMs,
    void Function(double progress, String status)? onProgress,
  }) async {
    FFmpegKitConfig.enableStatisticsCallback((Statistics statistics) {
      if (durationMs != null && durationMs > 0) {
        final progress = (statistics.getTime() / durationMs).clamp(0.0, 1.0);
        onProgress?.call(progress, 'Rendering reframe...');
      }
    });
    try {
      return await FFmpegKit.execute(command);
    } finally {
      FFmpegKitConfig.enableStatisticsCallback(null);
    }
  }
}
