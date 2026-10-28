import 'dart:io';
import 'dart:math';

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
  /// Emitted as a **balanced binary tree** of `if(lt(t\,...))` branches, so a
  /// 64-keyframe trajectory nests only `log2(64) ≈ 6` levels deep instead of
  /// 64: FFmpeg's expression parser never overflows and speaker cuts survive
  /// intact.
  ///
  /// Cut handling: explicit `isCut` keyframes are expanded into 1ms step pairs
  /// first (see [FaceDetectionService.materializeKeyframesForFfmpeg]), so this
  /// renderer always receives an already-linearized segment list — a cut then
  /// interpolates across exactly 1ms (an instant snap) while smooth keyframes
  /// pan linearly.
  static String normExpression(
    List<FaceTrackPoint> keyframes, {
    required bool axisX,
  }) {
    double valueOf(FaceTrackPoint p) => axisX ? p.normX : p.normY;

    // Honor explicit cut flags even for callers that skipped materialization.
    final linearized = keyframes.any((k) => k.isCut)
        ? FaceDetectionService.materializeKeyframesForFfmpeg(keyframes)
        : keyframes;

    if (linearized.isEmpty) return axisX ? '0.5000' : '0.4200';
    if (linearized.length == 1) {
      return valueOf(linearized.first).toStringAsFixed(4);
    }
    return _buildBalancedTimeTree(
      linearized,
      start: 0,
      end: linearized.length - 1,
      axisX: axisX,
    );
  }

  /// Recursively bisects the keyframe range `[start .. end]`.
  ///
  /// `start == end` → constant; `[start .. start+1]` → one linear segment;
  /// otherwise `if(lt(t\,tMid)\,left\,right)` over the midpoint keyframe.
  /// Depth is `ceil(log2(keyframes))` — at most ~6 for 60-70 keyframes.
  static String _buildBalancedTimeTree(
    List<FaceTrackPoint> keyframes, {
    required int start,
    required int end,
    required bool axisX,
  }) {
    double valueOf(FaceTrackPoint p) => axisX ? p.normX : p.normY;

    if (start >= end) return valueOf(keyframes[start]).toStringAsFixed(4);
    if (end - start == 1) {
      final a = keyframes[start];
      final b = keyframes[end];
      final span = (b.timeSec - a.timeSec).abs() < 0.001
          ? 0.001
          : b.timeSec - a.timeSec;
      // Clamp `t` into this segment so times BEFORE the first keyframe or
      // AFTER the last one HOLD the edge position instead of extrapolating
      // linearly to absurd coordinates (the last shot's keyframe sits at
      // that shot's start, so the tail of the video is "beyond the last").
      return '${valueOf(a).toStringAsFixed(4)}+'
          '(${valueOf(b).toStringAsFixed(4)}-${valueOf(a).toStringAsFixed(4)})'
          '*(min(max(t\\,${a.timeSec.toStringAsFixed(3)})'
          '\\,${b.timeSec.toStringAsFixed(3)})'
          '-${a.timeSec.toStringAsFixed(3)})/${span.toStringAsFixed(3)}';
    }

    final mid = (start + end) >> 1;
    final tMid = keyframes[mid].timeSec.toStringAsFixed(3);
    final left = _buildBalancedTimeTree(
      keyframes,
      start: start,
      end: mid,
      axisX: axisX,
    );
    final right = _buildBalancedTimeTree(
      keyframes,
      start: mid,
      end: end,
      axisX: axisX,
    );
    return 'if(lt(t\\,$tMid)\\,$left\\,$right)';
  }

  /// Inner active box of the output canvas for a `frameFill` value.
  ///
  /// Portrait/square targets keep the full width and shrink the height;
  /// landscape targets keep the full height and shrink the width. The box is
  /// centered, so the discarded proportion becomes black bars.
  static ({int boxW, int boxH}) innerBoxForFill({
    required int outW,
    required int outH,
    required double frameFill,
  }) {
    final fill = frameFill.clamp(0.45, 1.0);
    if (outH >= outW) {
      final boxH = max(4, 4 * ((outH * fill) / 4).round());
      return (boxW: outW, boxH: boxH);
    }
    final boxW = max(4, 4 * ((outW * fill) / 4).round());
    return (boxW: boxW, boxH: outH);
  }

  /// Full `crop + scale [+ pad] + setsar + format` chain for one output size.
  ///
  /// Inside `crop=w:h:x:y`, `out_w`/`out_h` are the evaluated crop width and
  /// height, so the centering expression stays short: the face center minus
  /// half the crop window, clamped into the frame.
  ///
  /// With [frameFill] < 0.99 the source is cropped to the **wider effective
  /// aspect** of the inner box, scaled into that box, then centered on the
  /// black canvas with `pad=...:black`.
  ///
  /// [keyframes] are passed through
  /// [FaceDetectionService.materializeKeyframesForFfmpeg] so `isCut` keyframes
  /// become exact 1ms snaps (idempotent for pre-expanded lists).
  static String buildCropFilter({
    required int outW,
    required int outH,
    List<FaceTrackPoint> keyframes = const [],
    bool faceTracking = true,
    double frameFill = 1.0,
  }) {
    final fill = frameFill.clamp(0.45, 1.0);
    var boxW = outW;
    var boxH = outH;
    if (fill < 0.99) {
      final box = innerBoxForFill(outW: outW, outH: outH, frameFill: fill);
      boxW = box.boxW;
      boxH = box.boxH;
    }

    final targetAspect = (boxW / boxH).toStringAsFixed(6);
    final cropW = cropWidthExpr(targetAspect);
    final cropH = cropHeightExpr(targetAspect);

    final linearized = FaceDetectionService.materializeKeyframesForFfmpeg(
      keyframes,
    );
    final normX = normExpression(linearized, axisX: true);
    final normY = normExpression(linearized, axisX: false);

    final x = faceTracking
        ? 'max(0\\,min(iw-out_w\\,iw*($normX)-out_w/2))'
        : '(iw-out_w)/2';
    final y = faceTracking
        ? 'max(0\\,min(ih-out_h\\,ih*($normY)-out_h/2))'
        : '(ih-out_h)/2';

    final scaleAndPad = fill < 0.99
        ? 'scale=$boxW:$boxH:flags=bilinear,'
            'pad=$outW:$outH:($outW-$boxW)/2:($outH-$boxH)/2:black,'
            'setsar=1,format=yuv420p'
        : 'scale=$outW:$outH:flags=bilinear,setsar=1,format=yuv420p';

    return "crop=$cropW:$cropH:x='$x':y='$y',$scaleAndPad";
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
        ? FaceDetectionService.materializeKeyframesForFfmpeg(track.keyframes)
        : const <FaceTrackPoint>[];
    final filter = buildCropFilter(
      outW: outW,
      outH: outH,
      keyframes: keyframes,
      faceTracking: config.style == AutoReframeStyle.smartFaceCrop,
      frameFill: config.frameFillClamped,
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
