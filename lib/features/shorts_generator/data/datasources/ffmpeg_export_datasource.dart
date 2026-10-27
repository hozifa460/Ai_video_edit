import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import '../../../../core/utils/file_utils.dart';
import '../../../../core/utils/logger.dart';
import '../../../../core/utils/media_scanner.dart';
import '../../domain/entities/export_settings.dart';
import '../../domain/entities/reframe_settings.dart';

class FfmpegExportDatasource {
  Future<String> exportClip({
    required String inputPath,
    required double start,
    required double end,
    required ReframeSettings reframe,
    required ExportSettings exportSettings,
    required String outputPath,
    void Function(double progress)? onProgress,
    double? faceCenterX,
    List<double>? facePath,
  }) async {
    final durationMs = ((end - start) * 1000).round();
    final clipDuration = end - start;
    final (filter, useComplex) = _buildReframeFilter(reframe, exportSettings,
        faceCenterX: faceCenterX, facePath: facePath, clipDuration: clipDuration, startSec: start);
    final filterFlag = useComplex ? '-filter_complex' : '-vf';
    final bv = exportSettings.bitrateMbps;

    final command =
        '-ss ${_fmt(start)} -i "$inputPath" -t ${_fmt(end - start)} $filterFlag "$filter" -pix_fmt yuv420p -c:v mpeg4 -b:v ${bv}M -q:v 5 -c:a aac -b:a 128k -movflags +faststart -y "$outputPath"';

    AppLogger().i('Export clip: $command');

    if (durationMs > 0) {
      FFmpegKitConfig.enableStatisticsCallback((Statistics statistics) {
        onProgress?.call((statistics.getTime() / durationMs).clamp(0.0, 1.0));
      });
    }

    var success = false;
    var ffmpegLogs = '';

    final session = await FFmpegKit.execute(command);
    ffmpegLogs = await session.getAllLogsAsString() ?? '';
    success = ReturnCode.isSuccess(await session.getReturnCode());

    if (!success) {
      AppLogger().e('Clip export failed (mpeg4): $ffmpegLogs');

      final altCommand =
          '-ss ${_fmt(start)} -i "$inputPath" -t ${_fmt(end - start)} $filterFlag "$filter" -pix_fmt yuv420p -c:v libx264 -preset fast -b:v ${bv}M -maxrate ${bv * 2}M -bufsize ${bv * 2}M -c:a aac -b:a 128k -movflags +faststart -y "$outputPath"';
      AppLogger().i('Retry with libx264: $altCommand');

      final altSession = await FFmpegKit.execute(altCommand);
      ffmpegLogs = await altSession.getAllLogsAsString() ?? '';
      success = ReturnCode.isSuccess(await altSession.getReturnCode());
    }

    FFmpegKitConfig.enableStatisticsCallback(null);

    if (!success) {
      AppLogger().e('Clip export failed (all attempts): $ffmpegLogs');

      final outFile = File(outputPath);
      if (await outFile.exists()) await outFile.delete();

      final shortLog = ffmpegLogs.length > 300 ? '${ffmpegLogs.substring(0, 300)}...' : ffmpegLogs;
      throw Exception('Clip export failed: $shortLog');
    }

    final outFile = File(outputPath);
    if (!await outFile.exists() || await outFile.length() < 1024) {
      AppLogger().e('Export output missing or too small: $outputPath');
      throw Exception('Export file is missing or corrupt');
    }

    return outputPath;
  }

  (String, bool) _buildReframeFilter(ReframeSettings reframe, ExportSettings settings,
      {double? faceCenterX, List<double>? facePath, double? clipDuration, double? startSec}) {
    final outW = reframe.targetWidth;
    final outH = reframe.targetHeight;
    // mpeg4 encoder + yuv420p chroma planes require widths that are multiples of 4
    // (even Y → odd chroma at /2; multiple-of-4 guarantees both are properly aligned)
    String evenCropW(String h) => '4*trunc($h*$outW/$outH/4)';

    switch (reframe.mode) {
      case ReframeMode.centerCrop:
        final cropH = 'min(ih\\,$outH)';
        final cropW = evenCropW(cropH);
        return ('crop=$cropW:$cropH:(iw-$cropW)/2:0,scale=$outW:$outH:flags=lanczos', false);

      case ReframeMode.pillarbox:
        return (
          "scale='min($outW\\,iw*$outH/ih)':'2*trunc(min($outH\\,ih*$outW/iw)/2)':flags=lanczos,pad=$outW:$outH:($outW-iw)/2:($outH-ih)/2:color=black",
          false
        );

      case ReframeMode.blurBackground:
        return (
          '[0:v]scale=$outW:$outH,boxblur=20[bg];'
              '[0:v]scale=$outW:2*trunc(ih*$outW/iw/2)[fg];'
              '[bg][fg]overlay=(W-w)/2:(H-h)/2',
          true
        );

      case ReframeMode.faceAware: {
        final cropW = evenCropW('ih');

        // Dynamic per-frame face path (multi-speaker, smooth transitions)
        // t in crop filter starts at 0 (input -ss seeking resets PTS),
        // so sample times must be relative to clip start, NOT absolute.
        if (facePath != null && facePath.length >= 2 && clipDuration != null && clipDuration > 0) {
          final perSample = clipDuration / (facePath.length - 1);
          final buf = StringBuffer();
          final segments = facePath.length - 1;
          for (var i = 0; i < segments; i++) {
            final x0 = facePath[i].toStringAsFixed(1);
            final x1 = facePath[i + 1].toStringAsFixed(1);
            final tEnd = ((i + 1) * perSample).toStringAsFixed(3);
            final tStart = (i * perSample).toStringAsFixed(3);
            if (i == 0) {
              buf.write('max(0\\, min(iw-$cropW\\, if(lte(t\\,$tEnd)\\, $x0+($x1-$x0)*(t-$tStart)/$perSample-($cropW)/2');
            } else if (i < segments - 1) {
              buf.write('\\, if(lte(t\\,$tEnd)\\, $x0+($x1-$x0)*(t-$tStart)/$perSample-($cropW)/2');
            } else {
              buf.write('\\, $x0+($x1-$x0)*(t-$tStart)/$perSample-($cropW)/2');
            }
          }
          final closeCount = segments >= 2 ? segments + 1 : 3;
          for (var i = 0; i < closeCount; i++) { buf.write(')'); }
          final xExpr = buf.toString();
          return ('crop=$cropW:ih:$xExpr:0,scale=$outW:$outH:flags=lanczos', false);
        }

        // Static face position (raw pixel X, not normalized)
        if (faceCenterX != null) {
          final fcPx = faceCenterX.toStringAsFixed(1);
          return ('crop=$cropW:ih:max(0\\, min(iw-$cropW\\, $fcPx-($cropW)/2)):0,scale=$outW:$outH:flags=lanczos', false);
        }
        return ('crop=$cropW:ih:(iw-$cropW)/2:0,scale=$outW:$outH:flags=lanczos', false);
      }

      case ReframeMode.cinematicLetterbox:
        final barH = (outH - outW / 2.35).round() ~/ 2;
        return (
          "scale='min($outW\\,iw*$outH/ih)':'2*trunc(min($outH\\,ih*$outW/iw)/2)':flags=lanczos,pad=$outW:$outH:($outW-iw)/2:($outH-ih)/2:color=black,drawbox=x=0:y=0:w=$outW:h=$barH:color=black:t=fill,drawbox=x=0:y=${outH - barH}:w=$outW:h=$barH:color=black:t=fill",
          false
        );

      case ReframeMode.kenBurns:
        return (
          'scale=2*trunc(iw*1.02/2):2*trunc(ih*1.02/2):flags=lanczos,zoompan=z=\'min(zoom+0.0008\\,1.12)\':x=iw/2-(iw/zoom/2):y=ih/2-(ih/zoom/2):d=1:s=${outW}x$outH,fps=30',
          false
        );

      case ReframeMode.shadowGlow:
        return (
          'split[orig][glow];[glow]scale=$outW:$outH,gblur=sigma=40,colorchannelmixer=rr=0.3:gg=0.3:bb=0.3[bg];[orig]scale=$outW:2*trunc(ih*$outW/iw/2)[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2',
          true
        );

      case ReframeMode.mirrorSplit:
        // Each half scales to HALF the output width, then hstack joins them
        // at exactly outW x outH. The old graph stacked two full-width frames
        // and force-rescaled → 2:1 horizontal squash.
        return (
          'split[orig][mir];'
              '[mir]hflip,scale=2*trunc($outW/4):$outH:flags=lanczos[ml];'
              '[orig]scale=2*trunc($outW/4):$outH:flags=lanczos[mr];'
              '[ml][mr]hstack=inputs=2',
          true
        );
    }
  }

  Future<String> get outputDir async {
    final dir = await FileUtils.getExportDirectory();
    final out = '${dir.path}/shorts_${DateTime.now().millisecondsSinceEpoch}';
    await Directory(out).create(recursive: true);
    return out;
  }

  Future<void> scanOutput(String path) async {
    await MediaScanner.scanFile(path);
  }

  String _fmt(double s) => s.toStringAsFixed(3);
}
