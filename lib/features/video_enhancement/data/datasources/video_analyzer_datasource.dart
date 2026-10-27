import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';
import '../../../../core/utils/logger.dart';
import '../../domain/entities/video_analysis_result.dart';

class VideoAnalyzerDatasource {
  Future<VideoAnalysisResult> analyzeVideo(String videoPath) async {
    final metadata = await _extractMetadata(videoPath);
    final quality = await _analyzeQuality(videoPath, metadata);
    final issues = quality.issues;

    return VideoAnalysisResult(
      metadata: metadata,
      quality: quality,
      detectedIssues: issues,
      analyzedAt: DateTime.now(),
    );
  }

  Future<VideoMetadata> _extractMetadata(String videoPath) async {
    final session = await FFprobeKit.getMediaInformation(videoPath);
    final info = session.getMediaInformation();

    if (info == null) {
      throw Exception('Failed to get video metadata');
    }

    final durationStr = info.getDuration() ?? '0';
    final duration = Duration(milliseconds: (double.parse(durationStr) * 1000).round());

    final streams = info.getStreams();
    int? width, height, videoBitrate, audioBitrate;
    String? codec, pixelFormat, colorSpace, audioCodec;
    double? fps;
    bool hasAudio = false;

    for (final stream in streams) {
      final streamType = stream.getType();
      if (streamType == 'video') {
        width = stream.getWidth();
        height = stream.getHeight();
        codec = stream.getCodec();
        pixelFormat = 'yuv420p';
        
        final fpsStr = stream.getRealFrameRate();
        if (fpsStr != null && fpsStr.contains('/')) {
          final parts = fpsStr.split('/');
          fps = double.parse(parts[0]) / double.parse(parts[1]);
        } else if (fpsStr != null) {
          fps = double.tryParse(fpsStr);
        }

        final bitrateStr = stream.getBitrate();
        if (bitrateStr != null) {
          videoBitrate = int.tryParse(bitrateStr);
        }
      } else if (streamType == 'audio') {
        hasAudio = true;
        audioCodec = stream.getCodec();
        final bitrateStr = stream.getBitrate();
        if (bitrateStr != null) {
          audioBitrate = int.tryParse(bitrateStr);
        }
      }
    }

    final file = File(videoPath);
    final fileSize = await file.length();

    return VideoMetadata(
      width: width ?? 0,
      height: height ?? 0,
      fps: fps ?? 30.0,
      duration: duration,
      codec: codec ?? 'unknown',
      videoBitrate: videoBitrate ?? 0,
      audioBitrate: audioBitrate ?? 0,
      pixelFormat: pixelFormat ?? 'yuv420p',
      colorSpace: colorSpace ?? 'unknown',
      fileSizeBytes: fileSize,
      hasAudio: hasAudio,
      audioCodec: audioCodec,
    );
  }

  Future<VideoQualityAnalysis> _analyzeQuality(
    String videoPath,
    VideoMetadata metadata,
  ) async {
    double brightness = 0.5;
    double contrast = 0.5;
    double saturation = 0.7;
    double noiseLevel = 0.1;
    double blurLevel = 0.1;
    double exposure = 0.5;
    int colorTemperature = 6500;

    try {
      final tempDir = await getTemporaryDirectory();
      final statsFile = File('${tempDir.path}/video_stats.txt');
      
      if (await statsFile.exists()) {
        await statsFile.delete();
      }

      // Sample only the first 30s — decoding the whole video just for
      // brightness stats made analysis unusably slow on long inputs.
      final statsPath = statsFile.path.replaceAll('\\', '/').replaceAll(':', r'\:');
      final command = '-t 30 -i "$videoPath" '
          '-vf "signalstats,metadata=print:file=$statsPath" '
          '-f null -';

      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode) && await statsFile.exists()) {
        final content = await statsFile.readAsString();
        final lines = content.split('\n');

        double sumY = 0;
        int countY = 0;
        double minY = 255, maxY = 0;

        for (final line in lines) {
          if (line.contains('YAVG') || line.contains('YMIN') || line.contains('YMAX')) {
            final match = RegExp(r'(\d+\.?\d*)').firstMatch(line);
            if (match != null) {
              final value = double.parse(match.group(1)!);
              if (line.contains('YAVG')) {
                sumY += value;
                countY++;
              } else if (line.contains('YMIN')) {
                minY = value;
              } else if (line.contains('YMAX')) {
                maxY = value;
              }
            }
          }
        }

        if (countY > 0) {
          brightness = (sumY / countY) / 255.0;
        }
        if (maxY > minY) {
          contrast = ((maxY - minY) / 255.0).clamp(0.0, 1.0);
        }

        exposure = brightness;
      }

      noiseLevel = _estimateNoiseLevel(metadata);
      blurLevel = _estimateBlurLevel(metadata);
      saturation = _estimateSaturation(metadata, brightness);
      colorTemperature = _estimateColorTemperature(metadata);
    } catch (e) {
      // Fallback to defaults, but log so failures aren't fully silent.
      AppLogger().w('Quality analysis failed: $e');
    }

    return VideoQualityAnalysis(
      brightness: brightness,
      contrast: contrast,
      saturation: saturation,
      noiseLevel: noiseLevel,
      blurLevel: blurLevel,
      exposure: exposure,
      colorTemperature: colorTemperature,
    );
  }

  double _estimateNoiseLevel(VideoMetadata metadata) {
    if (metadata.videoBitrate < 1000000) return 0.6;
    if (metadata.videoBitrate < 2000000) return 0.4;
    if (metadata.videoBitrate < 4000000) return 0.2;
    if (metadata.fileSizeBytes > 100000000) return 0.1;
    return 0.3;
  }

  double _estimateBlurLevel(VideoMetadata metadata) {
    if (metadata.width < 640) return 0.7;
    if (metadata.width < 1280) return 0.5;
    if (metadata.height < 720) return 0.4;
    return 0.2;
  }

  double _estimateSaturation(VideoMetadata metadata, double brightness) {
    if (metadata.codec.toLowerCase().contains('hevc') || 
        metadata.codec.toLowerCase().contains('h265')) {
      return 0.6;
    }
    if (metadata.videoBitrate < 2000000) return 0.5;
    return 0.7;
  }

  int _estimateColorTemperature(VideoMetadata metadata) {
    return 6500;
  }
}