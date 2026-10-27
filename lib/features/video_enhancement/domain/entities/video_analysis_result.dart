import 'dart:ui';

enum VideoQualityIssue {
  none,
  tooDark,
  tooBright,
  lowContrast,
  washedOutColors,
  noisy,
  blurry,
  lowResolution,
  lowBitrate,
  badAudio,
}

class VideoMetadata {
  final int width;
  final int height;
  final double fps;
  final Duration duration;
  final String codec;
  final int videoBitrate;
  final int audioBitrate;
  final String pixelFormat;
  final String colorSpace;
  final int fileSizeBytes;
  final bool hasAudio;
  final String? audioCodec;

  const VideoMetadata({
    required this.width,
    required this.height,
    required this.fps,
    required this.duration,
    required this.codec,
    required this.videoBitrate,
    required this.audioBitrate,
    required this.pixelFormat,
    required this.colorSpace,
    required this.fileSizeBytes,
    required this.hasAudio,
    this.audioCodec,
  });

  bool get needsUpscaling => width < 1920 && height < 1080;
  bool get isLowBitrate => videoBitrate < 2000000;
  bool get isHd => width >= 1920 || height >= 1080;

  VideoMetadata copyWith({
    int? width,
    int? height,
    double? fps,
    Duration? duration,
    String? codec,
    int? videoBitrate,
    int? audioBitrate,
    String? pixelFormat,
    String? colorSpace,
    int? fileSizeBytes,
    bool? hasAudio,
    String? audioCodec,
  }) {
    return VideoMetadata(
      width: width ?? this.width,
      height: height ?? this.height,
      fps: fps ?? this.fps,
      duration: duration ?? this.duration,
      codec: codec ?? this.codec,
      videoBitrate: videoBitrate ?? this.videoBitrate,
      audioBitrate: audioBitrate ?? this.audioBitrate,
      pixelFormat: pixelFormat ?? this.pixelFormat,
      colorSpace: colorSpace ?? this.colorSpace,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      hasAudio: hasAudio ?? this.hasAudio,
      audioCodec: audioCodec ?? this.audioCodec,
    );
  }
}

class VideoQualityAnalysis {
  final double brightness;
  final double contrast;
  final double saturation;
  final double noiseLevel;
  final double blurLevel;
  final double exposure;
  final int colorTemperature;

  const VideoQualityAnalysis({
    required this.brightness,
    required this.contrast,
    required this.saturation,
    required this.noiseLevel,
    required this.blurLevel,
    required this.exposure,
    required this.colorTemperature,
  });

  List<VideoQualityIssue> get issues {
    final List<VideoQualityIssue> result = [];
    
    if (brightness < 0.3) result.add(VideoQualityIssue.tooDark);
    if (brightness > 0.8) result.add(VideoQualityIssue.tooBright);
    if (contrast < 0.4) result.add(VideoQualityIssue.lowContrast);
    if (saturation < 0.5) result.add(VideoQualityIssue.washedOutColors);
    if (noiseLevel > 0.3) result.add(VideoQualityIssue.noisy);
    if (blurLevel > 0.5) result.add(VideoQualityIssue.blurry);
    
    return result;
  }

  bool get hasIssues => issues.isNotEmpty;
}

class VideoAnalysisResult {
  final VideoMetadata metadata;
  final VideoQualityAnalysis quality;
  final List<VideoQualityIssue> detectedIssues;
  final DateTime analyzedAt;

  const VideoAnalysisResult({
    required this.metadata,
    required this.quality,
    required this.detectedIssues,
    required this.analyzedAt,
  });

  bool get needsUpscaling => metadata.needsUpscaling;
  bool get hasNoise => quality.noiseLevel > 0.3;
  bool get isDark => quality.brightness < 0.3;
  bool isBlurry(double threshold) => quality.blurLevel > threshold;

  Size getUpscaleTarget() {
    if (metadata.width >= 1920) return const Size(2560, 1440);
    if (metadata.height >= 1080) return const Size(1920, 1080);
    if (metadata.width >= 1280 || metadata.height >= 720) return const Size(1920, 1080);
    return const Size(1280, 720);
  }
}